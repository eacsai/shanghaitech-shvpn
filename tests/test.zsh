#!/bin/zsh

set -eu
setopt extendedglob
umask 077

typeset -gr project_root="${0:A:h:h}"
typeset -gr upstream_commit="a759261b76ed653900911559400005b40a31392a"
typeset -gr go_mod_sha="d06b5a0423a5ce23887222d1e3f2b06b0f1c63f16873d87887c0c1147a5f7204"
typeset -gr go_sum_sha="8af52b375ebe736a54883a39bdffff6cdfb8f55face981cbbd13e3362e2e0572"
typeset -gr begin_ssh="# >>> shanghaitech-shvpn managed SSH targets >>>"
typeset -gr end_ssh="# <<< shanghaitech-shvpn managed SSH targets <<<"
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

assert_manifest_hash() {
  local key="$1"
  local file="$2"
  local manifest="$3"
  local expected actual
  expected="$(/usr/bin/awk -F '\t' -v key="$key" '$1 == key {count++; value=$2} END {if (count != 1) exit 1; print value}' "$manifest")" || fail "manifest key is missing or duplicated: $key"
  actual="$(/usr/bin/shasum -a 256 "$file" | /usr/bin/awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || fail "manifest hash mismatch for $key"
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
  libexec/shvpn-config.zsh
  libexec/shvpn.zsh
  patches/zju-connect-v1.2.2-node-selection.patch
  tests/test.zsh
  uninstall.zsh
)
actual_paths=("${(@f)$({
  /usr/bin/git -C "$project_root" ls-files
  if [[ -f "$project_root/libexec/shvpn-config.zsh" ]] && ! /usr/bin/git -C "$project_root" ls-files --error-unmatch libexec/shvpn-config.zsh >/dev/null 2>&1; then
    print -r -- libexec/shvpn-config.zsh
  fi
} | LC_ALL=C /usr/bin/sort)}")
[[ "${(j:\n:)actual_paths}" == "${(j:\n:)expected_paths}" ]] || {
  print -u2 -r -- "Expected manifest:"
  print -u2 -l -- "${expected_paths[@]}"
  print -u2 -r -- "Actual manifest:"
  print -u2 -l -- "${actual_paths[@]}"
  fail "repository path manifest differs"
}
tracked_files=("${(@)^actual_paths/#/$project_root/}")

[[ "$(/usr/bin/grep -Fxc '|---|---|' "$project_root/README.md")" == 1 ]] || fail "README must contain exactly one command table"
[[ "$(/usr/bin/grep -Ec '^\| `shvpn([^`]*)?` \|' "$project_root/README.md")" == 10 ]] || fail "README command table must list exactly ten shvpn command forms"
for documented_command in \
  '`shvpn`' \
  '`shvpn start`' \
  '`shvpn login`' \
  '`shvpn status`' \
  '`shvpn stop`' \
  '`shvpn add HOST_OR_ALIAS`' \
  '`shvpn remove HOST_OR_ALIAS`' \
  '`shvpn doctor [ALIAS ...]`' \
  '`shvpn reconnect [ALIAS ...]`' \
  '`shvpn uninstall`'; do
  /usr/bin/grep -F "| $documented_command |" "$project_root/README.md" >/dev/null || fail "README command table is missing $documented_command"
