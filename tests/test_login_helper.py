#!/usr/bin/env python3

import importlib.util
import os
import stat
import sys
import tempfile
import threading
import unittest
from io import BytesIO, StringIO
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "shvpn_login_helper", ROOT / "libexec" / "python-login-helper.py"
)
assert SPEC and SPEC.loader
HELPER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = HELPER
SPEC.loader.exec_module(HELPER)


class CallbackTests(unittest.TestCase):
    def test_cdp_patterns_escape_the_literal_query_delimiter(self):
        self.assertEqual(
            HELPER.CALLBACK_PATTERNS,
            (
                r"https://vpn.shanghaitech.edu.cn/passport/v1/auth/cas\?*",
                r"https://vpn.shanghaitech.edu.cn:443/passport/v1/auth/cas\?*",
            ),
        )

    def test_accepts_one_ticket_and_extra_query_keys(self):
        raw = (
            "https://vpn.shanghaitech.edu.cn:443/passport/v1/auth/cas"
            "?ticket=ST-EXAMPLE&lang=zh-CN"
        )
        self.assertEqual(HELPER.validate_callback(raw), raw)
        HELPER.validate_start_url()

    def test_rejects_wrong_shape_controls_whitespace_and_ticket_counts(self):
        invalid = [
            "http://vpn.shanghaitech.edu.cn/passport/v1/auth/cas?ticket=x",
            "https://user@vpn.shanghaitech.edu.cn/passport/v1/auth/cas?ticket=x",
            "https://vpn.shanghaitech.edu.cn/portal/?ticket=x",
            "https://vpn.shanghaitech.edu.cn/passport/v1/auth/cas",
            "https://vpn.shanghaitech.edu.cn/passport/v1/auth/cas?ticket=",
            "https://vpn.shanghaitech.edu.cn/passport/v1/auth/cas?ticket=x&ticket=y",
            "https://vpn.shanghaitech.edu.cn/passport/v1/auth/cas?ticket=x#fragment",
            " https://vpn.shanghaitech.edu.cn/passport/v1/auth/cas?ticket=x",
            "https://vpn.shanghaitech.edu.cn/passport/v1/auth/cas?ticket=x\x7f",
            "https://vpn.shanghaitech.edu.cn/passport/v1/auth/cas?ticket=x\n",
            "https://vpn.shanghaitech.edu.cn/passport/v1/auth/cas?ticket=%0A",
            "https://vpn.shanghaitech.edu.cn:444/passport/v1/auth/cas?ticket=x",
        ]
        for raw in invalid:
            with self.subTest(raw=repr(raw)), self.assertRaises(HELPER.LoginError):
                HELPER.validate_callback(raw)

    def test_removed_callback_cli_cannot_place_a_ticket_in_argv(self):
        with mock.patch("sys.stderr", StringIO()), self.assertRaises(SystemExit):
            HELPER.parse_args(["--validate-callback", "ticket-secret"])

    def test_navigation_error_is_accepted_only_after_capture(self):
        class Error(Exception):
            pass

        class Page:
            def goto(self, *args, **kwargs):
                raise Error("ST-EXAMPLE must stay secret")

        with self.assertRaises(HELPER.LoginError):
            HELPER.navigate_to_entry(Page(), HELPER.CallbackCapture(), Error)
        captured = HELPER.CallbackCapture()
        captured.urls.append(
            "https://vpn.shanghaitech.edu.cn/passport/v1/auth/cas?ticket=ST-EXAMPLE"
        )
        HELPER.navigate_to_entry(Page(), captured, Error)

    def test_capture_aborts_invalid_and_duplicate_requests(self):
        class CDP:
            def __init__(self):
                self.failed = []

            def send(self, command, parameters):
                self.failed.append((command, parameters))

        valid = "https://vpn.shanghaitech.edu.cn/passport/v1/auth/cas?ticket=ST-EXAMPLE"
        cdp = CDP()
        invalid_capture = HELPER.CallbackCapture()
        invalid_capture.handle(
            cdp, {"requestId": "invalid", "request": {"url": "https://example.test/?ticket=x"}}
        )
        self.assertTrue(invalid_capture.error)
        self.assertEqual(cdp.failed[0][0], "Fetch.failRequest")

        duplicate = HELPER.CallbackCapture()
        duplicate.handle(cdp, {"requestId": "one", "request": {"url": valid}})
        duplicate.handle(cdp, {"requestId": "two", "request": {"url": valid}})
        self.assertTrue(duplicate.error)
        self.assertEqual(len(duplicate.urls), 1)
        self.assertEqual([item[1]["requestId"] for item in cdp.failed[-2:]], ["one", "two"])


