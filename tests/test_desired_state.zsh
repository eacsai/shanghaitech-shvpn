#!/usr/bin/env zsh

set -eu
setopt extendedglob
umask 077

typeset -gr project_root="${0:A:h:h}"

fail() {
  print -u2 -r -- "desired state test: $*"
  exit 1
}

case "$(uname -s)" in
  Darwin)
    platform_id="darwin-arm64"
    sha_bin="/usr/bin/shasum"
    stat_format=(-f)
    mode_format="%Lp"
    ;;
  Linux)
    platform_id="linux-amd64"
    sha_bin="$(command -v sha256sum)"
    stat_format=(-c)
    mode_format="%a"
    ;;
  *) fail "unsupported platform" ;;
esac
python_bin="$(command -v python3 2>/dev/null)" || fail "python3 is required for the fixture VPN client"
zsh_bin="$(command -v zsh)"
zsh_bin="${zsh_bin:A}"
current_uid="$(/usr/bin/id -u)"
unset DISPLAY WAYLAND_DISPLAY

temp_parent="${${TMPDIR:-/tmp}:A}"
test_tmp="$(/usr/bin/mktemp -d "$temp_parent/shvpn-desired-tests.XXXXXX")"
lock_holder_pid=""
fake_client_pid=""
cleanup() {
  local pid
  for pid in "${lock_holder_pid:-}" "${fake_client_pid:-}"; do
    if [[ "$pid" == <-> ]] && /bin/kill -0 "$pid" 2>/dev/null; then
      /bin/kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  [[ -d "$test_tmp" && "$test_tmp" == "$temp_parent"/shvpn-desired-tests.* ]] && /bin/rm -rf -- "$test_tmp"
}
trap cleanup EXIT INT TERM

fixture_home="$test_tmp/home"
bin_dir="$fixture_home/bin"
state_dir="$test_tmp/state dir"
desired="$state_dir/desired"
client="$bin_dir/zju-connect"
launcher="$bin_dir/shanghaitech-vpn"
shvpn="$bin_dir/shvpn"
listener_pid_file="$test_tmp/listener.pid"
launch_snapshot="$test_tmp/launch-desired"
client_command_file="$test_tmp/client-command"
/usr/bin/install -d -m 700 "$fixture_home" "$bin_dir"

file_mode() {
  /usr/bin/stat "${stat_format[@]}" "$mode_format" -- "$1"
}

file_uid() {
  /usr/bin/stat "${stat_format[@]}" %u -- "$1"
}

file_inode() {
  /usr/bin/stat "${stat_format[@]}" %i -- "$1"
}

print -r -- '#!/bin/sh' >"$client"
print -r -- 'exit 0' >>"$client"

# The launcher records what the desired file held when the start work began,
# then fails like a client whose saved login has expired.
{
  print -r -- '#!/bin/zsh'
  print -r -- "desired=${(qqq)desired}"
  print -r -- "snapshot=${(qqq)launch_snapshot}"
  print -r -- 'if [[ -L "$desired" ]]; then print -r -- symlink >"$snapshot"'
  print -r -- 'elif [[ -f "$desired" ]]; then /bin/cat -- "$desired" >"$snapshot"'
  print -r -- 'elif [[ -e "$desired" ]]; then print -r -- not-regular >"$snapshot"'
  print -r -- 'else print -r -- missing >"$snapshot"; fi'
  print -r -- 'exit 7'
} >"$launcher"

