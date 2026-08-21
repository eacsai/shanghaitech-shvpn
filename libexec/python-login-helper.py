#!/usr/bin/env python3
"""Automate ShanghaiTech CAS callback capture without exposing the callback."""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import os
import select
import secrets
import signal
import stat
import subprocess
import sys
import termios
import threading
import time
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit

START_URL = (
    "https://vpn.shanghaitech.edu.cn/passport/v1/public/casLogin"
    "?sfDomain=Shanghaitech.edu.cn"
)
CALLBACK_HOST = "vpn.shanghaitech.edu.cn"
CALLBACK_PATH = "/passport/v1/auth/cas"
CALLBACK_PATTERNS = (
    r"https://vpn.shanghaitech.edu.cn/passport/v1/auth/cas\?*",
    r"https://vpn.shanghaitech.edu.cn:443/passport/v1/auth/cas\?*",
)
CALLBACK_PROMPT = b"Please enter the callback url:"
SMS_PROMPT = b"Please enter the SMS verification code:"
READY_MARKER = b"SOCKS5 server listening on 127.0.0.1:11080"
TAIL_LIMIT = 4096


class LoginError(RuntimeError):
    pass


class CallbackCapture:
    def __init__(self) -> None:
        self.urls: list[str] = []
        self.error = False

    def handle(self, cdp: object, event: dict[str, object]) -> None:
        request_id = str(event.get("requestId", ""))
        request = event.get("request", {})
        raw = str(request.get("url", "")) if isinstance(request, dict) else ""
        try:
            cdp.send(  # type: ignore[attr-defined]
                "Fetch.failRequest",
                {"requestId": request_id, "errorReason": "Aborted"},
            )
        except Exception:
            self.error = True
            return
        if self.urls:
            self.error = True
            return
        try:
            self.urls.append(validate_callback(raw))
        except LoginError:
            self.error = True


def _owned_nonsymlink(path: Path, *, directory: bool | None = None) -> bool:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    if stat.S_ISLNK(info.st_mode) or info.st_uid != os.getuid():
        return False
    if directory is True and not stat.S_ISDIR(info.st_mode):
        return False
    if directory is False and not stat.S_ISREG(info.st_mode):
        return False
    return True


def ensure_private_dir(path: Path) -> None:
    if path.exists() or path.is_symlink():
        if not _owned_nonsymlink(path, directory=True):
            raise LoginError("unsafe login state directory")
    else:
        path.mkdir(mode=0o700, parents=True)
    path.chmod(0o700)


def validate_callback(raw: str) -> str:
    if len(raw) > 8192 or raw != raw.strip():
        raise LoginError("invalid CAS callback URL")
    if any(ord(char) <= 0x1F or ord(char) == 0x7F for char in raw):
        raise LoginError("invalid CAS callback URL")
    try:
        parsed = urlsplit(raw)
        port = parsed.port
    except ValueError as exc:
        raise LoginError("invalid CAS callback URL") from exc
    if (
        parsed.scheme != "https"
        or parsed.username is not None
        or parsed.password is not None
        or parsed.hostname != CALLBACK_HOST
        or port not in (None, 443)
        or parsed.path != CALLBACK_PATH
        or parsed.fragment
    ):
        raise LoginError("invalid CAS callback URL")
    tickets = [value for key, value in parse_qsl(parsed.query, keep_blank_values=True) if key == "ticket"]
    if (
        len(tickets) != 1
        or not tickets[0]
        or any(ord(char) <= 0x1F or ord(char) == 0x7F for char in tickets[0])
    ):
        raise LoginError("invalid CAS callback URL")
    return raw


def validate_start_url() -> None:
    try:
        parsed = urlsplit(START_URL)
        port = parsed.port
    except ValueError as exc:
        raise LoginError("invalid managed CAS entry URL") from exc
    query = parse_qsl(parsed.query, keep_blank_values=True)
    if (
        parsed.scheme != "https"
        or parsed.username is not None
        or parsed.password is not None
        or parsed.hostname != CALLBACK_HOST
        or port is not None
        or parsed.path != "/passport/v1/public/casLogin"
        or parsed.fragment
        or query != [("sfDomain", "Shanghaitech.edu.cn")]
    ):
        raise LoginError("invalid managed CAS entry URL")


