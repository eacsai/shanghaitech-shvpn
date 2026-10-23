#!/usr/bin/env zsh

set -eu
setopt extendedglob
umask 077

typeset -gr project_root="${0:A:h:h}"

fail() {
  print -u2 -r -- "linux test: $*"
  exit 1
}

[[ "$(uname -s)" == "Linux" ]] || fail "this integration test requires Linux"
case "$(uname -m)" in
  x86_64|amd64) expected_platform="linux-amd64" ;;
  aarch64|arm64) expected_platform="linux-arm64" ;;
  *) fail "unsupported Linux architecture" ;;
esac

for command_name in zsh git go ssh nc lsof stat sha256sum python3; do
  command -v "$command_name" >/dev/null 2>&1 || fail "missing command: $command_name"
done
nc_help="$(nc -h 2>&1 || true)"
[[ "$nc_help" == *'-x '* && "$nc_help" == *'-X '* ]] || fail "OpenBSD netcat is required"
command -v google-chrome >/dev/null 2>&1 || command -v google-chrome-stable >/dev/null 2>&1 || fail "Google Chrome is required"

for script in "$project_root"/*.zsh "$project_root"/libexec/*.zsh "$project_root"/tests/*.zsh; do
  zsh -n "$script" || fail "zsh syntax failed: $script"
done
PYTHONDONTWRITEBYTECODE=1 python3 -I -B "$project_root/tests/test_login_helper.py" || fail "login helper tests failed"
"$project_root/tests/test_platform.zsh" || fail "platform mapping tests failed"
"$project_root/tests/test_desired_state.zsh" || fail "desired-state tests failed"

temp_parent="${${TMPDIR:-/tmp}:A}"
test_tmp="$(mktemp -d "$temp_parent/shvpn-linux-tests.XXXXXX")"
fixture_client_pid=""
unrelated_listener_pid=""
cleanup() {
  for fixture_pid in "$fixture_client_pid" "$unrelated_listener_pid"; do
    if [[ "$fixture_pid" == <-> ]] && /bin/kill -0 "$fixture_pid" 2>/dev/null; then
      /bin/kill -TERM "$fixture_pid" 2>/dev/null || true
      wait "$fixture_pid" 2>/dev/null || true
    fi
  done
  [[ -d "$test_tmp" && "$test_tmp" == "$temp_parent"/shvpn-linux-tests.* ]] && /bin/rm -rf -- "$test_tmp"
}
trap cleanup EXIT INT TERM

fixture_repo="$test_tmp/repo"
fixture_home="$test_tmp/home"
/bin/cp -R "$project_root" "$fixture_repo"
/usr/bin/install -d -m 700 "$fixture_home/.ssh"

# Fixture lifecycle checks never inspect or claim the user's real VPN port.
fixture_port=19181
if nc -z -w 1 127.0.0.1 "$fixture_port" >/dev/null 2>&1; then
  fail "fixture port is already in use"
fi
for fixture_template in shanghaitech-vpn.zsh shvpn.zsh shanghaitech-ssh-route.zsh; do
  /usr/bin/sed "s/11080/$fixture_port/g" "$fixture_repo/libexec/$fixture_template" >"$test_tmp/$fixture_template"
  /usr/bin/install -m 755 "$test_tmp/$fixture_template" "$fixture_repo/libexec/$fixture_template"
done

cat >"$test_tmp/fixture-client.go" <<'GO'
package main

import (
    "net"
    "os"
    "os/signal"
    "syscall"
)

func main() {
    bind := ""
    for i := 1; i+1 < len(os.Args); i++ {
        if os.Args[i] == "-socks-bind" {
            bind = os.Args[i+1]
        }
    }
    if bind == "" {
        os.Exit(1)
    }
    stopped := make(chan os.Signal, 1)
    signal.Notify(stopped, syscall.SIGINT, syscall.SIGTERM)
    listener, err := net.Listen("tcp", bind)
    if err != nil {
        os.Exit(2)
    }
    <-stopped
    listener.Close()
}
GO
GOTOOLCHAIN=local go build -o "$test_tmp/fixture-client" "$test_tmp/fixture-client.go" || fail "cannot build fixture client"
{
  print -r -- '#!/usr/bin/env zsh'
  print -r -- 'set -eu'
  print -r -- "/bin/cp ${(qqq)test_tmp}/fixture-client \"\$1\""
  print -r -- '/bin/chmod 755 "$1"'
} >"$fixture_repo/libexec/build-client.zsh"
/bin/chmod 755 "$fixture_repo/libexec/build-client.zsh"

{
  print -r -- '#!/usr/bin/env zsh'
  print -r -- 'set -eu'
  print -r -- 'output_dir="$3"'
  print -r -- '/usr/bin/install -d -m 700 "$output_dir/playwright"'
  print -r -- 'print -r -- "" >"$output_dir/playwright/__init__.py"'
  print -r -- 'print -r -- "class Error(Exception): pass" >"$output_dir/playwright/sync_api.py"'
  print -r -- 'print -r -- "def sync_playwright(): return None" >>"$output_dir/playwright/sync_api.py"'
} >"$fixture_repo/libexec/build-login-runtime.zsh"
/bin/chmod 755 "$fixture_repo/libexec/build-login-runtime.zsh"

print -r -- 'Host gpu-alias' >"$fixture_home/.ssh/config"
print -r -- '    HostName 192.0.2.10' >>"$fixture_home/.ssh/config"
print -r -- '    User test-user' >>"$fixture_home/.ssh/config"
/bin/chmod 600 "$fixture_home/.ssh/config"

unset XDG_STATE_HOME DISPLAY WAYLAND_DISPLAY
HOME="$fixture_home" "$fixture_repo/install.zsh" --non-interactive --target 192.0.2.10 --add-path >/dev/null || fail "fixture install failed"

manifest="$fixture_home/.local/lib/shanghaitech-shvpn/install.manifest.tsv"
/usr/bin/grep -Fx $'format\t4' "$manifest" >/dev/null || fail "manifest format is not 4"
/usr/bin/grep -Fx $'platform\t'"$expected_platform" "$manifest" >/dev/null || fail "manifest platform is incorrect"
/usr/bin/grep -F "$fixture_home/.local/bin" "$fixture_home/.profile" >/dev/null || fail "PATH block was not written to .profile"
[[ -d "$fixture_home/.local/state/shanghaitech-shvpn" ]] || fail "XDG default state directory was not created"

for installed_file in \
  "$fixture_home/.local/bin/shvpn" \
  "$fixture_home/.local/bin/shanghaitech-vpn" \
  "$fixture_home/.local/bin/shanghaitech-ssh-route" \
  "$fixture_home/.local/lib/shanghaitech-shvpn/configure-targets.zsh"; do
  [[ -x "$installed_file" ]] || fail "missing installed helper: $installed_file"
  ! /usr/bin/grep -F '@@' "$installed_file" >/dev/null || fail "unresolved template token: $installed_file"
done

ssh_output="$(HOME="$fixture_home" ssh -F "$fixture_home/.ssh/config" -G -- gpu-alias 2>/dev/null)" || fail "ssh -G rejected alias"
resolved_host="$(print -r -- "$ssh_output" | /usr/bin/awk '$1 == "hostname" {print $2; exit}')"
resolved_proxy="$(print -r -- "$ssh_output" | /usr/bin/awk '$1 == "proxycommand" {$1=""; sub(/^ /, ""); print; exit}')"
[[ "$resolved_host" == "192.0.2.10" ]] || fail "alias HostName was not preserved"
fixture_route="$fixture_home/.local/bin/shanghaitech-ssh-route"
[[ "$resolved_proxy" == "${(qqq)fixture_route} %h %p" ]] || fail "alias did not receive the managed route: $resolved_proxy"

set +e
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" doctor gpu-alias >"$test_tmp/doctor.out" 2>"$test_tmp/doctor.err"
doctor_rc=$?
set -e
[[ "$doctor_rc" == 0 ]] || {
  /bin/cat "$test_tmp/doctor.out" >&2
  /bin/cat "$test_tmp/doctor.err" >&2
  fail "doctor returned $doctor_rc"
}

set +e
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" login >"$test_tmp/login.out" 2>"$test_tmp/login.err"
login_rc=$?
set -e
[[ "$login_rc" == 69 ]] || fail "headless login returned $login_rc instead of 69"
/usr/bin/grep -F 'DISPLAY or WAYLAND_DISPLAY is unset' "$test_tmp/login.err" >/dev/null || fail "headless login diagnostic is missing"

# Reinstall must leave a live executable and all managed bytes untouched.
fixture_files=(
  .local/bin/zju-connect .local/bin/shanghaitech-vpn .local/bin/shvpn
  .local/bin/shanghaitech-ssh-route .config/shanghaitech-shvpn/targets.tsv
  .local/lib/shanghaitech-shvpn/configure-targets.zsh
  .local/lib/shanghaitech-shvpn/uninstall.zsh
  .local/lib/shanghaitech-shvpn/python-login-helper.py
  .local/lib/shanghaitech-shvpn/requirements-login.txt
  .local/lib/shanghaitech-shvpn/python-packages/playwright/__init__.py
  .local/lib/shanghaitech-shvpn/python-packages/playwright/sync_api.py
  .local/lib/shanghaitech-shvpn/install.manifest.tsv .ssh/config .profile
)
snapshot_fixture_files() (
  cd "$fixture_home"
  sha256sum -- "${fixture_files[@]}"
)
snapshot_fixture_files >"$test_tmp/before-running-reinstall.sha256"
client_inode="$(stat -c %i "$fixture_home/.local/bin/zju-connect")"
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" start >/dev/null || fail "fixture client did not start"
fixture_client_pid="$(lsof -nP -t -a -iTCP@127.0.0.1:$fixture_port -sTCP:LISTEN)"
[[ "$fixture_client_pid" == <-> ]] || fail "fixture listener identity is ambiguous"
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" status >/dev/null || fail "fixture client is not trusted"
set +e
HOME="$fixture_home" "$fixture_repo/install.zsh" --non-interactive --target 192.0.2.10 --add-path \
  >"$test_tmp/running-reinstall.out" 2>"$test_tmp/running-reinstall.err"
reinstall_rc=$?
set -e
[[ "$reinstall_rc" == 75 ]] || fail "running reinstall returned $reinstall_rc instead of 75"
/usr/bin/grep -F "run 'shvpn stop' when ready" "$test_tmp/running-reinstall.err" >/dev/null || fail "running reinstall diagnostic is missing"
snapshot_fixture_files >"$test_tmp/after-running-reinstall.sha256"
/usr/bin/cmp -s "$test_tmp/before-running-reinstall.sha256" "$test_tmp/after-running-reinstall.sha256" || fail "refused running reinstall changed managed bytes"
[[ "$(stat -c %i "$fixture_home/.local/bin/zju-connect")" == "$client_inode" ]] || fail "refused reinstall replaced the live client inode"
/bin/kill -0 "$fixture_client_pid" 2>/dev/null || fail "refused reinstall stopped the fixture client"
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" status >/dev/null || fail "refused reinstall made the fixture client untrusted"
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" stop >/dev/null || fail "cannot stop fixture client after refused reinstall"
fixture_client_pid=""
set +e
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" status >/dev/null
stopped_rc=$?
set -e
[[ "$stopped_rc" == 1 ]] || fail "fixture status did not report stopped"
HOME="$fixture_home" "$fixture_repo/install.zsh" --non-interactive --target 192.0.2.10 --add-path >/dev/null || fail "stopped reinstall failed"
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" doctor gpu-alias >/dev/null || fail "stopped reinstall did not preserve a healthy install"

# An unrelated listener also blocks replacement without being signalled.
nc -l 127.0.0.1 "$fixture_port" >/dev/null 2>&1 &
unrelated_listener_pid=$!
listener_ready=0
for (( i = 0; i < 40; i++ )); do
  if lsof -nP -a -p "$unrelated_listener_pid" -iTCP@127.0.0.1:$fixture_port -sTCP:LISTEN >/dev/null 2>&1; then
    listener_ready=1
    break
  fi
  /bin/sleep 0.05
done
(( listener_ready )) || fail "unrelated fixture listener did not start"
snapshot_fixture_files >"$test_tmp/before-unsafe-reinstall.sha256"
set +e
HOME="$fixture_home" "$fixture_repo/install.zsh" --non-interactive --target 192.0.2.10 --add-path \
  >"$test_tmp/unsafe-reinstall.out" 2>"$test_tmp/unsafe-reinstall.err"
reinstall_rc=$?
set -e
[[ "$reinstall_rc" == 2 ]] || fail "unsafe reinstall returned $reinstall_rc instead of 2"
snapshot_fixture_files >"$test_tmp/after-unsafe-reinstall.sha256"
/usr/bin/cmp -s "$test_tmp/before-unsafe-reinstall.sha256" "$test_tmp/after-unsafe-reinstall.sha256" || fail "refused unsafe reinstall changed managed bytes"
/bin/kill -0 "$unrelated_listener_pid" 2>/dev/null || fail "refused unsafe reinstall stopped an unrelated process"
/bin/kill -TERM "$unrelated_listener_pid"
wait "$unrelated_listener_pid" 2>/dev/null || true
unrelated_listener_pid=""

HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" add 192.0.2.20 >/dev/null || fail "add failed"
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" remove 192.0.2.20 >/dev/null || fail "remove failed"
HOME="$fixture_home" XDG_STATE_HOME="$fixture_home/changed-state-root" \
  "$fixture_home/.local/bin/shvpn" uninstall >/dev/null || fail "uninstall failed after XDG_STATE_HOME changed"

[[ ! -e "$fixture_home/.local/bin/shvpn" ]] || fail "uninstall left shvpn installed"
[[ ! -e "$fixture_home/.profile" ]] || fail "uninstall did not restore absent .profile"
[[ -f "$fixture_home/.ssh/config" ]] || fail "uninstall removed SSH config"
if /usr/bin/grep -F 'shanghaitech-shvpn managed SSH targets' "$fixture_home/.ssh/config" >/dev/null; then
  fail "uninstall left SSH marker"
fi

print -r -- "Linux installation integration tests passed."