# Listener discovery is faked so the fixture never probes the real SOCKS port.
{
  print -r -- '#!/bin/zsh'
  print -r -- "listener_pid_file=${(qqq)listener_pid_file}"
  print -r -- "client=${(qqq)client}"
  print -r -- 'if [[ "$*" == *-iTCP@* ]]; then'
  print -r -- '  [[ -f "$listener_pid_file" ]] || exit 1'
  print -r -- '  pid="$(<"$listener_pid_file")"'
  print -r -- '  /bin/kill -0 "$pid" 2>/dev/null || exit 1'
  print -r -- '  print -r -- "p$pid"'
  print -r -- '  exit 0'
  print -r -- 'fi'
  print -r -- '[[ "$*" == *"-d txt"* ]] && { print -r -- "n$client"; exit 0; }'
  print -r -- 'exit 1'
} >"$bin_dir/fake-lsof"
{
  print -r -- '#!/bin/zsh'
  print -r -- "client_command_file=${(qqq)client_command_file}"
  print -r -- '[[ "$*" == *"-o uid="* ]] && { /usr/bin/id -u; exit 0; }'
  print -r -- '[[ "$*" == *"-o command="* ]] && { /bin/cat -- "$client_command_file"; exit 0; }'
  print -r -- 'exit 1'
} >"$bin_dir/fake-ps"
print -r -- '#!/bin/sh' >"$bin_dir/fake-nc"
print -r -- 'exit 1' >>"$bin_dir/fake-nc"
/bin/chmod 755 "$client" "$launcher" "$bin_dir/fake-lsof" "$bin_dir/fake-ps" "$bin_dir/fake-nc"
socks_bind="$(/usr/bin/sed -n 's/^typeset -gr bind_host="\(.*\)"$/\1/p' "$project_root/libexec/shvpn.zsh"):$(/usr/bin/sed -n 's/^typeset -gr bind_port="\(.*\)"$/\1/p' "$project_root/libexec/shvpn.zsh")"
[[ "$socks_bind" == 127.0.0.1:<-> ]] || fail "cannot read the SOCKS bind address from the template"
print -r -- "$client -protocol atrust -server vpn.shanghaitech.edu.cn -port 443 -login-domain Shanghaitech.edu.cn -auth-type auth/cas -client-data-file $state_dir/client-data.json -socks-bind $socks_bind -http-bind  -auto-detect-interface" >"$client_command_file"

missing="$test_tmp/not-installed"
typeset -A tokens
tokens=(
  CLIENT_Q "$client"
  LAUNCHER_Q "$launcher"
  SHVPN_Q "$shvpn"
  STATE_DIR_Q "$state_dir"
  TARGETS_Q "$missing/targets.tsv"
  ROUTE_Q "$missing/shanghaitech-ssh-route"
  ROUTE_PROXY_Q "$missing/shanghaitech-ssh-route %h %p"
  SSH_CONFIG_Q "$missing/ssh-config"
  MANIFEST_Q "$missing/install.manifest.tsv"
  CONFIG_HELPER_Q "$missing/configure-targets.zsh"
  UNINSTALL_HELPER_Q "$missing/uninstall.zsh"
  CONFIG_LOCK_Q "$state_dir/shvpn.config.lock"
  LOGIN_HELPER_Q "$missing/python-login-helper.py"
  LOGIN_REQUIREMENTS_Q "$missing/requirements-login.txt"
  LOGIN_PACKAGES_Q "$missing/python-packages"
  PLATFORM_ID_Q "$platform_id"
  STAT_BIN_Q "/usr/bin/stat"
  SHA_BIN_Q "$sha_bin"
  NC_BIN_Q "$bin_dir/fake-nc"
  LSOF_BIN_Q "$bin_dir/fake-lsof"
  PS_BIN_Q "$bin_dir/fake-ps"
  PGREP_BIN_Q "/usr/bin/pgrep"
  ZSH_BIN_Q "$zsh_bin"
  NOHUP_BIN_Q "/usr/bin/nohup"
  CHROME_BIN_Q "$missing/google-chrome"
  SSH_BIN_Q "/usr/bin/ssh"
)
content="$(<"$project_root/libexec/shvpn.zsh")"
for token in ${(k)tokens}; do
  content="${content//@@${token}@@/${(qqq)tokens[$token]}}"
done
[[ "$content" != *'@@'* ]] || fail "unresolved shvpn template token"
print -rn -- "$content" >"$shvpn"
/bin/chmod 755 "$shvpn"
"$zsh_bin" -n "$shvpn" || fail "rendered shvpn has a syntax error"

run_shvpn() {
  local name="$1"
  shift
  set +e
  HOME="$fixture_home" TMPDIR="$test_tmp/absent-tmpdir" "$shvpn" "$@" </dev/null >"$test_tmp/$name.out" 2>"$test_tmp/$name.err"
  REPLY=$?
  set -e
}

expect_rc() {
  local name="$1"
  local expected="$2"
  [[ "$REPLY" == "$expected" ]] || {
    /bin/cat -- "$test_tmp/$name.out" "$test_tmp/$name.err" >&2
    fail "$name returned $REPLY instead of $expected"
  }
}

expect_no_warning() {
  local name="$1"
  if /usr/bin/grep -F 'warning' "$test_tmp/$name.err" >/dev/null 2>&1; then
    /bin/cat -- "$test_tmp/$name.err" >&2
    fail "$name printed an unexpected warning"
  fi
}