def tree_digest(root: Path) -> str:
    if not _owned_nonsymlink(root, directory=True):
        raise LoginError("unsafe Python package directory")
    records: list[tuple[bytes, bytes]] = []
    def walk_error(error: OSError) -> None:
        raise LoginError("unreadable Python package tree") from error

    for current, directories, files in os.walk(
        root, topdown=True, onerror=walk_error, followlinks=False
    ):
        current_path = Path(current)
        for name in directories:
            item = current_path / name
            if "\n" in name or "\r" in name or not _owned_nonsymlink(item, directory=True):
                raise LoginError("unsafe Python package tree")
        for name in files:
            item = current_path / name
            if "\n" in name or "\r" in name or not _owned_nonsymlink(item, directory=False):
                raise LoginError("unsafe Python package tree")
            relative = item.relative_to(root).as_posix()
            if not relative or relative.startswith("/") or any(part in ("", ".", "..") for part in relative.split("/")):
                raise LoginError("unsafe Python package tree")
            encoded = relative.encode("utf-8")
            digest = hashlib.sha256(item.read_bytes()).hexdigest().encode("ascii")
            records.append((encoded, encoded + b"\0" + digest + b"\n"))
    records.sort(key=lambda item: item[0])
    result = hashlib.sha256()
    for _, record in records:
        result.update(record)
    return result.hexdigest()


class OutputMonitor:
    def __init__(self, stream: object) -> None:
        self.stream = stream
        self.tail = b""
        self.callback_prompt = False
        self.sms_prompt = False
        self.ready = False
        self.eof = False
        self.condition = threading.Condition()
        self.thread = threading.Thread(target=self._read, daemon=True)

    def start(self) -> None:
        self.thread.start()

    def _read(self) -> None:
        while True:
            try:
                chunk = self.stream.read(512)  # type: ignore[attr-defined]
            except OSError:
                chunk = b""
            with self.condition:
                if not chunk:
                    self.eof = True
                    self.condition.notify_all()
                    return
                self.tail = (self.tail + chunk)[-TAIL_LIMIT:]
                self.callback_prompt = self.callback_prompt or CALLBACK_PROMPT in self.tail
                self.sms_prompt = self.sms_prompt or SMS_PROMPT in self.tail
                self.ready = self.ready or READY_MARKER in self.tail
                self.condition.notify_all()

    def wait_for(self, predicate: object, timeout: float, process: subprocess.Popen[bytes]) -> bool:
        deadline = time.monotonic() + timeout
        with self.condition:
            while not predicate():  # type: ignore[operator]
                if process.poll() is not None or self.eof:
                    return bool(predicate())  # type: ignore[operator]
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
                self.condition.wait(min(remaining, 0.25))
        return True


def read_sms_code(timeout: float = 300.0) -> str:
    owned = False
    prompt = None
    try:
        tty = open("/dev/tty", "r+", encoding="utf-8", buffering=1)
        owned = True
        prompt = tty
    except OSError as exc:
        # Some desktop terminals attach stdin to a PTY without a controlling
        # /dev/tty. Fall back to the current interactive stdin in that case.
        if not (sys.stdin.isatty() and sys.stderr.isatty()):
            raise LoginError("SMS verification requires an interactive terminal") from exc
        tty = sys.stdin
        prompt = sys.stderr
    try:
        fd = tty.fileno()
        old = termios.tcgetattr(fd)
    except (OSError, termios.error) as exc:
        if owned:
            tty.close()
        raise LoginError("SMS verification requires an interactive terminal") from exc
    try:
        prompt.write("SMS verification code: ")
        prompt.flush()
        new = termios.tcgetattr(fd)
        new[3] &= ~termios.ECHO
        termios.tcsetattr(fd, termios.TCSADRAIN, new)
        readable, _, _ = select.select([tty], [], [], timeout)
        if not readable:
            raise LoginError("SMS verification timed out")
        code = tty.readline().rstrip("\r\n")
        prompt.write("\n")
        prompt.flush()
    finally:
        try:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
        except termios.error:
            pass
        if owned:
            tty.close()
    if not code or any(ord(char) <= 0x20 or ord(char) == 0x7F for char in code):
        raise LoginError("invalid SMS verification code")
    return code