done

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
lock_login_pid=""
lock_client_pid=""
config_lock_holder_pid=""
cleanup() {
  if [[ "${lock_client_pid:-}" == <-> ]] && /bin/kill -0 "$lock_client_pid" 2>/dev/null; then
    /bin/kill -INT "$lock_client_pid" 2>/dev/null || true
  fi
  if [[ "${lock_login_pid:-}" == <-> ]] && /bin/kill -0 "$lock_login_pid" 2>/dev/null; then
    /bin/kill -INT "$lock_login_pid" 2>/dev/null || true
    wait "$lock_login_pid" 2>/dev/null || true
  fi
  if [[ "${config_lock_holder_pid:-}" == <-> ]] && /bin/kill -0 "$config_lock_holder_pid" 2>/dev/null; then
    /bin/kill -TERM "$config_lock_holder_pid" 2>/dev/null || true
    wait "$config_lock_holder_pid" 2>/dev/null || true
  fi
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
/usr/bin/install -d -m 700 "$fixture_home/.ssh" "$fixture_home/.ssh/conf.d" "$fake_bin"

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

print -r -- 'Include ~/.ssh/conf.d/*' >"$fixture_home/.ssh/config"
print -r -- 'Host keep' >>"$fixture_home/.ssh/config"
print -r -- '    HostName 192.0.2.30' >>"$fixture_home/.ssh/config"
print -r -- 'Host gpu-main' >>"$fixture_home/.ssh/config"
print -r -- '    HostName 192.0.2.10' >>"$fixture_home/.ssh/config"
print -r -- '    User alias-user' >>"$fixture_home/.ssh/config"
print -r -- '    Port 2201' >>"$fixture_home/.ssh/config"
print -r -- '    ControlMaster auto' >>"$fixture_home/.ssh/config"
print -r -- '    ControlPath ~/.ssh/cm-%C' >>"$fixture_home/.ssh/config"
print -r -- 'Host gpu-add' >>"$fixture_home/.ssh/config"
print -r -- '    HostName 192.0.2.40' >>"$fixture_home/.ssh/config"
print -r -- 'Host gpu-include' >"$fixture_home/.ssh/conf.d/gpu.conf"
print -r -- '    HostName 192.0.2.20' >>"$fixture_home/.ssh/conf.d/gpu.conf"
print -r -- '    User include-user' >>"$fixture_home/.ssh/conf.d/gpu.conf"
print -r -- '    Port 2202' >>"$fixture_home/.ssh/conf.d/gpu.conf"
print -r -- '    ControlMaster auto' >>"$fixture_home/.ssh/conf.d/gpu.conf"
print -r -- '    ControlPath ~/.ssh/cm-%C' >>"$fixture_home/.ssh/conf.d/gpu.conf"
print -r -- 'Host gpu-include-add' >>"$fixture_home/.ssh/conf.d/gpu.conf"
print -r -- '    HostName 192.0.2.60' >>"$fixture_home/.ssh/conf.d/gpu.conf"
print -r -- '    User include-add-user' >>"$fixture_home/.ssh/conf.d/gpu.conf"
print -r -- '    Port 2260' >>"$fixture_home/.ssh/conf.d/gpu.conf"
print -r -- '# existing zsh content' >"$fixture_home/.zshrc"
/usr/bin/install -d -m 700 "$fixture_home/.local/bin"
print -r -- '#!/bin/zsh' >"$fixture_home/.local/bin/zju-connect"
print -r -- 'print preexisting-client' >>"$fixture_home/.local/bin/zju-connect"
/bin/chmod 755 "$fixture_home/.local/bin/zju-connect"
/bin/cp -p "$fixture_home/.ssh/config" "$test_tmp/original-ssh-config"
/bin/cp -p "$fixture_home/.zshrc" "$test_tmp/original-zshrc"
/bin/cp -p "$fixture_home/.local/bin/zju-connect" "$test_tmp/original-zju-connect"

fixture_path="$fake_bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

for invalid_install in \
  "--non-interactive --add-path" \
  "--non-interactive --target user@192.0.2.10 --add-path" \
  "--non-interactive --target 192.0.2.10 --target 192.0.2.10 --add-path" \
  "--non-interactive --target gpu 192.0.2.10 22 alice --add-path"; do
  set +e
  HOME="$fixture_home" PATH="$fixture_path" "$fixture_repo/install.zsh" ${(z)invalid_install} >/dev/null 2>&1
  invalid_install_rc=$?
  set -e
  [[ "$invalid_install_rc" == 64 ]] || fail "invalid installer input returned $invalid_install_rc: $invalid_install"
  [[ ! -e "$fixture_home/.local/lib/shanghaitech-shvpn" ]] || fail "invalid installer input created metadata"
  /usr/bin/cmp -s "$test_tmp/original-ssh-config" "$fixture_home/.ssh/config" || fail "invalid installer input changed SSH config"
  /usr/bin/cmp -s "$test_tmp/original-zshrc" "$fixture_home/.zshrc" || fail "invalid installer input changed .zshrc"
  /usr/bin/cmp -s "$test_tmp/original-zju-connect" "$fixture_home/.local/bin/zju-connect" || fail "invalid installer input changed zju-connect"
done

set +e
print -r -- '' | HOME="$fixture_home" PATH="$fixture_path" "$fixture_repo/install.zsh" --no-path >/dev/null 2>&1
empty_interactive_rc=$?
set -e
[[ "$empty_interactive_rc" == 64 ]] || fail "interactive empty target list did not fail with 64"
[[ ! -e "$fixture_home/.local/lib/shanghaitech-shvpn" ]] || fail "interactive empty target list created metadata"

conflict_home="$test_tmp/Conflict Home"
/usr/bin/install -d -m 700 "$conflict_home/.ssh/conf.d"
print -r -- 'Include ~/.ssh/conf.d/*' >"$conflict_home/.ssh/config"
print -r -- 'Host conflict-alias' >"$conflict_home/.ssh/conf.d/conflict.conf"
print -r -- '    HostName 192.0.2.10' >>"$conflict_home/.ssh/conf.d/conflict.conf"
print -r -- '    ProxyCommand /usr/bin/nc 192.0.2.99 22' >>"$conflict_home/.ssh/conf.d/conflict.conf"
/bin/cp -p "$conflict_home/.ssh/config" "$test_tmp/conflict-original-config"
set +e
HOME="$conflict_home" PATH="$fixture_path" "$fixture_repo/install.zsh" --non-interactive \
  --target 192.0.2.10 \
  --add-path >"$test_tmp/conflict-install.out" 2>"$test_tmp/conflict-install.err"
conflict_install_rc=$?
set -e
[[ "$conflict_install_rc" == 65 ]] || fail "included alias proxy conflict returned $conflict_install_rc instead of 65"
/usr/bin/grep -F 'earlier ProxyCommand or ProxyJump' "$test_tmp/conflict-install.err" >/dev/null || fail "included alias proxy conflict message missing"
[[ ! -e "$conflict_home/.local/lib/shanghaitech-shvpn" ]] || fail "conflicting alias install created metadata"
/usr/bin/cmp -s "$test_tmp/conflict-original-config" "$conflict_home/.ssh/config" || fail "conflicting alias install changed SSH config"

jump_home="$test_tmp/Jump Conflict Home"
/usr/bin/install -d -m 700 "$jump_home/.ssh/conf.d"
print -r -- 'Include ~/.ssh/conf.d/*' >"$jump_home/.ssh/config"
print -r -- 'Host jump-conflict-alias' >"$jump_home/.ssh/conf.d/conflict.conf"
print -r -- '    HostName 192.0.2.10' >>"$jump_home/.ssh/conf.d/conflict.conf"
print -r -- '    ProxyJump jump.example.test' >>"$jump_home/.ssh/conf.d/conflict.conf"
/bin/cp -p "$jump_home/.ssh/config" "$test_tmp/jump-original-config"
set +e
HOME="$jump_home" PATH="$fixture_path" "$fixture_repo/install.zsh" --non-interactive \
  --target 192.0.2.10 \
  --add-path >"$test_tmp/jump-install.out" 2>"$test_tmp/jump-install.err"
jump_install_rc=$?
set -e
[[ "$jump_install_rc" == 65 ]] || fail "included alias ProxyJump conflict returned $jump_install_rc instead of 65"
/usr/bin/grep -F 'earlier ProxyCommand or ProxyJump' "$test_tmp/jump-install.err" >/dev/null || fail "included alias ProxyJump conflict message missing"
[[ ! -e "$jump_home/.local/lib/shanghaitech-shvpn" ]] || fail "ProxyJump conflict install created metadata"
/usr/bin/cmp -s "$test_tmp/jump-original-config" "$jump_home/.ssh/config" || fail "ProxyJump conflict install changed SSH config"

warning_home="$test_tmp/Warning Home"
outside_ssh="$test_tmp/outside-ssh"
/usr/bin/install -d -m 700 "$warning_home/.ssh" "$outside_ssh"
print -r -- 'Host outside-only' >"$outside_ssh/hosts.conf"
print -r -- '    HostName 192.0.2.90' >>"$outside_ssh/hosts.conf"
print -r -- "Include $outside_ssh/*.conf" >"$warning_home/.ssh/config"
HOME="$warning_home" PATH="$fixture_path" "$fixture_repo/install.zsh" --non-interactive \
  --target 192.0.2.40 \
  --no-path >"$test_tmp/warning-install.out" 2>"$test_tmp/warning-install.err"
/usr/bin/grep -F 'SSH alias discovery was incomplete because of Include, safety, or scan limits' "$test_tmp/warning-install.err" >/dev/null || fail "incomplete alias discovery warning missing"
set +e
HOME="$warning_home" "$warning_home/.local/bin/shvpn" doctor >"$test_tmp/warning-doctor.out" 2>"$test_tmp/warning-doctor.err"
warning_doctor_rc=$?
set -e
if [[ "$warning_doctor_rc" != 1 ]]; then
  /bin/cat "$test_tmp/warning-doctor.out" "$test_tmp/warning-doctor.err" >&2
  fail "doctor incomplete include warning returned $warning_doctor_rc instead of 1"
fi
HOME="$warning_home" "$warning_home/.local/bin/shvpn" add outside-only >"$test_tmp/warning-add.out" 2>"$test_tmp/warning-add.err" || fail "add did not continue after incomplete Include discovery"
/usr/bin/grep -F 'SSH alias discovery was incomplete because of Include, safety, or scan limits' "$test_tmp/warning-add.err" >/dev/null || fail "add incomplete Include warning missing"
/usr/bin/grep -Fx '192.0.2.90' "$warning_home/.config/shanghaitech-shvpn/targets.tsv" >/dev/null || fail "add did not resolve the explicit outside Include alias"
HOME="$warning_home" PATH="$fixture_path" "$fixture_repo/uninstall.zsh" >/dev/null

HOME="$fixture_home" PATH="$fixture_path" "$fixture_repo/install.zsh" --non-interactive \
  --target 192.0.2.10 \
  --target 192.0.2.20 \
  --add-path

for executable in zju-connect shanghaitech-vpn shvpn shanghaitech-ssh-route; do
  [[ -x "$fixture_home/.local/bin/$executable" && ! -L "$fixture_home/.local/bin/$executable" ]] || fail "missing installed executable: $executable"
  assert_file_mode 755 "$fixture_home/.local/bin/$executable"
done
assert_file_mode 600 "$fixture_home/.config/shanghaitech-shvpn/targets.tsv"
assert_file_mode 600 "$fixture_home/.local/lib/shanghaitech-shvpn/install.manifest.tsv"
assert_file_mode 700 "$fixture_home/.local/lib/shanghaitech-shvpn/configure-targets.zsh"
assert_file_mode 700 "$fixture_home/.local/lib/shanghaitech-shvpn/uninstall.zsh"
/usr/bin/grep -Fx $'format\t2' "$fixture_home/.local/lib/shanghaitech-shvpn/install.manifest.tsv" >/dev/null || fail "fresh install did not write manifest format 2"
assert_count 1 "$begin_ssh" "$fixture_home/.ssh/config"
assert_count 1 "$begin_path" "$fixture_home/.zshrc"

{
  print -r -- '192.0.2.10'
  print -r -- '192.0.2.20'
} >"$test_tmp/expected-targets.tsv"
/usr/bin/cmp -s "$test_tmp/expected-targets.tsv" "$fixture_home/.config/shanghaitech-shvpn/targets.tsv" || fail "target TSV differs"
assert_count 1 'Match final host 192.0.2.10,192.0.2.20' "$fixture_home/.ssh/config"
assert_count 0 'Host 192.0.2.10' "$fixture_home/.ssh/config"
assert_count 0 'Host 192.0.2.20' "$fixture_home/.ssh/config"

for rendered in \
  "$fixture_home/.local/bin/shanghaitech-vpn" \
  "$fixture_home/.local/bin/shvpn" \
  "$fixture_home/.local/bin/shanghaitech-ssh-route" \
  "$fixture_home/.local/lib/shanghaitech-shvpn/configure-targets.zsh"; do
  if /usr/bin/grep -F '@@' "$rendered" >/dev/null 2>&1; then
    fail "unresolved template token in $rendered"
  fi
done
/usr/bin/grep -F -- "$fixture_home/.local/bin/zju-connect" "$fixture_home/.local/bin/shvpn" >/dev/null || fail "shvpn does not bind the physical client path"
/usr/bin/grep -F -- "$fixture_home/.config/shanghaitech-shvpn/targets.tsv" "$fixture_home/.local/bin/shanghaitech-ssh-route" >/dev/null || fail "route helper does not bind the physical targets path"
/usr/bin/grep -F -- '-http-bind  -auto-detect-interface' "$fixture_home/.local/bin/shvpn" >/dev/null || fail "trusted argv lost the empty http-bind field"

route_path="$fixture_home/.local/bin/shanghaitech-ssh-route"
route_q="${(qqq)route_path}"
fixture_manifest="$fixture_home/.local/lib/shanghaitech-shvpn/install.manifest.tsv"
fixture_config_helper="$fixture_home/.local/lib/shanghaitech-shvpn/configure-targets.zsh"
fixture_uninstall_helper="$fixture_home/.local/lib/shanghaitech-shvpn/uninstall.zsh"
for helper_spec in "config-helper:$fixture_config_helper" "uninstall-helper:$fixture_uninstall_helper"; do
  assert_manifest_hash "${helper_spec%%:*}" "${helper_spec#*:}" "$fixture_manifest"
done

# Duplicate add is a byte-for-byte no-op, including when an alias resolves to
# an already-managed final HostName.
for state_file in targets ssh manifest; do
  case "$state_file" in
    targets) source_file="$fixture_home/.config/shanghaitech-shvpn/targets.tsv" ;;
    ssh) source_file="$fixture_home/.ssh/config" ;;
    manifest) source_file="$fixture_manifest" ;;
  esac
  /bin/cp -p "$source_file" "$test_tmp/noop-$state_file"