expect_one_warning() {
  local name="$1"
  local count
  count="$(/usr/bin/grep -c 'shvpn: warning: .*desired' "$test_tmp/$name.err" 2>/dev/null || true)"
  [[ "$count" == 1 ]] || {
    /bin/cat -- "$test_tmp/$name.err" >&2
    fail "$name printed $count desired-state warnings instead of 1"
  }
}

assert_desired() {
  local expected="$1"
  local context="$2"
  local -a leftovers
  [[ -f "$desired" && ! -L "$desired" ]] || fail "$context: desired state is not a regular file"
  [[ "$(file_mode "$desired")" == 600 ]] || fail "$context: desired state mode is $(file_mode "$desired")"
  [[ "$(file_uid "$desired")" == "$current_uid" ]] || fail "$context: desired state is not owned by the user"
  print -r -- "$expected" >"$test_tmp/expected-desired"
  /usr/bin/cmp -s "$test_tmp/expected-desired" "$desired" || fail "$context: desired state is not exactly '$expected' plus newline"
  leftovers=("$state_dir"/.desired.*(N))
  (( ${#leftovers} == 0 )) || fail "$context: temporary desired-state files were left behind"
}

# Background jobs start with SIGINT ignored, so wait until the fixture client
# has installed its handler before shvpn may send it SIGINT.
start_fake_client() {
  local client_ready="$test_tmp/client.ready"
  local i
  /bin/rm -f -- "$client_ready"
  "$python_bin" -I -B -c '
import pathlib, signal, sys, time
signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
pathlib.Path(sys.argv[1]).write_text("ready")
while True:
    time.sleep(0.05)
' "$client_ready" &
  fake_client_pid=$!
  for (( i = 0; i < 250; i++ )); do
    [[ -f "$client_ready" ]] && break
    /bin/sleep 0.02
  done
  [[ -f "$client_ready" ]] || fail "fixture VPN client did not become ready"
  print -r -- "$fake_client_pid" >"$listener_pid_file"
}

# start records intent before any start work and keeps the start result.
[[ ! -e "$state_dir" ]] || fail "fixture state directory already exists"
run_shvpn fresh-start start
expect_rc fresh-start 1
/usr/bin/grep -F 'VPN start exited with status 7' "$test_tmp/fresh-start.err" >/dev/null || fail "fixture start did not reach the launcher"
assert_desired up "start"
[[ "$(<"$launch_snapshot")" == "up" ]] || fail "start launched the VPN before recording 'up' (saw $(<"$launch_snapshot"))"
expect_no_warning fresh-start

run_shvpn stopped-stop stop
expect_rc stopped-stop 0
[[ "$(<"$test_tmp/stopped-stop.out")" == "ShanghaiTech VPN is already stopped." ]] || fail "stop output changed"
assert_desired down "stop"
expect_no_warning stopped-stop

# A stale file with another mode is replaced by rename, never rewritten in place.
print -r -- junk >"$desired"
/bin/chmod 644 "$desired"
old_inode="$(file_inode "$desired")"
run_shvpn bare-start
expect_rc bare-start 1
assert_desired up "bare shvpn"
[[ "$(file_inode "$desired")" != "$old_inode" ]] || fail "desired state was rewritten in place instead of renamed"

run_shvpn login-reset stop
expect_rc login-reset 0
assert_desired down "stop before login"
run_shvpn headless-login login
expect_rc headless-login 69
assert_desired up "failed login"
expect_no_warning headless-login

# Commands other than start, stop and login leave the file untouched.
run_shvpn untouched-reset stop
expect_rc untouched-reset 0
untouched_inode="$(file_inode "$desired")"
typeset -A untouched_rc
untouched_rc=(
  status 1
  doctor 2
  reconnect 2
  "add 192.0.2.10" 69
  "remove 192.0.2.10" 69
  uninstall 69
  "start extra" 64
  "stop extra" 64
  "login extra" 64
  unknown 64
)
for untouched_command in ${(k)untouched_rc}; do
  run_shvpn untouched ${(z)untouched_command}
  expect_rc untouched "${untouched_rc[$untouched_command]}"
  assert_desired down "$untouched_command"
  [[ "$(file_inode "$desired")" == "$untouched_inode" ]] || fail "$untouched_command replaced the desired state"
  expect_no_warning untouched
done

# Without the operation or configuration lock nothing is recorded.
lock_ready="$test_tmp/lock.ready"
{
  print -r -- '#!/bin/zsh'
  print -r -- 'set -eu'
  print -r -- 'zmodload zsh/system'
  print -r -- 'typeset -g held_fd'
  print -r -- 'zsystem flock -f held_fd -e "$1"'
  print -r -- 'print -r -- ready >"$2"'
  print -r -- 'while true; do /bin/sleep 0.1; done'
} >"$test_tmp/hold-lock.zsh"
/bin/chmod 700 "$test_tmp/hold-lock.zsh"
for held_lock in shvpn.operation.lock shvpn.config.lock; do
  /bin/rm -f -- "$lock_ready"
  "$test_tmp/hold-lock.zsh" "$state_dir/$held_lock" "$lock_ready" &
  lock_holder_pid=$!
  for (( i = 0; i < 100; i++ )); do
    [[ -f "$lock_ready" ]] && break
    /bin/sleep 0.02
  done
  [[ -f "$lock_ready" ]] || fail "$held_lock holder did not become ready"
  for contended_command in start stop login; do
    run_shvpn contended "$contended_command"
    expect_rc contended 75
    assert_desired down "$contended_command while $held_lock is held"
    [[ "$(file_inode "$desired")" == "$untouched_inode" ]] || fail "$contended_command wrote the desired state without $held_lock"
  done
  /bin/kill -TERM "$lock_holder_pid"
  wait "$lock_holder_pid" 2>/dev/null || true
  lock_holder_pid=""
done

# The same intent is recorded whatever a running VPN makes of the command.
start_fake_client
run_shvpn running-login login
expect_rc running-login 2
assert_desired up "login while running"
run_shvpn running-stop stop
expect_rc running-stop 0
[[ "$(<"$test_tmp/running-stop.out")" == "ShanghaiTech VPN stopped." ]] || fail "trusted fixture client was not stopped"
wait "$fake_client_pid" 2>/dev/null || true
fake_client_pid=""
assert_desired down "stop while running"
start_fake_client
run_shvpn running-start start
expect_rc running-start 0
/usr/bin/grep -F 'ShanghaiTech VPN is already running' "$test_tmp/running-start.out" >/dev/null || fail "start did not see the running fixture client"
assert_desired up "start while running"
run_shvpn running-stop-again stop
expect_rc running-stop-again 0
wait "$fake_client_pid" 2>/dev/null || true
fake_client_pid=""
assert_desired down "second stop while running"

# A path that cannot be replaced safely gives one warning and the normal result.
/bin/rm -f -- "$desired"
/usr/bin/install -d -m 700 "$desired"
run_shvpn dir-start start
expect_rc dir-start 1
expect_one_warning dir-start
[[ "$(<"$launch_snapshot")" == "not-regular" ]] || fail "directory desired path was replaced"
run_shvpn dir-stop stop
expect_rc dir-stop 0
expect_one_warning dir-stop
[[ "$(<"$test_tmp/dir-stop.out")" == "ShanghaiTech VPN is already stopped." ]] || fail "stop output changed after a failed desired-state write"
[[ "${$(/usr/bin/wc -l <"$test_tmp/dir-stop.err")//[[:space:]]/}" == 1 ]] || fail "failed desired-state write printed more than one line"
[[ -d "$desired" && ! -L "$desired" ]] || fail "directory desired path was replaced"
directory_entries=("$desired"/*(DN))
(( ${#directory_entries} == 0 )) || fail "desired state was written inside a directory"
/bin/rmdir -- "$desired"

outside_target="$test_tmp/outside-desired"
print -r -- down >"$outside_target"
/bin/chmod 600 "$outside_target"
/bin/ln -s "$outside_target" "$desired"
for symlink_command in start stop login; do
  run_shvpn symlink "$symlink_command"
  case "$symlink_command" in
    start) expect_rc symlink 1 ;;
    stop) expect_rc symlink 0 ;;
    login) expect_rc symlink 69 ;;
  esac
  expect_one_warning symlink
  [[ -L "$desired" && "$(/usr/bin/readlink "$desired")" == "$outside_target" ]] || fail "$symlink_command replaced a symlinked desired path"
  [[ "$(<"$outside_target")" == "down" ]] || fail "$symlink_command wrote through a symlinked desired path"
done
/bin/rm -f -- "$desired"
/bin/ln -s "$test_tmp/absent-target" "$desired"
run_shvpn dangling-stop stop
expect_rc dangling-stop 0
expect_one_warning dangling-stop
[[ -L "$desired" && ! -e "$test_tmp/absent-target" ]] || fail "stop replaced or followed a dangling desired symlink"

print -r -- "Desired-state tests passed."
