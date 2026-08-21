#!/usr/bin/env zsh

set -eu
setopt extendedglob
umask 077

typeset -gr project_root="${0:A:h:h}"
temp_parent="${${TMPDIR:-/tmp}:A}"
test_tmp="$(/usr/bin/mktemp -d "$temp_parent/shvpn-platform-tests.XXXXXX")"
cleanup() {
  [[ -d "$test_tmp" && "$test_tmp" == "$temp_parent"/shvpn-platform-tests.* ]] && /bin/rm -rf -- "$test_tmp"
}
trap cleanup EXIT INT TERM

fake_bin="$test_tmp/bin"
/usr/bin/install -d -m 700 "$fake_bin"

for command_name in stat shasum sha256sum; do
  /usr/bin/install -m 700 /usr/bin/true "$fake_bin/$command_name"
done

typeset -A expected
expected[Darwin:arm64]='darwin-arm64 darwin arm64'
expected[Linux:x86_64]='linux-amd64 linux amd64'
expected[Linux:aarch64]='linux-arm64 linux arm64'

for platform_case in ${(k)expected}; do
  os_name="${platform_case%%:*}"
  machine_name="${platform_case#*:}"
  {
    print -r -- '#!/usr/bin/env zsh'
    print -r -- '[[ "$1" == "-s" ]] && { print -r -- "$TEST_OS"; exit 0; }'
    print -r -- '[[ "$1" == "-m" ]] && { print -r -- "$TEST_MACHINE"; exit 0; }'
    print -r -- 'print -u2 -r -- "unexpected uname arguments"'
    print -r -- 'exit 64'
  } >"$test_tmp/uname"
  /usr/bin/install -m 700 "$test_tmp/uname" "$fake_bin/uname"
  actual="$(
    TEST_OS="$os_name" TEST_MACHINE="$machine_name" PATH="$fake_bin:/usr/bin:/bin" \
      /bin/zsh -fc 'setopt extendedglob; source "$1"; shvpn_detect_platform || exit 1; print -r -- "$shvpn_platform_id $shvpn_goos $shvpn_goarch"' \
      shvpn-platform-test "$project_root/libexec/platform.zsh"
  )"
  [[ "$actual" == "${expected[$platform_case]}" ]] || {
    print -u2 -r -- "platform test: $platform_case produced '$actual'"
    exit 1
  }
done

set +e
TEST_OS=Linux TEST_MACHINE=riscv64 PATH="$fake_bin:/usr/bin:/bin" \
  /bin/zsh -fc 'setopt extendedglob; source "$1"; shvpn_detect_platform' \
  shvpn-platform-test "$project_root/libexec/platform.zsh" >/dev/null 2>&1
unsupported_rc=$?
set -e
[[ "$unsupported_rc" != 0 ]] || {
  print -u2 -r -- "platform test: unsupported architecture was accepted"
  exit 1
}

print -r -- "Platform mapping tests passed."
