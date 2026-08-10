#!/bin/zsh

set -eu
setopt extendedglob
umask 077

typeset -gr project_root="${0:A:h:h}"
typeset -gr upstream_commit="a759261b76ed653900911559400005b40a31392a"
typeset -gr go_mod_sha="d06b5a0423a5ce23887222d1e3f2b06b0f1c63f16873d87887c0c1147a5f7204"
typeset -gr go_sum_sha="8af52b375ebe736a54883a39bdffff6cdfb8f55face981cbbd13e3362e2e0572"
typeset -gr begin_ssh="# >>> shanghaitech-shvpn managed SSH targets >>>"
typeset -gr begin_path="# >>> shanghaitech-shvpn managed PATH >>>"

fail() {
  print -u2 -r -- "test: $*"
  exit 1
}

assert_file_mode() {
  local expected="$1"
  local file="$2"
  local actual="$(/usr/bin/stat -f %Lp "$file")"
  [[ "$actual" == "$expected" ]] || fail "$file mode is $actual, expected $expected"
}

assert_count() {
  local expected="$1"
  local pattern="$2"
  local file="$3"
  local actual="$(/usr/bin/grep -Fxc -- "$pattern" "$file" 2>/dev/null || true)"
  [[ "$actual" == "$expected" ]] || fail "$file contains $actual copies of $pattern, expected $expected"
}

for script in "$project_root"/*.zsh "$project_root"/libexec/*.zsh "$project_root"/tests/*.zsh; do
  /bin/zsh -n "$script" || fail "zsh syntax failed: $script"
done

expected_paths=(
  .github/workflows/ci.yml
  .gitignore
  CODEX_SETUP.md
  LICENSE
  NOTICE.md
  README.md
  SECURITY.md
  config/targets.example.tsv
  install.zsh
  libexec/build-client.zsh
  libexec/shanghaitech-ssh-route.zsh
  libexec/shanghaitech-vpn.zsh
  libexec/shvpn.zsh
  patches/zju-connect-v1.2.2-node-selection.patch
  tests/test.zsh
  uninstall.zsh
)
actual_paths=("${(@f)$(/usr/bin/git -C "$project_root" ls-files | LC_ALL=C /usr/bin/sort)}")
[[ "${(j:\n:)actual_paths}" == "${(j:\n:)expected_paths}" ]] || {
  print -u2 -r -- "Expected manifest:"
  print -u2 -l -- "${expected_paths[@]}"
  print -u2 -r -- "Actual manifest:"
  print -u2 -l -- "${actual_paths[@]}"
  fail "repository path manifest differs"
}
tracked_files=("${(@)^actual_paths/#/$project_root/}")

for forbidden in \
  '/Use''rs/' \
  '-----BEGIN OPENSSH PRIVATE ''KEY-----' \
  '-----BEGIN RSA PRIVATE ''KEY-----'; do
  if LC_ALL=C /usr/bin/grep -n -F -- "$forbidden" "${tracked_files[@]}" >/dev/null 2>&1; then
    fail "forbidden private pattern found: $forbidden"
  fi
done

if LC_ALL=C /usr/bin/grep -n -E \
  '(^|[^0-9])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}|169\.254\.[0-9]{1,3}\.[0-9]{1,3})([^0-9]|$)' \
  "${tracked_files[@]}" >/dev/null 2>&1; then
  fail "private, CGNAT, or link-local IPv4 literal found"
fi
if LC_ALL=C /usr/bin/grep -n -Ei \
  '(^|[^0-9a-f:])(f[cd][0-9a-f]{2}:|fe[89ab][0-9a-f]:)' "${tracked_files[@]}" >/dev/null 2>&1; then
  fail "ULA or link-local IPv6 literal found"
fi
ipv4_literals=("${(@f)$(LC_ALL=C /usr/bin/grep -h -o -E \
  '(^|[^0-9])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$)' "${tracked_files[@]}" 2>/dev/null | \
  /usr/bin/sed -E 's/^[^0-9]*//; s/[^0-9]*$//' | LC_ALL=C /usr/bin/sort -u)}")