def _port_is_free() -> bool:
    import socket

    with socket.socket() as sock:
        return sock.connect_ex(("127.0.0.1", 11080)) != 0


def wait_for_client_ready(
    monitor: OutputMonitor, process: subprocess.Popen[bytes]
) -> None:
    sms_sent = False
    ready_deadline = time.monotonic() + 300.0
    while not monitor.ready:
        if process.poll() is not None:
            raise LoginError("VPN client exited before login completed")
        if monitor.sms_prompt and not sms_sent:
            assert process.stdin is not None
            process.stdin.write(read_sms_code().encode("utf-8") + b"\n")
            process.stdin.flush()
            sms_sent = True
            ready_deadline = time.monotonic() + 300.0
        if time.monotonic() >= ready_deadline:
            raise LoginError("VPN login timed out")
        with monitor.condition:
            monitor.condition.wait(0.25)


def navigate_to_entry(page: object, capture: CallbackCapture, error_type: type[Exception]) -> None:
    try:
        page.goto(  # type: ignore[attr-defined]
            START_URL, wait_until="domcontentloaded", timeout=600_000
        )
    except error_type:
        if not capture.urls:
            raise LoginError("CAS browser navigation failed")


def _safe_discard_profile(profile: Path) -> None:
    parent = profile.parent
    if profile.name != "cas-chrome-profile" or not _owned_nonsymlink(parent, directory=True):
        raise LoginError("refusing unsafe browser profile cleanup")
    if not (profile.exists() or profile.is_symlink()):
        return
    if not _owned_nonsymlink(profile, directory=True):
        raise LoginError("refusing unsafe browser profile cleanup")
    resolved_parent = parent.resolve(strict=True)
    discard = parent / f".cas-chrome-profile.discard-{os.getpid()}-{secrets.token_hex(8)}"
    if discard.exists() or discard.is_symlink():
        raise LoginError("browser profile discard path already exists")
    profile.rename(discard)
    if (
        not _owned_nonsymlink(parent, directory=True)
        or not _owned_nonsymlink(discard, directory=True)
        or discard.parent.resolve(strict=True) != resolved_parent
        or discard.resolve(strict=True).parent != resolved_parent
    ):
        raise LoginError("refusing unsafe browser profile cleanup")
    import shutil

    shutil.rmtree(discard)


def _clean_browser(context: object, page: object, cdp: object, profile: Path) -> None:
    failed = False
    try:
        page.goto("about:blank", wait_until="commit", timeout=10_000)  # type: ignore[attr-defined]
        cdp.send("Page.resetNavigationHistory")  # type: ignore[attr-defined]
        cdp.send("Network.clearBrowserCache")  # type: ignore[attr-defined]
        _clear_vpn_cookies(context)
    except Exception:
        failed = True
    try:
        context.close()  # type: ignore[attr-defined]
    except Exception:
        failed = True
    if failed:
        _safe_discard_profile(profile)


def _clear_vpn_cookies(context: object) -> None:
    context.clear_cookies(domain=CALLBACK_HOST)  # type: ignore[attr-defined]


@contextlib.contextmanager
def sanitized_process_environment() -> object:
    blocked = {
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "http_proxy",
        "https_proxy",
        "all_proxy",
        "DEBUG",
        "PWDEBUG",
        "SSLKEYLOGFILE",
    }
    blocked.update(key for key in os.environ if key.startswith("PLAYWRIGHT_"))
    saved = {key: os.environ[key] for key in blocked if key in os.environ}
    try:
        for key in blocked:
            os.environ.pop(key, None)
        yield
    finally:
        for key in blocked:
            os.environ.pop(key, None)
        os.environ.update(saved)


def install_cancellation_handlers() -> dict[int, object]:
    previous: dict[int, object] = {}

    def cancel(signum: int, _frame: object) -> None:
        raise LoginError(f"cancelled stage=signal-{signum}")

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous[signum] = signal.getsignal(signum)
        signal.signal(signum, cancel)
    return previous


