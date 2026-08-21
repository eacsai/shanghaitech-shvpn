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

temp_parent="${${TMPDIR:-/tmp}:A}"
test_tmp="$(mktemp -d "$temp_parent/shvpn-linux-tests.XXXXXX")"
cleanup() {
  [[ -d "$test_tmp" && "$test_tmp" == "$temp_parent"/shvpn-linux-tests.* ]] && /bin/rm -rf -- "$test_tmp"
}
trap cleanup EXIT INT TERM

fixture_repo="$test_tmp/repo"
fixture_home="$test_tmp/home"
/bin/cp -R "$project_root" "$fixture_repo"
/usr/bin/install -d -m 700 "$fixture_home/.ssh"

{
  print -r -- '#!/usr/bin/env zsh'
  print -r -- 'set -eu'
  print -r -- '/bin/cp /usr/bin/true "$1"'
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
[[ "$resolved_proxy" == "$fixture_home/.local/bin/shanghaitech-ssh-route %h %p" ]] || fail "alias did not receive the managed route"

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