for ipv4 in "${ipv4_literals[@]}"; do
  [[ "$ipv4" == "127.0.0.1" || "$ipv4" == 192.0.2.<0-255> ]] || fail "non-documentation IPv4 literal found: $ipv4"
done

for file in "${actual_paths[@]}"; do
  LC_ALL=C /usr/bin/grep -Iq . "$project_root/$file" || [[ ! -s "$project_root/$file" ]] || fail "binary or NUL-containing file found: $file"
done

temp_parent="${${TMPDIR:-/tmp}:A}"
[[ -d "$temp_parent" && "$temp_parent" == /* ]] || fail "unsafe TMPDIR"
test_tmp="$(/usr/bin/mktemp -d "$temp_parent/shvpn-tests.XXXXXX")"
lifecycle_started=0
unrelated_listener_pid=""
cleanup() {
  if (( ${lifecycle_started:-0} )) && [[ -x "${fixture_home:-}/.local/bin/shvpn" ]]; then
    HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" stop >/dev/null 2>&1 || true
  fi
  if [[ "${unrelated_listener_pid:-}" == <-> ]] && /bin/kill -0 "$unrelated_listener_pid" 2>/dev/null; then
    /bin/kill -TERM "$unrelated_listener_pid" 2>/dev/null || true
    wait "$unrelated_listener_pid" 2>/dev/null || true
  fi
  if [[ -n "${test_tmp:-}" && -d "$test_tmp" && "$test_tmp" == "$temp_parent"/shvpn-tests.* ]]; then
    /bin/rm -rf -- "$test_tmp"
  fi
}
trap cleanup EXIT INT TERM

fixture_repo="$test_tmp/repo"
fixture_home="$test_tmp/Fixture Home"
fake_bin="$test_tmp/fake-bin"
/bin/cp -R "$project_root" "$fixture_repo"
/usr/bin/install -d -m 700 "$fixture_home/.ssh" "$fake_bin"

# Keep fixture lifecycle checks isolated from a real shvpn listener on the test Mac.
for fixture_template in shanghaitech-vpn.zsh shvpn.zsh shanghaitech-ssh-route.zsh; do
  /usr/bin/sed 's/11080/19180/g' "$fixture_repo/libexec/$fixture_template" >"$test_tmp/$fixture_template"
  /usr/bin/install -m 755 "$test_tmp/$fixture_template" "$fixture_repo/libexec/$fixture_template"
done

{
  print -r -- '#!/bin/zsh'
  print -r -- 'set -eu'
  print -r -- '/bin/cp /usr/bin/true "$1"'
  print -r -- '/bin/chmod 755 "$1"'
} >"$fixture_repo/libexec/build-client.zsh"
/bin/chmod 755 "$fixture_repo/libexec/build-client.zsh"
{
  print -r -- '#!/bin/zsh'
  print -r -- 'print -r -- "go version go1.25.6 darwin/arm64"'
} >"$fake_bin/go"
/bin/chmod 755 "$fake_bin/go"

print -r -- 'Host keep' >"$fixture_home/.ssh/config"
print -r -- '    HostName 192.0.2.30' >>"$fixture_home/.ssh/config"
print -r -- '# existing zsh content' >"$fixture_home/.zshrc"
/usr/bin/install -d -m 700 "$fixture_home/.local/bin"
print -r -- '#!/bin/zsh' >"$fixture_home/.local/bin/zju-connect"
print -r -- 'print preexisting-client' >>"$fixture_home/.local/bin/zju-connect"
/bin/chmod 755 "$fixture_home/.local/bin/zju-connect"
/bin/cp -p "$fixture_home/.ssh/config" "$test_tmp/original-ssh-config"
/bin/cp -p "$fixture_home/.zshrc" "$test_tmp/original-zshrc"
/bin/cp -p "$fixture_home/.local/bin/zju-connect" "$test_tmp/original-zju-connect"

fixture_path="$fake_bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
HOME="$fixture_home" PATH="$fixture_path" "$fixture_repo/install.zsh" --non-interactive \
  --target gpu 192.0.2.10 22 alice \
  --target gpu2 192.0.2.20 2222 - \
  --add-path

for executable in zju-connect shanghaitech-vpn shvpn shanghaitech-ssh-route; do
  [[ -x "$fixture_home/.local/bin/$executable" && ! -L "$fixture_home/.local/bin/$executable" ]] || fail "missing installed executable: $executable"
  assert_file_mode 755 "$fixture_home/.local/bin/$executable"
done
assert_file_mode 600 "$fixture_home/.config/shanghaitech-shvpn/targets.tsv"
assert_file_mode 600 "$fixture_home/.local/lib/shanghaitech-shvpn/install.manifest.tsv"
assert_count 1 "$begin_ssh" "$fixture_home/.ssh/config"
assert_count 1 "$begin_path" "$fixture_home/.zshrc"

{
  print -r -- $'gpu\t192.0.2.10\t22\talice'
  print -r -- $'gpu2\t192.0.2.20\t2222\t-'
} >"$test_tmp/expected-targets.tsv"
/usr/bin/cmp -s "$test_tmp/expected-targets.tsv" "$fixture_home/.config/shanghaitech-shvpn/targets.tsv" || fail "target TSV differs"

for rendered in shanghaitech-vpn shvpn shanghaitech-ssh-route; do
  if /usr/bin/grep -F '@@' "$fixture_home/.local/bin/$rendered" >/dev/null 2>&1; then
    fail "unresolved template token in $rendered"
  fi
done
/usr/bin/grep -F -- "$fixture_home/.local/bin/zju-connect" "$fixture_home/.local/bin/shvpn" >/dev/null || fail "shvpn does not bind the physical client path"
/usr/bin/grep -F -- "$fixture_home/.config/shanghaitech-shvpn/targets.tsv" "$fixture_home/.local/bin/shanghaitech-ssh-route" >/dev/null || fail "route helper does not bind the physical targets path"
/usr/bin/grep -F -- '-http-bind  -auto-detect-interface' "$fixture_home/.local/bin/shvpn" >/dev/null || fail "trusted argv lost the empty http-bind field"

route_path="$fixture_home/.local/bin/shanghaitech-ssh-route"
route_q="${(qqq)route_path}"
ssh_output="$(/usr/bin/ssh -F "$fixture_home/.ssh/config" -G gpu 2>/dev/null)"
[[ "$(print -r -- "$ssh_output" | /usr/bin/awk '$1 == "hostname" {print $2; exit}')" == "192.0.2.10" ]] || fail "ssh hostname mismatch"
[[ "$(print -r -- "$ssh_output" | /usr/bin/awk '$1 == "port" {print $2; exit}')" == "22" ]] || fail "ssh port mismatch"
[[ "$(print -r -- "$ssh_output" | /usr/bin/awk '$1 == "user" {print $2; exit}')" == "alice" ]] || fail "ssh user mismatch"
actual_proxy="$(print -r -- "$ssh_output" | /usr/bin/awk '$1 == "proxycommand" {$1=""; sub(/^ /, ""); print; exit}')"
[[ "$actual_proxy" == "$route_q %h %p" ]] || fail "ssh ProxyCommand mismatch: got [$actual_proxy], expected [$route_q %h %p]"
keep_output="$(/usr/bin/ssh -F "$fixture_home/.ssh/config" -G keep 2>/dev/null)"
if print -r -- "$keep_output" | /usr/bin/grep -q '^proxycommand '; then
  fail "unmanaged SSH alias received a ProxyCommand"
fi

set +e
HOME="$fixture_home" "$fixture_home/.local/bin/shanghaitech-ssh-route" 192.0.2.99 22 >/dev/null 2>&1
route_rc=$?
set -e
[[ "$route_rc" == 64 ]] || fail "route helper did not reject an unlisted target"

if [[ "${SHVPN_RUN_UPSTREAM:-0}" == "1" ]]; then
  command -v go >/dev/null 2>&1 || fail "Go is required for lifecycle tests"
  [[ "$(go version)" == "go version go1.25.6 darwin/arm64" ]] || fail "lifecycle gate requires go1.25.6 darwin/arm64"
  {
    print -r -- 'package main'
    print -r -- 'import ('
    print -r -- '  "net"'
    print -r -- '  "os"'
    print -r -- '  "os/signal"'
    print -r -- ')'
    print -r -- 'func main() {'
    print -r -- '  listener, err := net.Listen("tcp", "127.0.0.1:19180")'
    print -r -- '  if err != nil { panic(err) }'
    print -r -- '  signals := make(chan os.Signal, 1)'
    print -r -- '  signal.Notify(signals, os.Interrupt)'
    print -r -- '  <-signals'
    print -r -- '  _ = listener.Close()'
    print -r -- '}'
  } >"$test_tmp/fake-client.go"
  GOTOOLCHAIN=local CGO_ENABLED=0 go build -trimpath -o "$test_tmp/fake-zju-connect" "$test_tmp/fake-client.go"
  /bin/cp -p "$fixture_home/.local/bin/zju-connect" "$test_tmp/fixture-installed-client"
  /usr/bin/install -m 755 "$test_tmp/fake-zju-connect" "$fixture_home/.local/bin/zju-connect"
  HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" start >/dev/null
  lifecycle_started=1
  HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" status >/dev/null || fail "trusted lifecycle status did not report running"
  HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" start >/dev/null || fail "repeated trusted start was not idempotent"
  HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" stop >/dev/null || fail "trusted lifecycle stop failed"
  lifecycle_started=0
  set +e
  HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" status >/dev/null
  stopped_rc=$?
  set -e
  [[ "$stopped_rc" == 1 ]] || fail "trusted lifecycle status did not report stopped"
  /bin/cp -p "$test_tmp/fixture-installed-client" "$fixture_home/.local/bin/zju-connect"
fi

/bin/cp -p "$fixture_home/.local/bin/shvpn" "$test_tmp/real-shvpn"
{
  print -r -- '#!/bin/zsh'
  print -r -- 'exit 2'
} >"$fixture_home/.local/bin/shvpn"
/bin/chmod 755 "$fixture_home/.local/bin/shvpn"
set +e
HOME="$fixture_home" "$fixture_home/.local/bin/shanghaitech-ssh-route" 192.0.2.10 22 >/dev/null 2>&1
route_rc=$?
set -e
[[ "$route_rc" == 255 ]] || fail "route helper did not fail closed on ambiguous shvpn status"
/bin/cp -p "$test_tmp/real-shvpn" "$fixture_home/.local/bin/shvpn"

first_backup_count="$(/usr/bin/find "$fixture_home/.local/lib/shanghaitech-shvpn/backups" -mindepth 1 -maxdepth 1 -type d | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
HOME="$fixture_home" PATH="$fixture_path" "$fixture_repo/install.zsh" --non-interactive \
  --target gpu 192.0.2.10 22 alice \
  --target gpu2 192.0.2.20 2222 - \
  --add-path
assert_count 1 "$begin_ssh" "$fixture_home/.ssh/config"
assert_count 1 "$begin_path" "$fixture_home/.zshrc"
second_backup_count="$(/usr/bin/find "$fixture_home/.local/lib/shanghaitech-shvpn/backups" -mindepth 1 -maxdepth 1 -type d | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
(( second_backup_count > first_backup_count )) || fail "idempotent reinstall did not preserve a new backup"

/bin/cp -p "$fixture_home/.ssh/config" "$test_tmp/installed-ssh-config"
client_before="$(/usr/bin/shasum -a 256 "$fixture_home/.local/bin/zju-connect" | /usr/bin/awk '{print $1}')"
/usr/bin/sed 's/HostName 192\.0\.2\.10/HostName 192.0.2.11/' "$fixture_home/.ssh/config" >"$test_tmp/modified-ssh-config"
/usr/bin/install -m 600 "$test_tmp/modified-ssh-config" "$fixture_home/.ssh/config"
set +e
HOME="$fixture_home" PATH="$fixture_path" "$fixture_repo/uninstall.zsh" >/dev/null 2>&1
uninstall_rc=$?
set -e
[[ "$uninstall_rc" == 2 ]] || fail "uninstall did not fail closed on a modified managed block"
client_after="$(/usr/bin/shasum -a 256 "$fixture_home/.local/bin/zju-connect" | /usr/bin/awk '{print $1}')"
[[ "$client_before" == "$client_after" ]] || fail "failed uninstall changed a managed binary"
/usr/bin/cmp -s "$test_tmp/modified-ssh-config" "$fixture_home/.ssh/config" || fail "failed uninstall changed the modified config"
/usr/bin/install -m 600 "$test_tmp/installed-ssh-config" "$fixture_home/.ssh/config"

/usr/bin/nc -l 127.0.0.1 19180 >/dev/null 2>&1 &
unrelated_listener_pid=$!
listener_ready=0
for (( i = 0; i < 40; i++ )); do
  if /usr/sbin/lsof -nP -a -p "$unrelated_listener_pid" -iTCP@127.0.0.1:19180 -sTCP:LISTEN >/dev/null 2>&1; then
    listener_ready=1
    break
  fi
  /bin/sleep 0.05
done
(( listener_ready )) || fail "unrelated fixture listener did not start"
HOME="$fixture_home" PATH="$fixture_path" "$fixture_repo/uninstall.zsh" >"$test_tmp/uninstall.out" 2>"$test_tmp/uninstall.err"
/bin/kill -0 "$unrelated_listener_pid" 2>/dev/null || fail "uninstall stopped an unrelated listener"
/usr/bin/grep -F 'leaving that process untouched and continuing' "$test_tmp/uninstall.err" >/dev/null || fail "uninstall did not warn about the unrelated listener"
/bin/kill -TERM "$unrelated_listener_pid"
wait "$unrelated_listener_pid" 2>/dev/null || true
unrelated_listener_pid=""
/usr/bin/cmp -s "$test_tmp/original-ssh-config" "$fixture_home/.ssh/config" || fail "SSH config baseline was not restored"
/usr/bin/cmp -s "$test_tmp/original-zshrc" "$fixture_home/.zshrc" || fail ".zshrc baseline was not restored"
/usr/bin/cmp -s "$test_tmp/original-zju-connect" "$fixture_home/.local/bin/zju-connect" || fail "pre-existing zju-connect was not restored"
[[ ! -e "$fixture_home/.local/bin/shvpn" && ! -e "$fixture_home/.local/bin/shanghaitech-vpn" && ! -e "$fixture_home/.local/bin/shanghaitech-ssh-route" ]] || fail "new managed binaries remain after uninstall"
[[ ! -e "$fixture_home/.config/shanghaitech-shvpn/targets.tsv" ]] || fail "target TSV remains after uninstall"
[[ ! -e "$fixture_home/.local/lib/shanghaitech-shvpn/install.manifest.tsv" ]] || fail "manifest was not consumed after uninstall"

HOME="$fixture_home" PATH="$fixture_path" "$fixture_repo/install.zsh" --non-interactive \
  --target gpu 192.0.2.10 22 alice \
  --add-path >/dev/null
HOME="$fixture_home" PATH="$fixture_path" "$fixture_repo/uninstall.zsh" >/dev/null
/usr/bin/cmp -s "$test_tmp/original-ssh-config" "$fixture_home/.ssh/config" || fail "reinstall cycle did not restore SSH config"
/usr/bin/cmp -s "$test_tmp/original-zju-connect" "$fixture_home/.local/bin/zju-connect" || fail "reinstall cycle did not restore zju-connect"
[[ ! -e "$fixture_home/.local/lib/shanghaitech-shvpn" ]] || fail "active metadata namespace remains after reinstall cycle"

print -r -- '' | HOME="$fixture_home" PATH="$fixture_path" "$fixture_repo/install.zsh" --no-path >/dev/null
assert_count 0 "$begin_path" "$fixture_home/.zshrc"
HOME="$fixture_home" PATH="$fixture_path" "$fixture_repo/uninstall.zsh" >/dev/null
/usr/bin/cmp -s "$test_tmp/original-zshrc" "$fixture_home/.zshrc" || fail "interactive --no-path cycle changed .zshrc"

if [[ "${SHVPN_RUN_UPSTREAM:-0}" == "1" ]]; then
  command -v go >/dev/null 2>&1 || fail "Go is required for upstream tests"
  [[ "$(go version)" == "go version go1.25.6 darwin/arm64" ]] || fail "upstream gate requires go1.25.6 darwin/arm64"
  upstream_dir="$test_tmp/upstream"
  pristine_dir="$test_tmp/pristine"
  patched_dir="$test_tmp/patched"
  /usr/bin/git -c advice.detachedHead=false clone --quiet --depth 1 --branch v1.2.2 \
    https://github.com/Mythologyli/zju-connect.git "$upstream_dir"
  [[ "$(/usr/bin/git -C "$upstream_dir" rev-parse HEAD)" == "$upstream_commit" ]] || fail "upstream commit mismatch"
  [[ "$(/usr/bin/shasum -a 256 "$upstream_dir/go.mod" | /usr/bin/awk '{print $1}')" == "$go_mod_sha" ]] || fail "go.mod hash mismatch"
  [[ "$(/usr/bin/shasum -a 256 "$upstream_dir/go.sum" | /usr/bin/awk '{print $1}')" == "$go_sum_sha" ]] || fail "go.sum hash mismatch"
  /bin/cp -R "$upstream_dir" "$pristine_dir"
  /bin/cp -R "$upstream_dir" "$patched_dir"
  /usr/bin/git -C "$pristine_dir" apply --unidiff-zero \
    --exclude=client/atrust/node.go --include=client/atrust/node_test.go \
    "$project_root/patches/zju-connect-v1.2.2-node-selection.patch"
  set +e
  (cd "$pristine_dir" && GOTOOLCHAIN=local GOFLAGS=-mod=readonly go test ./client/atrust -run 'TestGetBestNodes(KeepsNodeAlignedWhenIPv6IsSkipped|FallbackUsesFirstProbeableNode)$' -count=1) >/dev/null 2>&1
  pristine_rc=$?
  set -e
  (( pristine_rc != 0 )) || fail "regression tests unexpectedly passed on pristine source"
  /usr/bin/git -C "$patched_dir" apply --unidiff-zero --check "$project_root/patches/zju-connect-v1.2.2-node-selection.patch"
  /usr/bin/git -C "$patched_dir" apply --unidiff-zero "$project_root/patches/zju-connect-v1.2.2-node-selection.patch"
  (cd "$patched_dir" && GOTOOLCHAIN=local GOFLAGS=-mod=readonly go test ./client/atrust -count=1)
  (cd "$patched_dir" && GOTOOLCHAIN=local GOFLAGS=-mod=readonly go test ./... -count=1)
  (cd "$patched_dir" && GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 GOFLAGS=-mod=readonly MACOSX_DEPLOYMENT_TARGET=12.0 \
    go build -trimpath -ldflags='-s -w -buildid= -X main.zjuConnectVersion=v1.2.2-shanghaitech-nodefix1' -o "$test_tmp/zju-connect" .)
  /usr/bin/codesign --verify --strict "$test_tmp/zju-connect"
  [[ "$("$test_tmp/zju-connect" -version)" == "ZJU Connect v1.2.2-shanghaitech-nodefix1" ]] || fail "built client failed its version smoke test"
fi

print -r -- "All shanghaitech-shvpn tests passed."