done
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" add gpu-main >/dev/null || fail "alias-to-existing add no-op failed"
/usr/bin/cmp -s "$test_tmp/noop-targets" "$fixture_home/.config/shanghaitech-shvpn/targets.tsv" || fail "duplicate add changed targets"
/usr/bin/cmp -s "$test_tmp/noop-ssh" "$fixture_home/.ssh/config" || fail "duplicate add changed SSH config"
/usr/bin/cmp -s "$test_tmp/noop-manifest" "$fixture_manifest" || fail "duplicate add changed manifest"
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" add 192.0.2.10 >/dev/null || fail "direct repeated add no-op failed"
/usr/bin/cmp -s "$test_tmp/noop-targets" "$fixture_home/.config/shanghaitech-shvpn/targets.tsv" || fail "direct repeated add changed targets"
/usr/bin/cmp -s "$test_tmp/noop-ssh" "$fixture_home/.ssh/config" || fail "direct repeated add changed SSH config"
/usr/bin/cmp -s "$test_tmp/noop-manifest" "$fixture_manifest" || fail "direct repeated add changed manifest"

HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" add gpu-add >"$test_tmp/alias-add.out" || fail "alias add failed"
/usr/bin/grep -F 'gpu-add -> 192.0.2.40' "$test_tmp/alias-add.out" >/dev/null || fail "alias add output omitted the resolved target mapping"
{
  print -r -- '192.0.2.10'
  print -r -- '192.0.2.20'
  print -r -- '192.0.2.40'
} >"$test_tmp/expected-targets-added.tsv"
/usr/bin/cmp -s "$test_tmp/expected-targets-added.tsv" "$fixture_home/.config/shanghaitech-shvpn/targets.tsv" || fail "alias add did not append the resolved HostName"
assert_count 1 'Match final host 192.0.2.10,192.0.2.20,192.0.2.40' "$fixture_home/.ssh/config"
assert_manifest_hash targets "$fixture_home/.config/shanghaitech-shvpn/targets.tsv" "$fixture_manifest"
assert_manifest_hash ssh-full "$fixture_home/.ssh/config" "$fixture_manifest"
/usr/bin/awk -v begin="$begin_ssh" -v end="$end_ssh" '
  $0 == begin { inside=1 }
  inside { print }
  $0 == end { inside=0 }
' "$fixture_home/.ssh/config" >"$test_tmp/add-managed-ssh.block"
assert_manifest_hash ssh-block "$test_tmp/add-managed-ssh.block" "$fixture_manifest"

print -r -- '# user edit preserved across shvpn target updates' >>"$fixture_home/.ssh/config"
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" remove gpu-add >"$test_tmp/alias-remove.out" || fail "alias remove failed"
/usr/bin/grep -F 'gpu-add -> 192.0.2.40' "$test_tmp/alias-remove.out" >/dev/null || fail "alias remove output omitted the resolved target mapping"
/usr/bin/grep -F 'aliases sharing this HostName no longer receive the managed route' "$test_tmp/alias-remove.out" >/dev/null || fail "alias remove output omitted shared-target semantics"
/usr/bin/grep -Fx '# user edit preserved across shvpn target updates' "$fixture_home/.ssh/config" >/dev/null || fail "target update discarded SSH config outside the managed block"
/usr/bin/cmp -s "$test_tmp/expected-targets.tsv" "$fixture_home/.config/shanghaitech-shvpn/targets.tsv" || fail "alias remove did not remove its resolved target"

HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" add gpu-include-add >/dev/null || fail "safe-Include alias add failed"
include_add_output="$(HOME="$fixture_home" /usr/bin/ssh -F "$fixture_home/.ssh/config" -G gpu-include-add 2>/dev/null)"
[[ "$(print -r -- "$include_add_output" | /usr/bin/awk '$1 == "hostname" {print $2; exit}')" == "192.0.2.60" ]] || fail "safe-Include add hostname mismatch"
[[ "$(print -r -- "$include_add_output" | /usr/bin/awk '$1 == "user" {print $2; exit}')" == "include-add-user" ]] || fail "safe-Include add did not preserve User"
[[ "$(print -r -- "$include_add_output" | /usr/bin/awk '$1 == "port" {print $2; exit}')" == "2260" ]] || fail "safe-Include add did not preserve Port"
[[ "$(print -r -- "$include_add_output" | /usr/bin/awk '$1 == "proxycommand" {$1=""; sub(/^ /, ""); print; exit}')" == "$route_q %h %p" ]] || fail "safe-Include add did not install the managed route"
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" remove gpu-include-add >/dev/null || fail "safe-Include alias remove failed"

HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" add 192.0.2.40 >/dev/null || fail "direct target add failed"
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" remove 192.0.2.40 >/dev/null || fail "direct target remove failed"
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" remove gpu-include >/dev/null || fail "included alias remove failed"
print -r -- '192.0.2.10' >"$test_tmp/expected-one-target.tsv"
/usr/bin/cmp -s "$test_tmp/expected-one-target.tsv" "$fixture_home/.config/shanghaitech-shvpn/targets.tsv" || fail "alias remove did not remove the shared underlying target"
/bin/cp -p "$fixture_home/.config/shanghaitech-shvpn/targets.tsv" "$test_tmp/last-remove-targets"
/bin/cp -p "$fixture_home/.ssh/config" "$test_tmp/last-remove-ssh"
/bin/cp -p "$fixture_manifest" "$test_tmp/last-remove-manifest"
set +e
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" remove 192.0.2.10 >"$test_tmp/last-remove.out" 2>"$test_tmp/last-remove.err"
last_remove_rc=$?
set -e
[[ "$last_remove_rc" == 64 ]] || fail "last-target removal returned $last_remove_rc instead of 64"
/usr/bin/grep -F "use 'shvpn uninstall'" "$test_tmp/last-remove.err" >/dev/null || fail "last-target removal did not recommend uninstall"
/usr/bin/cmp -s "$test_tmp/last-remove-targets" "$fixture_home/.config/shanghaitech-shvpn/targets.tsv" || fail "failed last-target removal changed targets"
/usr/bin/cmp -s "$test_tmp/last-remove-ssh" "$fixture_home/.ssh/config" || fail "failed last-target removal changed SSH config"
/usr/bin/cmp -s "$test_tmp/last-remove-manifest" "$fixture_manifest" || fail "failed last-target removal changed manifest"
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" add 192.0.2.20 >/dev/null || fail "direct add did not restore the removed target"

# A discovered alias with an earlier ProxyJump must fail before writes.
/bin/cp -p "$fixture_home/.ssh/config" "$test_tmp/pre-conflict-ssh"
/bin/cp -p "$fixture_home/.config/shanghaitech-shvpn/targets.tsv" "$test_tmp/pre-conflict-targets"
/bin/cp -p "$fixture_manifest" "$test_tmp/pre-conflict-manifest"
print -r -- 'Host add-conflict' >>"$fixture_home/.ssh/config"
print -r -- '    HostName 192.0.2.50' >>"$fixture_home/.ssh/config"
print -r -- '    ProxyJump jump.example.test' >>"$fixture_home/.ssh/config"
set +e
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" add add-conflict >"$test_tmp/add-conflict.out" 2>"$test_tmp/add-conflict.err"
add_conflict_rc=$?
set -e
[[ "$add_conflict_rc" == 2 ]] || fail "dynamic ProxyJump conflict returned $add_conflict_rc instead of 2"
/usr/bin/grep -F 'earlier ProxyCommand or ProxyJump' "$test_tmp/add-conflict.err" >/dev/null || fail "dynamic ProxyJump conflict message missing"
/usr/bin/cmp -s "$test_tmp/pre-conflict-targets" "$fixture_home/.config/shanghaitech-shvpn/targets.tsv" || fail "failed conflict add changed targets"
/usr/bin/cmp -s "$test_tmp/pre-conflict-manifest" "$fixture_manifest" || fail "failed conflict add changed manifest"
/usr/bin/install -m 600 "$test_tmp/pre-conflict-ssh" "$fixture_home/.ssh/config"

# The lock is owned by the mutator itself; both helper writes and lifecycle
# operations fail immediately with 75 while another mutator holds it.
config_lock_path="$fixture_home/Library/Application Support/ShanghaitechVPN/shvpn.config.lock"
config_lock_ready="$test_tmp/config-lock.ready"
{
  print -r -- '#!/bin/zsh'
  print -r -- 'set -eu'
  print -r -- 'zmodload zsh/system'
  print -r -- 'typeset -g held_fd'
  print -r -- 'zsystem flock -f held_fd -e "$1"'
  print -r -- 'print -r -- ready >"$2"'
  print -r -- '/bin/sleep 30'
} >"$test_tmp/hold-config-lock.zsh"
/bin/chmod 700 "$test_tmp/hold-config-lock.zsh"
"$test_tmp/hold-config-lock.zsh" "$config_lock_path" "$config_lock_ready" &
config_lock_holder_pid=$!
for (( i = 0; i < 100; i++ )); do
  [[ -f "$config_lock_ready" ]] && break
  /bin/sleep 0.02
done
[[ -f "$config_lock_ready" ]] || fail "configuration lock holder did not become ready"
for contended_command in "add gpu-add" "start"; do
  set +e
  HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" ${(z)contended_command} >/dev/null 2>"$test_tmp/config-contended.err"
  contended_config_rc=$?
  set -e
  [[ "$contended_config_rc" == 75 ]] || fail "configuration lock contention returned $contended_config_rc for $contended_command"
  /usr/bin/grep -F 'another shvpn configuration or lifecycle operation is in progress' "$test_tmp/config-contended.err" >/dev/null || fail "configuration lock contention message missing"