def ignore_cancellation_signals() -> None:
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, signal.SIG_IGN)


def restore_cancellation_handlers(previous: dict[int, object]) -> None:
    for signum, handler in previous.items():
        signal.signal(signum, handler)


def cleanup_login(
    process: subprocess.Popen[bytes] | None,
    context: object | None,
    page: object | None,
    cdp: object | None,
    profile: Path,
    state_dir: Path,
) -> None:
    cleanup_error: LoginError | None = None
    if context is not None and page is not None and cdp is not None:
        try:
            _clean_browser(context, page, cdp, profile)
        except Exception:
            cleanup_error = LoginError("cleanup failed stage=browser")
    if process is not None and process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGINT)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=10.0)
        except subprocess.TimeoutExpired:
            cleanup_error = LoginError(
                f"cleanup residual pid={process.pid} stage=signal-wait"
            )
    client_data = state_dir / "client-data.json"
    if client_data.exists() or client_data.is_symlink():
        if _owned_nonsymlink(client_data, directory=False):
            client_data.chmod(0o600)
        elif cleanup_error is None:
            cleanup_error = LoginError("cleanup failed stage=client-data")
    if not _port_is_free() and cleanup_error is None:
        residual_pid = process.pid if process is not None else 0
        cleanup_error = LoginError(
            f"cleanup residual pid={residual_pid} stage=port-release"
        )
    if cleanup_error is not None:
        raise cleanup_error


def safe_external_executable(path: Path) -> bool:
    try:
        resolved = path.resolve(strict=True)
        info = resolved.stat()
    except (FileNotFoundError, OSError):
        return False
    return (
        stat.S_ISREG(info.st_mode)
        and info.st_uid in (0, os.getuid())
        and not (info.st_mode & 0o002)
        and os.access(resolved, os.X_OK)
    )


def resolve_chrome_binary(chrome_executable: Path) -> Path:
    resolved = chrome_executable.resolve(strict=True)
    sibling = resolved.parent / "chrome"
    if sibling != resolved and safe_external_executable(sibling):
        return sibling
    return resolved


def spawn_vpn_client(
    launcher: Path, environment: dict[str, str]
) -> tuple[subprocess.Popen[bytes], object]:
    # zju-connect logs to os.Stdout. Go fully buffers stdout when it is a
    # pipe, so the CAS callback prompt never arrives. A PTY makes stdout a
    # terminal and restores line buffering. stdin stays a pipe so this helper
    # can submit the captured callback and SMS code.
    if not hasattr(os, "openpty"):
        raise LoginError("PTY support is required to read VPN client prompts")
    master_fd, slave_fd = os.openpty()
    try:
        process = subprocess.Popen(
            [str(launcher)],
            stdin=subprocess.PIPE,
            stdout=slave_fd,
            stderr=slave_fd,
            start_new_session=True,
            env=environment,
            close_fds=True,
        )
    except Exception:
        os.close(master_fd)
        os.close(slave_fd)
        raise
    os.close(slave_fd)
    return process, os.fdopen(master_fd, "rb", buffering=0)