class DigestTests(unittest.TestCase):
    def test_digest_is_path_sorted_and_rejects_symlinks(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "b").write_bytes(b"two")
            (root / "a").write_bytes(b"one")
            first = HELPER.tree_digest(root)
            self.assertEqual(first, HELPER.tree_digest(root))
            (root / "link").symlink_to(root / "a")
            with self.assertRaises(HELPER.LoginError):
                HELPER.tree_digest(root)


class MonitorTests(unittest.TestCase):
    def test_markers_latch_across_chunks_and_tail_filler(self):
        read_fd, write_fd = os.pipe()
        stream = os.fdopen(read_fd, "rb", buffering=0)
        monitor = HELPER.OutputMonitor(stream)
        monitor.start()
        os.write(write_fd, b"x" * 5000 + b"Please enter the call")
        os.write(write_fd, b"back url:" + b"y" * 5000)
        os.write(write_fd, b"Please enter the SMS verification code:")
        os.write(write_fd, b"SOCKS5 server listening on 127.0.0.1:11080")
        os.close(write_fd)
        monitor.thread.join(2)
        stream.close()
        self.assertTrue(monitor.callback_prompt)
        self.assertTrue(monitor.sms_prompt)
        self.assertTrue(monitor.ready)


class LoginIntegrationTests(unittest.TestCase):
    def test_cdp_capture_submits_exactly_one_newline_and_cleans_up(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            package = root / "packages"
            sync_api = package / "playwright" / "sync_api.py"
            sync_api.parent.mkdir(parents=True)
            (sync_api.parent / "__init__.py").write_text("")
            sync_api.write_text(
                """
class Error(Exception): pass
LAST_CONTEXT = None
class CDP:
    def __init__(self): self.handlers = {}; self.commands = []
    def send(self, name, params=None): self.commands.append((name, params))
    def on(self, name, handler): self.handlers[name] = handler
class Page:
    def __init__(self, context): self.context = context
    def goto(self, url, **kwargs):
        if url == 'about:blank': return None
        self.context.cdp.handlers['Fetch.requestPaused']({
            'requestId': 'one',
            'request': {'url': 'https://vpn.shanghaitech.edu.cn/passport/v1/auth/cas?ticket=ST-EXAMPLE'}
        })
        raise Error('ST-EXAMPLE must stay secret')
    def wait_for_timeout(self, value): return None
class Context:
    def __init__(self):
        self.cdp = CDP(); self.pages = [Page(self)]
        self._cookies = [
            {'name':'cas','value':'ok','domain':'ids.shanghaitech.edu.cn','path':'/'},
            {'name':'vpn','value':'drop','domain':'vpn.shanghaitech.edu.cn','path':'/'},
        ]
        self.closed = False
    def new_page(self): return Page(self)
    def new_cdp_session(self, page): return self.cdp
    def cookies(self): return list(self._cookies)
    def clear_cookies(self, domain=None):
        if domain is None: self._cookies = []
        else: self._cookies = [cookie for cookie in self._cookies if cookie['domain'] != domain]
    def add_cookies(self, cookies): self._cookies.extend(cookies)
    def close(self): self.closed = True
class Chromium:
    def launch_persistent_context(self, *args, **kwargs):
        global LAST_CONTEXT, LAST_LAUNCH_KWARGS
        LAST_LAUNCH_KWARGS = kwargs
        LAST_CONTEXT = Context(); return LAST_CONTEXT
class Manager:
    chromium = Chromium()
    def __enter__(self): return self
    def __exit__(self, *args): return False
def sync_playwright(): return Manager()
"""
            )
            state = root / "state"
            state.mkdir()
            (state / "client-data.json").write_text("{}")
            launcher = root / "launcher"
            launcher.write_text("#!/bin/sh\nexit 0\n")
            launcher.chmod(0o700)

            class FakeProcess:
                pid = 424242

                def __init__(self):
                    self.stdin = BytesIO()
                    self.stdout = BytesIO(
                        HELPER.CALLBACK_PROMPT + b"\n" + HELPER.READY_MARKER + b"\n"
                    )
                    self.done = False
                    self.environment = None

                def poll(self):
                    return 0 if self.done else None

                def wait(self, timeout=None):
                    self.done = True
                    return 0

            fake_process = FakeProcess()

            def fake_spawn(launcher_path, environment):
                fake_process.environment = environment
                self.assertEqual(Path(launcher_path), launcher)
                return fake_process, fake_process.stdout

            def fake_killpg(pid, sig):
                self.assertEqual(pid, fake_process.pid)
                fake_process.done = True

            old_proxy = os.environ.get("https_proxy")
            os.environ["https_proxy"] = "http://127.0.0.1:9"
            stdout = StringIO()
            stderr = StringIO()
            try:
                with mock.patch.object(HELPER, "_port_is_free", return_value=True), mock.patch.object(
                    HELPER.time, "sleep", return_value=None
                ), mock.patch.object(HELPER, "spawn_vpn_client", side_effect=fake_spawn), mock.patch.object(
                    HELPER.os, "killpg", side_effect=fake_killpg
                ), mock.patch("sys.stdout", stdout), mock.patch("sys.stderr", stderr):
                    self.assertEqual(HELPER.run_login(package, launcher, state), 0)
            finally:
                if old_proxy is None:
                    os.environ.pop("https_proxy", None)
                else:
                    os.environ["https_proxy"] = old_proxy
            self.assertEqual(
                fake_process.stdin.getvalue(),
                b"https://vpn.shanghaitech.edu.cn/passport/v1/auth/cas?ticket=ST-EXAMPLE\n",
            )
            self.assertNotIn("https_proxy", fake_process.environment)
            self.assertEqual(stat.S_IMODE((state / "client-data.json").stat().st_mode), 0o600)
            self.assertEqual(os.environ.get("https_proxy"), old_proxy)
            sync_module = sys.modules.get("playwright.sync_api")
            self.assertIsNotNone(sync_module)
            context = sync_module.LAST_CONTEXT
            self.assertTrue(context.closed)
            self.assertEqual([cookie["domain"] for cookie in context._cookies], ["ids.shanghaitech.edu.cn"])
            failed = [command for command, _ in context.cdp.commands]
            self.assertIn("Fetch.failRequest", failed)
            self.assertIn("--no-sandbox", sync_module.LAST_LAUNCH_KWARGS["args"])
            self.assertIn("--disable-dev-shm-usage", sync_module.LAST_LAUNCH_KWARGS["args"])
            self.assertNotIn("ST-EXAMPLE", stdout.getvalue() + stderr.getvalue())
            for artifact in state.rglob("*"):
                if artifact.is_file():
                    self.assertNotIn(b"ST-EXAMPLE", artifact.read_bytes())

    def test_sms_has_its_own_ready_budget(self):
        class Condition:
            def __init__(self, monitor):
                self.monitor = monitor

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def wait(self, timeout):
                self.monitor.ready = True

        class Monitor:
            ready = False
            sms_prompt = True

            def __init__(self):
                self.condition = Condition(self)

        class Process:
            def __init__(self):
                self.stdin = BytesIO()

            def poll(self):
                return None

        monitor = Monitor()
        process = Process()
        with mock.patch.object(HELPER, "read_sms_code", return_value="123456"):
            HELPER.wait_for_client_ready(monitor, process)
        self.assertEqual(process.stdin.getvalue(), b"123456\n")

    def test_client_exit_before_ready_fails_closed(self):
        class Monitor:
            ready = False
            sms_prompt = False
            condition = threading.Condition()

        class Process:
            stdin = BytesIO()

            def poll(self):
                return 1

        with self.assertRaisesRegex(HELPER.LoginError, "exited before login"):
            HELPER.wait_for_client_ready(Monitor(), Process())

    def test_cancellation_handlers_raise_a_controlled_error(self):
        previous = HELPER.install_cancellation_handlers()
        try:
            handler = HELPER.signal.getsignal(HELPER.signal.SIGTERM)
            with self.assertRaisesRegex(HELPER.LoginError, "stage=signal"):
                handler(HELPER.signal.SIGTERM, None)
        finally:
            HELPER.ignore_cancellation_signals()
            HELPER.restore_cancellation_handlers(previous)

    def test_profile_discard_is_exact_and_leaves_no_sibling(self):
        with tempfile.TemporaryDirectory() as temp:
            state = Path(temp)
            profile = state / "cas-chrome-profile"
            profile.mkdir()
            (profile / "residue").write_text("not a ticket")
            HELPER._safe_discard_profile(profile)
            self.assertFalse(profile.exists())
            self.assertEqual(list(state.iterdir()), [])

    def test_residual_cleanup_reports_only_pid_and_stage(self):
        class Process:
            pid = 424242

            def poll(self):
                return None

            def wait(self, timeout):
                raise HELPER.subprocess.TimeoutExpired("contains-secret-argv", timeout)

        with tempfile.TemporaryDirectory() as temp, mock.patch.object(
            HELPER.os, "killpg"
        ), mock.patch.object(HELPER, "_port_is_free", return_value=True):
            root = Path(temp)
            with self.assertRaisesRegex(
                HELPER.LoginError, r"^cleanup residual pid=424242 stage=signal-wait$"
            ):
                HELPER.cleanup_login(
                    Process(), None, None, None, root / "cas-chrome-profile", root
                )

    def test_sms_without_tty_fails_closed(self):
        with mock.patch("builtins.open", side_effect=OSError):
            with self.assertRaises(HELPER.LoginError):
                HELPER.read_sms_code(0.01)

    def test_sms_falls_back_to_stdin_when_dev_tty_is_unavailable(self):
        stdin = mock.Mock()
        stdin.isatty.return_value = True
        stdin.fileno.return_value = 0
        stdin.readline.return_value = "123456\n"
        stderr = mock.Mock()
        stderr.isatty.return_value = True

        def fake_getattr(_fd):
            return [0, 0, 0, HELPER.termios.ECHO, 0, 0, []]

        with mock.patch("builtins.open", side_effect=OSError), mock.patch.object(
            HELPER.sys, "stdin", stdin
        ), mock.patch.object(HELPER.sys, "stderr", stderr), mock.patch.object(
            HELPER.termios, "tcgetattr", side_effect=fake_getattr
        ), mock.patch.object(HELPER.termios, "tcsetattr"), mock.patch.object(
            HELPER.select, "select", return_value=([stdin], [], [])
        ):
            self.assertEqual(HELPER.read_sms_code(1.0), "123456")
        stderr.write.assert_any_call("SMS verification code: ")

    def test_spawn_pty_flushes_block_buffered_callback_prompt(self):
        with tempfile.TemporaryDirectory() as temp:
            launcher = Path(temp) / "launcher"
            launcher.write_text(
                "#!/usr/bin/env python3\n"
                "import sys\n"
                "print('Please enter the callback url:')\n"
                "sys.stdin.readline()\n"
            )
            launcher.chmod(0o700)
            process = None
            stream = None
            try:
                process, stream = HELPER.spawn_vpn_client(launcher, os.environ.copy())
                self.assertTrue(process.stdin)
                monitor = HELPER.OutputMonitor(stream)
                monitor.start()
                self.assertTrue(monitor.wait_for(lambda: monitor.callback_prompt, 5.0, process))
                process.stdin.write(b"ok\n")
                process.stdin.flush()
                process.stdin.close()
                self.assertEqual(process.wait(timeout=5), 0)
            finally:
                if process is not None and process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
                if stream is not None:
                    stream.close()

    def test_resolve_chrome_binary_prefers_sibling_chrome(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            wrapper = root / "google-chrome"
            binary = root / "chrome"
            wrapper.write_text("#!/bin/sh\n")
            binary.write_text("#!/bin/sh\n")
            wrapper.chmod(0o755)
            binary.chmod(0o755)
            self.assertEqual(HELPER.resolve_chrome_binary(wrapper), binary)


if __name__ == "__main__":
    unittest.main()