done
set +e
HOME="$fixture_home" PATH="$fixture_path" "$fixture_repo/install.zsh" --non-interactive --target 192.0.2.10 --target 192.0.2.20 --add-path >/dev/null 2>"$test_tmp/install-contended.err"
contended_install_rc=$?
set -e
[[ "$contended_install_rc" == 75 ]] || fail "installer configuration lock contention returned $contended_install_rc instead of 75"
/usr/bin/grep -F 'another shvpn configuration or lifecycle operation is in progress' "$test_tmp/install-contended.err" >/dev/null || fail "installer configuration lock contention message missing"
set +e
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" uninstall >/dev/null 2>"$test_tmp/uninstall-contended.err"
contended_uninstall_rc=$?
set -e
[[ "$contended_uninstall_rc" == 75 ]] || fail "uninstaller configuration lock contention returned $contended_uninstall_rc instead of 75"
[[ -x "$fixture_home/.local/bin/shvpn" && -f "$fixture_manifest" ]] || fail "contended uninstall changed the installation"
/bin/kill -TERM "$config_lock_holder_pid"
wait "$config_lock_holder_pid" 2>/dev/null || true
config_lock_holder_pid=""

# Make the allowlist directory read-only after preflight. The SSH file write
# succeeds first, the allowlist write fails, and the caught error must restore
# the SSH file from the persistent pre-change backup.
/bin/cp -p "$fixture_home/.ssh/config" "$test_tmp/rollback-ssh"
/bin/cp -p "$fixture_home/.config/shanghaitech-shvpn/targets.tsv" "$test_tmp/rollback-targets"
/bin/cp -p "$fixture_manifest" "$test_tmp/rollback-manifest"
/bin/chmod 500 "$fixture_home/.config/shanghaitech-shvpn"
set +e
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" add gpu-add >"$test_tmp/rollback-add.out" 2>"$test_tmp/rollback-add.err"
rollback_add_rc=$?
set -e
/bin/chmod 700 "$fixture_home/.config/shanghaitech-shvpn"
[[ "$rollback_add_rc" == 74 ]] || fail "forced target write failure returned $rollback_add_rc instead of 74"
/usr/bin/cmp -s "$test_tmp/rollback-ssh" "$fixture_home/.ssh/config" || fail "caught target write failure did not roll back SSH config"
/usr/bin/cmp -s "$test_tmp/rollback-targets" "$fixture_home/.config/shanghaitech-shvpn/targets.tsv" || fail "caught target write failure changed targets"
/usr/bin/cmp -s "$test_tmp/rollback-manifest" "$fixture_manifest" || fail "caught target write failure changed manifest"

set +e
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" add 'bad*' >/dev/null 2>&1
invalid_add_rc=$?
set -e
[[ "$invalid_add_rc" == 64 ]] || fail "invalid dynamic target returned $invalid_add_rc instead of 64"
set +e
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" remove keep >/dev/null 2>&1
unmanaged_remove_rc=$?
set -e
[[ "$unmanaged_remove_rc" == 64 ]] || fail "unmanaged removal returned $unmanaged_remove_rc instead of 64"

/bin/cp -p "$fixture_home/.config/shanghaitech-shvpn/targets.tsv" "$test_tmp/tampered-targets"
print -r -- '192.0.2.30' >>"$fixture_home/.config/shanghaitech-shvpn/targets.tsv"
/bin/cp -p "$fixture_home/.ssh/config" "$test_tmp/pre-tamper-add-ssh"
/bin/cp -p "$fixture_manifest" "$test_tmp/pre-tamper-add-manifest"
set +e
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" add gpu-add >/dev/null 2>&1
tampered_add_rc=$?
set -e
[[ "$tampered_add_rc" == 2 ]] || fail "modified targets add returned $tampered_add_rc instead of 2"
/usr/bin/cmp -s "$test_tmp/pre-tamper-add-ssh" "$fixture_home/.ssh/config" || fail "modified targets rejection changed SSH config"
/usr/bin/cmp -s "$test_tmp/pre-tamper-add-manifest" "$fixture_manifest" || fail "modified targets rejection changed manifest"
/usr/bin/install -m 600 "$test_tmp/tampered-targets" "$fixture_home/.config/shanghaitech-shvpn/targets.tsv"

/bin/cp -p "$fixture_manifest" "$test_tmp/valid-dynamic-manifest"
/usr/bin/awk -F '\t' '$1 != "config-helper" {print}' "$fixture_manifest" >"$test_tmp/missing-helper-manifest"
/usr/bin/install -m 600 "$test_tmp/missing-helper-manifest" "$fixture_manifest"
set +e
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" add gpu-add >/dev/null 2>&1
missing_manifest_rc=$?
set -e
[[ "$missing_manifest_rc" == 65 ]] || fail "missing helper manifest key returned $missing_manifest_rc instead of 65"
/usr/bin/install -m 600 "$test_tmp/valid-dynamic-manifest" "$fixture_manifest"
assert_manifest_hash config-helper "$fixture_config_helper" "$fixture_manifest"
assert_manifest_hash uninstall-helper "$fixture_uninstall_helper" "$fixture_manifest"
assert_manifest_hash targets "$fixture_home/.config/shanghaitech-shvpn/targets.tsv" "$fixture_manifest"

# Remove the fixture-only outside-block edit so later uninstall can compare the
# restored baseline exactly. The managed block remains untouched.
/usr/bin/grep -Fvx '# user edit preserved across shvpn target updates' "$fixture_home/.ssh/config" >"$test_tmp/ssh-without-user-comment"
/usr/bin/install -m 600 "$test_tmp/ssh-without-user-comment" "$fixture_home/.ssh/config"

ssh_output="$(/usr/bin/ssh -F "$fixture_home/.ssh/config" -G 192.0.2.10 2>/dev/null)"
[[ "$(print -r -- "$ssh_output" | /usr/bin/awk '$1 == "hostname" {print $2; exit}')" == "192.0.2.10" ]] || fail "ssh hostname mismatch"
[[ "$(print -r -- "$ssh_output" | /usr/bin/awk '$1 == "port" {print $2; exit}')" == "22" ]] || fail "ssh port mismatch"
actual_proxy="$(print -r -- "$ssh_output" | /usr/bin/awk '$1 == "proxycommand" {$1=""; sub(/^ /, ""); print; exit}')"
[[ "$actual_proxy" == "$route_q %h %p" ]] || fail "ssh ProxyCommand mismatch: got [$actual_proxy], expected [$route_q %h %p]"
ssh_override_output="$(/usr/bin/ssh -F "$fixture_home/.ssh/config" -G -p 2222 -l alice 192.0.2.10 2>/dev/null)"
[[ "$(print -r -- "$ssh_override_output" | /usr/bin/awk '$1 == "hostname" {print $2; exit}')" == "192.0.2.10" ]] || fail "ssh override hostname mismatch"
[[ "$(print -r -- "$ssh_override_output" | /usr/bin/awk '$1 == "port" {print $2; exit}')" == "2222" ]] || fail "ssh runtime port override mismatch"
[[ "$(print -r -- "$ssh_override_output" | /usr/bin/awk '$1 == "user" {print $2; exit}')" == "alice" ]] || fail "ssh runtime user override mismatch"
[[ "$(print -r -- "$ssh_override_output" | /usr/bin/awk '$1 == "proxycommand" {$1=""; sub(/^ /, ""); print; exit}')" == "$route_q %h %p" ]] || fail "ssh runtime override lost ProxyCommand"
/usr/bin/awk -v begin="$begin_ssh" -v end="$end_ssh" '
  $0 == begin { inside=1 }
  inside { print }
  $0 == end { inside=0 }