def run_login(
    package_dir: Path,
    launcher: Path,
    state_dir: Path,
    chrome_executable: Path | None = None,
) -> int:
    if not _owned_nonsymlink(package_dir, directory=True):
        raise LoginError("unsafe managed Playwright runtime")
    if not _owned_nonsymlink(launcher, directory=False) or not os.access(launcher, os.X_OK):
        raise LoginError("unsafe managed VPN launcher")
    if chrome_executable is not None and not safe_external_executable(chrome_executable):
        raise LoginError("unsafe Google Chrome executable")
    ensure_private_dir(state_dir)
    profile = state_dir / "cas-chrome-profile"
    ensure_private_dir(profile)
    if not _port_is_free():
        raise LoginError("SOCKS port 127.0.0.1:11080 is already in use")
    validate_start_url()

    sys.path.insert(0, str(package_dir))
    try:
        from playwright.sync_api import Error as PlaywrightError
        from playwright.sync_api import sync_playwright
    except Exception as exc:
        raise LoginError("managed Playwright runtime is unavailable") from exc

    process: subprocess.Popen[bytes] | None = None
    client_output = None
    context = page = cdp = None
    capture = CallbackCapture()
    success = False
    previous_handlers = install_cancellation_handlers()
    try:
        with sanitized_process_environment():
            environment = os.environ.copy()
            process, client_output = spawn_vpn_client(launcher, environment)
        assert process.stdin is not None and client_output is not None
        monitor = OutputMonitor(client_output)
        monitor.start()
        print(
            "shvpn login: waiting for the VPN client to request CAS...",
            file=sys.stderr,
            flush=True,
        )
        if not monitor.wait_for(lambda: monitor.callback_prompt, 120.0, process):
            raise LoginError("VPN client did not request a CAS callback")
        print(
            "shvpn login: opening the dedicated Chrome login window...",
            file=sys.stderr,
            flush=True,
        )
        with sanitized_process_environment(), sync_playwright() as playwright:
            browser_options = {
                "headless": False,
                "args": [
                    "--no-proxy-server",
                    "--no-first-run",
                    "--no-default-browser-check",
                    "--disable-session-crashed-bubble",
                    "--disable-sync",
                    "--disable-extensions",
                    "--no-sandbox",
                    "--disable-dev-shm-usage",
                    "--disable-gpu",
                ],
                "service_workers": "block",
            }
            if chrome_executable is None:
                browser_options["channel"] = "chrome"
            else:
                browser_options["executable_path"] = str(
                    resolve_chrome_binary(chrome_executable)
                )
            context = playwright.chromium.launch_persistent_context(str(profile), **browser_options)
            _clear_vpn_cookies(context)
            page = context.pages[0] if context.pages else context.new_page()
            cdp = context.new_cdp_session(page)
            cdp.send("Network.enable")
            cdp.send(
                "Fetch.enable",
                {"patterns": [{"urlPattern": pattern, "requestStage": "Request"} for pattern in CALLBACK_PATTERNS]},
            )

            cdp.on("Fetch.requestPaused", lambda event: capture.handle(cdp, event))
            navigate_to_entry(page, capture, PlaywrightError)
            deadline = time.monotonic() + 600.0
            while not capture.urls and not capture.error and time.monotonic() < deadline:
                page.wait_for_timeout(100)
            if capture.error or not capture.urls:
                raise LoginError("a valid CAS callback was not captured")
            page.wait_for_timeout(250)
            if capture.error or len(capture.urls) != 1:
                raise LoginError("ambiguous CAS callback capture")
            process.stdin.write(capture.urls[0].encode("utf-8") + b"\n")
            process.stdin.flush()

            wait_for_client_ready(monitor, process)
            time.sleep(2.0)
            client_data = state_dir / "client-data.json"
            if not _owned_nonsymlink(client_data, directory=False):
                raise LoginError("VPN credential cache was not created safely")
            client_data.chmod(0o600)
            _clean_browser(context, page, cdp, profile)
            context = None
            success = True
    finally:
        ignore_cancellation_signals()
        try:
            cleanup_login(process, context, page, cdp, profile, state_dir)
        finally:
            if client_output is not None:
                try:
                    client_output.close()
                except Exception:
                    pass
            restore_cancellation_handlers(previous_handlers)
    if not success:
        raise LoginError("VPN login did not complete")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tree-digest", type=Path)
    parser.add_argument("--package-dir", type=Path)
    parser.add_argument("--launcher", type=Path)
    parser.add_argument("--chrome-executable", type=Path)
    parser.add_argument("--state-dir", type=Path)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.tree_digest is not None:
        print(tree_digest(args.tree_digest))
        return 0
    if not args.package_dir or not args.launcher or not args.chrome_executable or not args.state_dir:
        raise LoginError("missing managed login helper arguments")
    return run_login(args.package_dir, args.launcher, args.state_dir, args.chrome_executable)


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except LoginError as error:
        print(f"shvpn login: {error}", file=sys.stderr)
        raise SystemExit(1)
    except KeyboardInterrupt:
        print("shvpn login: cancelled stage=keyboard", file=sys.stderr)
        raise SystemExit(130)
    except Exception:
        print("shvpn login: unexpected failure stage=main", file=sys.stderr)
        raise SystemExit(1)