' "$fixture_home/.ssh/config" >"$test_tmp/current-managed-ssh.block"
if /usr/bin/grep -E '^[[:space:]]+(Port|User)[[:space:]]' "$test_tmp/current-managed-ssh.block" >/dev/null 2>&1; then
  fail "managed SSH config unexpectedly pins Port or User"
fi
keep_output="$(/usr/bin/ssh -F "$fixture_home/.ssh/config" -G keep 2>/dev/null)"
if print -r -- "$keep_output" | /usr/bin/grep -q '^proxycommand '; then
  fail "unmanaged SSH alias received a ProxyCommand"
fi
main_alias_output="$(/usr/bin/ssh -F "$fixture_home/.ssh/config" -G gpu-main 2>/dev/null)"
[[ "$(print -r -- "$main_alias_output" | /usr/bin/awk '$1 == "hostname" {print $2; exit}')" == "192.0.2.10" ]] || fail "main alias hostname mismatch"
[[ "$(print -r -- "$main_alias_output" | /usr/bin/awk '$1 == "user" {print $2; exit}')" == "alias-user" ]] || fail "main alias user was not preserved"
[[ "$(print -r -- "$main_alias_output" | /usr/bin/awk '$1 == "port" {print $2; exit}')" == "2201" ]] || fail "main alias port was not preserved"
[[ "$(print -r -- "$main_alias_output" | /usr/bin/awk '$1 == "proxycommand" {$1=""; sub(/^ /, ""); print; exit}')" == "$route_q %h %p" ]] || fail "main alias did not inherit managed ProxyCommand"
include_alias_output="$(HOME="$fixture_home" /usr/bin/ssh -F "$fixture_home/.ssh/config" -G gpu-include 2>/dev/null)"
[[ "$(print -r -- "$include_alias_output" | /usr/bin/awk '$1 == "hostname" {print $2; exit}')" == "192.0.2.20" ]] || fail "included alias hostname mismatch"
[[ "$(print -r -- "$include_alias_output" | /usr/bin/awk '$1 == "user" {print $2; exit}')" == "include-user" ]] || fail "included alias user was not preserved"
[[ "$(print -r -- "$include_alias_output" | /usr/bin/awk '$1 == "port" {print $2; exit}')" == "2202" ]] || fail "included alias port was not preserved"
[[ "$(print -r -- "$include_alias_output" | /usr/bin/awk '$1 == "proxycommand" {$1=""; sub(/^ /, ""); print; exit}')" == "$route_q %h %p" ]] || fail "included alias did not inherit managed ProxyCommand"

set +e
HOME="$fixture_home" "$fixture_home/.local/bin/shanghaitech-ssh-route" 192.0.2.99 22 >/dev/null 2>&1
route_rc=$?
set -e
[[ "$route_rc" == 64 ]] || fail "route helper did not reject an unlisted target"

HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" doctor >"$test_tmp/doctor.out" 2>"$test_tmp/doctor.err" || fail "doctor did not pass on a healthy stopped fixture"
/usr/bin/grep -F 'alias gpu-main -> 192.0.2.10: managed route OK' "$test_tmp/doctor.out" >/dev/null || fail "doctor did not validate the main alias"
/usr/bin/grep -F 'alias gpu-include -> 192.0.2.20: managed route OK' "$test_tmp/doctor.out" >/dev/null || fail "doctor did not validate the included alias"
/usr/bin/grep -F 'all checks passed' "$test_tmp/doctor.out" >/dev/null || fail "doctor success summary missing"
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" doctor gpu-main gpu-include >/dev/null || fail "doctor rejected multiple valid explicit aliases"
set +e
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" doctor keep >"$test_tmp/doctor-unmanaged.out" 2>"$test_tmp/doctor-unmanaged.err"
doctor_unmanaged_rc=$?
set -e
[[ "$doctor_unmanaged_rc" == 1 ]] || fail "doctor unmanaged explicit alias returned $doctor_unmanaged_rc instead of 1"
/usr/bin/grep -F 'HostName must exactly equal an installed target' "$test_tmp/doctor-unmanaged.err" >/dev/null || fail "doctor unmanaged alias message missing"

/bin/chmod 644 "$fixture_home/.config/shanghaitech-shvpn/targets.tsv"
set +e
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" doctor >/dev/null 2>"$test_tmp/doctor-unsafe-targets.err"
doctor_unsafe_rc=$?
set -e
[[ "$doctor_unsafe_rc" == 2 ]] || fail "doctor unsafe target mode returned $doctor_unsafe_rc instead of 2"
/bin/chmod 600 "$fixture_home/.config/shanghaitech-shvpn/targets.tsv"

for old_arity in "start extra" "stop extra" "status extra" "login extra" "add" "add one two" "remove" "remove one two" "uninstall extra"; do
  set +e
  HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" ${(z)old_arity} >/dev/null 2>&1
  old_arity_rc=$?
  set -e
  [[ "$old_arity_rc" == 64 ]] || fail "old command arity returned $old_arity_rc: $old_arity"
done
for invalid_name_command in "doctor bad*" "reconnect bad*"; do
  set +e
  HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" ${(z)invalid_name_command} >/dev/null 2>&1
  invalid_name_rc=$?
  set -e
  [[ "$invalid_name_rc" == 64 ]] || fail "invalid SSH name returned $invalid_name_rc: $invalid_name_command"
done

HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" reconnect >"$test_tmp/reconnect-none.out" 2>"$test_tmp/reconnect-none.err" || fail "reconnect no-master no-op failed"
/usr/bin/grep -F 'no active configured master was found' "$test_tmp/reconnect-none.out" >/dev/null || fail "reconnect no-master summary missing"
set +e
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" reconnect keep >/dev/null 2>"$test_tmp/reconnect-unmanaged.err"
reconnect_unmanaged_rc=$?
set -e
[[ "$reconnect_unmanaged_rc" == 64 ]] || fail "reconnect unmanaged alias returned $reconnect_unmanaged_rc instead of 64"

/bin/cp -p "$fixture_home/.local/bin/shvpn" "$test_tmp/doctor-real-shvpn"
fake_ssh="$test_tmp/fake-ssh"
fake_ssh_log="$test_tmp/fake-ssh.log"
fake_ssh_log_q="${(qqq)fake_ssh_log}"
{
  print -r -- '#!/bin/zsh'
  print -r -- 'set -u'
  print -r -- 'if [[ "$*" == *"-G"* ]]; then'
  print -r -- '  exec /usr/bin/ssh "$@"'
  print -r -- 'fi'
  print -r -- 'name="${@[-1]}"'
  print -r -- 'if [[ "$*" == *"-O check"* ]]; then'
  print -r -- "  print -r -- \"check \$name \$*\" >>$fake_ssh_log_q"
  print -r -- '  [[ "$name" == "gpu-main" ]] && exit 0'
  print -r -- '  exit 1'
  print -r -- 'fi'
  print -r -- 'if [[ "$*" == *"-O exit"* ]]; then'
  print -r -- "  print -r -- \"exit \$name \$*\" >>$fake_ssh_log_q"
  print -r -- '  [[ "$name" == "gpu-main" ]] && exit 0'
  print -r -- '  exit 1'
  print -r -- 'fi'
  print -r -- 'exit 64'
} >"$fake_ssh"
/bin/chmod 755 "$fake_ssh"
fake_ssh_q="${(qqq)fake_ssh}"
/usr/bin/sed "s#typeset -gr ssh_client=\"/usr/bin/ssh\"#typeset -gr ssh_client=$fake_ssh_q#" \
  "$test_tmp/doctor-real-shvpn" >"$test_tmp/shvpn-with-fake-ssh"
/usr/bin/install -m 755 "$test_tmp/shvpn-with-fake-ssh" "$fixture_home/.local/bin/shvpn"
HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" reconnect >"$test_tmp/reconnect-success.out" 2>"$test_tmp/reconnect-success.err" || fail "reconnect fixture success path failed"
/usr/bin/grep -F 'closed configured master for gpu-main' "$test_tmp/reconnect-success.out" >/dev/null || fail "reconnect did not report the closed alias master"
/usr/bin/awk '
  $1 == "check" && $2 == "gpu-main" { checked=NR }
  $1 == "exit" && $2 == "gpu-main" { exited=NR; exits++ }
  END { exit !(checked && exited == checked + 1 && exits == 1) }
' "$fake_ssh_log" || fail "reconnect did not issue one check immediately before exit for the managed alias"
/usr/bin/grep -F "check gpu-main -F $fixture_home/.ssh/config -O check -- gpu-main" "$fake_ssh_log" >/dev/null || fail "reconnect check was not bound to the installed SSH config"
/usr/bin/grep -F "exit gpu-main -F $fixture_home/.ssh/config -O exit -- gpu-main" "$fake_ssh_log" >/dev/null || fail "reconnect exit was not bound to the installed SSH config"
/usr/bin/install -m 755 "$test_tmp/doctor-real-shvpn" "$fixture_home/.local/bin/shvpn"

/bin/cp -p "$fixture_home/.local/bin/shvpn" "$test_tmp/real-shvpn"
route_status_marker="$test_tmp/route-status.marker"
route_status_marker_q="${(qqq)route_status_marker}"
{
  print -r -- '#!/bin/zsh'
  print -r -- "print -r -- \"\$*\" >$route_status_marker_q"
  print -r -- 'exit 2'
} >"$fixture_home/.local/bin/shvpn"
/bin/chmod 755 "$fixture_home/.local/bin/shvpn"
set +e
HOME="$fixture_home" "$fixture_home/.local/bin/shanghaitech-ssh-route" 192.0.2.10 2222 >/dev/null 2>&1
route_rc=$?
set -e
[[ "$route_rc" == 255 ]] || fail "listed host on a runtime-selected port did not reach shvpn status"
[[ "$(<"$route_status_marker")" == "status" ]] || fail "route helper did not query shvpn status for listed host"
for invalid_port in 0 65536 invalid; do
  /bin/rm -f -- "$route_status_marker"
  set +e
  HOME="$fixture_home" "$fixture_home/.local/bin/shanghaitech-ssh-route" 192.0.2.10 "$invalid_port" >/dev/null 2>&1
  route_rc=$?
  set -e
  [[ "$route_rc" == 64 ]] || fail "route helper did not reject invalid port $invalid_port"
  [[ ! -e "$route_status_marker" ]] || fail "invalid port $invalid_port reached shvpn status"
done
/bin/cp -p "$test_tmp/real-shvpn" "$fixture_home/.local/bin/shvpn"

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

  HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" login >"$test_tmp/lock-login.out" 2>"$test_tmp/lock-login.err" &
  lock_login_pid=$!
  lock_ready=0
  for (( i = 0; i < 80; i++ )); do
    lock_client_pid="$(/usr/sbin/lsof -t -nP -a -iTCP@127.0.0.1:19180 -sTCP:LISTEN 2>/dev/null || true)"
    if [[ "$lock_client_pid" == <-> ]]; then
      lock_ready=1
      break
    fi
    /bin/sleep 0.05
  done
  (( lock_ready )) || fail "foreground login did not start the fixture listener"
  set +e
  HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" stop >"$test_tmp/contended-stop.out" 2>"$test_tmp/contended-stop.err"
  contended_rc=$?
  set -e
  [[ "$contended_rc" == 75 ]] || fail "operation lock contention returned $contended_rc instead of 75"
  /usr/bin/grep -F 'another shvpn configuration or lifecycle operation is in progress' "$test_tmp/contended-stop.err" >/dev/null || fail "lifecycle configuration lock contention message missing"
  /bin/kill -INT "$lock_client_pid"
  wait "$lock_login_pid" || fail "foreground login did not exit cleanly after fixture SIGINT"
  lock_client_pid=""
  lock_login_pid=""

  HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" start >/dev/null
  lifecycle_started=1
  HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" status >/dev/null || fail "trusted lifecycle status did not report running"
  HOME="$fixture_home" "$fixture_home/.local/bin/shvpn" doctor >/dev/null || fail "doctor did not accept a trusted running VPN"
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

# Synthesize a hash-consistent legacy installation without relying on Git history.
{
  print -r -- $'gpu\t192.0.2.10\t22\talice'
  print -r -- $'gpu2\t192.0.2.20\t2222\t-'
} >"$test_tmp/legacy-targets.tsv"
{
  print -r -- "$begin_ssh"
  print -r -- 'Host gpu'
  print -r -- '    HostName 192.0.2.10'
  print -r -- '    Port 22'
  print -r -- '    User alice'
  print -r -- "    ProxyCommand $route_q %h %p"
  print -r -- 'Host gpu2'
  print -r -- '    HostName 192.0.2.20'
  print -r -- '    Port 2222'
  print -r -- "    ProxyCommand $route_q %h %p"
  print -r -- "$end_ssh"
} >"$test_tmp/legacy-ssh.block"
/bin/cp "$test_tmp/original-ssh-config" "$test_tmp/legacy-ssh.config"
print >>"$test_tmp/legacy-ssh.config"
/bin/cat "$test_tmp/legacy-ssh.block" >>"$test_tmp/legacy-ssh.config"
/usr/bin/install -m 600 "$test_tmp/legacy-targets.tsv" "$fixture_home/.config/shanghaitech-shvpn/targets.tsv"
/usr/bin/install -m 600 "$test_tmp/legacy-ssh.config" "$fixture_home/.ssh/config"
legacy_targets_sha="$(/usr/bin/shasum -a 256 "$test_tmp/legacy-targets.tsv" | /usr/bin/awk '{print $1}')"
legacy_ssh_block_sha="$(/usr/bin/shasum -a 256 "$test_tmp/legacy-ssh.block" | /usr/bin/awk '{print $1}')"
legacy_ssh_full_sha="$(/usr/bin/shasum -a 256 "$test_tmp/legacy-ssh.config" | /usr/bin/awk '{print $1}')"
manifest_path="$fixture_home/.local/lib/shanghaitech-shvpn/install.manifest.tsv"
/usr/bin/awk -F '\t' -v OFS='\t' \
  -v targets="$legacy_targets_sha" -v block="$legacy_ssh_block_sha" -v full="$legacy_ssh_full_sha" '
    $1 == "format" { $2="1" }
    $1 == "config-helper" || $1 == "uninstall-helper" { next }
    $1 == "targets" { $2=targets }
    $1 == "ssh-block" { $2=block }
    $1 == "ssh-full" { $2=full }
    { print }
  ' "$manifest_path" >"$test_tmp/legacy-manifest.tsv"
/usr/bin/install -m 600 "$test_tmp/legacy-manifest.tsv" "$manifest_path"
/bin/rm -f -- "$fixture_home/.local/lib/shanghaitech-shvpn/configure-targets.zsh" "$fixture_home/.local/lib/shanghaitech-shvpn/uninstall.zsh"

legacy_backup_count="$(/usr/bin/find "$fixture_home/.local/lib/shanghaitech-shvpn/backups" -mindepth 1 -maxdepth 1 -type d | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
HOME="$fixture_home" PATH="$fixture_path" "$fixture_repo/install.zsh" --non-interactive \
  --target 192.0.2.10 \
  --target 192.0.2.20 \
  --add-path
post_migration_backup_count="$(/usr/bin/find "$fixture_home/.local/lib/shanghaitech-shvpn/backups" -mindepth 1 -maxdepth 1 -type d | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
(( post_migration_backup_count > legacy_backup_count )) || fail "legacy migration did not preserve a new backup"
/usr/bin/cmp -s "$test_tmp/expected-targets.tsv" "$fixture_home/.config/shanghaitech-shvpn/targets.tsv" || fail "legacy target TSV was not replaced"
assert_count 0 'Host gpu' "$fixture_home/.ssh/config"
assert_count 0 'Host 192.0.2.10' "$fixture_home/.ssh/config"
assert_count 1 'Match final host 192.0.2.10,192.0.2.20' "$fixture_home/.ssh/config"
/usr/bin/grep -Fx $'format\t2' "$manifest_path" >/dev/null || fail "legacy migration did not write manifest format 2"
assert_manifest_hash config-helper "$fixture_home/.local/lib/shanghaitech-shvpn/configure-targets.zsh" "$manifest_path"
assert_manifest_hash uninstall-helper "$fixture_home/.local/lib/shanghaitech-shvpn/uninstall.zsh" "$manifest_path"
/usr/bin/awk -v begin="$begin_ssh" -v end="$end_ssh" '
  $0 == begin { inside=1 }
  inside { print }
  $0 == end { inside=0 }
' "$fixture_home/.ssh/config" >"$test_tmp/migrated-managed-ssh.block"
if /usr/bin/grep -E '^[[:space:]]+(Port|User)[[:space:]]' "$test_tmp/migrated-managed-ssh.block" >/dev/null 2>&1; then
  fail "legacy Port or User survived address-only migration"
fi

first_backup_count="$(/usr/bin/find "$fixture_home/.local/lib/shanghaitech-shvpn/backups" -mindepth 1 -maxdepth 1 -type d | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
HOME="$fixture_home" PATH="$fixture_path" "$fixture_repo/install.zsh" --non-interactive \
  --target 192.0.2.10 \
  --target 192.0.2.20 \
  --add-path
assert_count 1 "$begin_ssh" "$fixture_home/.ssh/config"
assert_count 1 "$begin_path" "$fixture_home/.zshrc"
second_backup_count="$(/usr/bin/find "$fixture_home/.local/lib/shanghaitech-shvpn/backups" -mindepth 1 -maxdepth 1 -type d | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
(( second_backup_count > first_backup_count )) || fail "idempotent reinstall did not preserve a new backup"

/bin/cp -p "$fixture_home/.ssh/config" "$test_tmp/installed-ssh-config"
client_before="$(/usr/bin/shasum -a 256 "$fixture_home/.local/bin/zju-connect" | /usr/bin/awk '{print $1}')"
/usr/bin/sed 's/Match final host 192\.0\.2\.10,192\.0\.2\.20/Match final host 192.0.2.11,192.0.2.20/' "$fixture_home/.ssh/config" >"$test_tmp/modified-ssh-config"
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
HOME="$fixture_home" PATH="$fixture_path" "$fixture_home/.local/bin/shvpn" uninstall >"$test_tmp/uninstall.out" 2>"$test_tmp/uninstall.err"
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
  --target 192.0.2.10 \
  --add-path >/dev/null
HOME="$fixture_home" PATH="$fixture_path" "$fixture_repo/uninstall.zsh" >/dev/null
/usr/bin/cmp -s "$test_tmp/original-ssh-config" "$fixture_home/.ssh/config" || fail "reinstall cycle did not restore SSH config"
/usr/bin/cmp -s "$test_tmp/original-zju-connect" "$fixture_home/.local/bin/zju-connect" || fail "reinstall cycle did not restore zju-connect"
[[ ! -e "$fixture_home/.local/lib/shanghaitech-shvpn" ]] || fail "active metadata namespace remains after reinstall cycle"

interrupted_home="$test_tmp/Interrupted Migration Home"
/usr/bin/install -d -m 700 "$interrupted_home/.ssh"
print -r -- 'Host keep' >"$interrupted_home/.ssh/config"
print -r -- '    HostName 192.0.2.30' >>"$interrupted_home/.ssh/config"
print -r -- '# interrupted fixture' >"$interrupted_home/.zshrc"
HOME="$interrupted_home" PATH="$fixture_path" "$fixture_repo/install.zsh" --non-interactive --target 192.0.2.40 --no-path >/dev/null
interrupted_manifest="$interrupted_home/.local/lib/shanghaitech-shvpn/install.manifest.tsv"
/usr/bin/awk -F '\t' -v OFS='\t' '
  $1 == "format" { $2="1" }
  $1 == "config-helper" || $1 == "uninstall-helper" { next }
  { print }
' "$interrupted_manifest" >"$test_tmp/interrupted-format1-manifest"
/usr/bin/install -m 600 "$test_tmp/interrupted-format1-manifest" "$interrupted_manifest"
set +e
HOME="$interrupted_home" PATH="$fixture_path" "$fixture_repo/install.zsh" --non-interactive --target 192.0.2.40 --no-path >"$test_tmp/interrupted-install.out" 2>"$test_tmp/interrupted-install.err"
interrupted_install_rc=$?
set -e
[[ "$interrupted_install_rc" == 65 ]] || fail "interrupted format-1 migration returned $interrupted_install_rc instead of 65"
/usr/bin/grep -F 'incomplete format-1 migration detected' "$test_tmp/interrupted-install.err" >/dev/null || fail "interrupted migration recovery message missing"
HOME="$interrupted_home" PATH="$fixture_path" "$fixture_repo/uninstall.zsh" >/dev/null || fail "standalone uninstall could not recover interrupted format-1 migration"
[[ ! -e "$interrupted_home/.local/lib/shanghaitech-shvpn" ]] || fail "standalone recovery left active metadata"

print -rn -- $'192.0.2.40\n\n' | HOME="$fixture_home" PATH="$fixture_path" "$fixture_repo/install.zsh" --no-path >/dev/null
assert_count 0 "$begin_path" "$fixture_home/.zshrc"
assert_count 1 'Match final host 192.0.2.40' "$fixture_home/.ssh/config"
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
