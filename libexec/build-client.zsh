#!/usr/bin/env zsh

set -eu
setopt extendedglob
umask 077

typeset -gr upstream_url="https://github.com/Mythologyli/zju-connect.git"
typeset -gr upstream_tag="v1.2.2"
typeset -gr upstream_commit="a759261b76ed653900911559400005b40a31392a"
typeset -gr go_mod_sha="d06b5a0423a5ce23887222d1e3f2b06b0f1c63f16873d87887c0c1147a5f7204"
typeset -gr go_sum_sha="8af52b375ebe736a54883a39bdffff6cdfb8f55face981cbbd13e3362e2e0572"
typeset -gr required_go="go1.25.6"
typeset -gr project_root="${0:A:h:h}"
typeset -gr patch_file="$project_root/patches/zju-connect-v1.2.2-node-selection.patch"
typeset -gr platform_helper="$project_root/libexec/platform.zsh"

say_error() {
  print -u2 -r -- "$*"
}

if (( $# != 1 )); then
  say_error "usage: build-client.zsh OUTPUT"
  exit 64
fi

output="${1:A}"
[[ -f "$platform_helper" && ! -L "$platform_helper" ]] || {
  say_error "build-client: platform helper is missing or unsafe"
  exit 69
}
source "$platform_helper"
shvpn_detect_platform || {
  say_error "build-client: supported platforms are Darwin/arm64, Linux/amd64, and Linux/arm64"
  exit 69
}

for command_name in git go mktemp; do
  shvpn_resolve_command "$command_name" || {
    say_error "build-client: required command not found: $command_name"
    exit 69
  }
  typeset -g "${command_name}_bin=$REPLY"
done
codesign_bin=""
if [[ "$shvpn_os" == "Darwin" ]]; then
  shvpn_resolve_command codesign || {
    say_error "build-client: required command not found: codesign"
    exit 69
  }
  codesign_bin="$REPLY"
fi

go_version="$($go_bin version)"
if [[ "$go_version" != "go version ${required_go} ${shvpn_goos}/${shvpn_goarch}" ]]; then
  say_error "build-client: Go ${required_go} for ${shvpn_goos}/${shvpn_goarch} is required; found: $go_version"
  exit 69
fi

[[ -f "$patch_file" && ! -L "$patch_file" ]] || {
  say_error "build-client: patch is missing or unsafe: $patch_file"
  exit 69
}

temp_parent="${TMPDIR:-/tmp}"
[[ -d "$temp_parent" && "$temp_parent" == /* ]] || {
  say_error "build-client: TMPDIR must name an existing absolute directory"
  exit 69
}
build_tmp="$($mktemp_bin -d "$temp_parent/shvpn-build.XXXXXX")"
cleanup() {
  if [[ -n "${build_tmp:-}" && -d "$build_tmp" && "$build_tmp" == "$temp_parent"/shvpn-build.* ]]; then
    /bin/rm -rf -- "$build_tmp"
  fi
}
trap cleanup EXIT INT TERM

source_dir="$build_tmp/source"
"$git_bin" -c advice.detachedHead=false clone --quiet --depth 1 --branch "$upstream_tag" \
  "$upstream_url" "$source_dir"

actual_commit="$("$git_bin" -C "$source_dir" rev-parse HEAD)"
[[ "$actual_commit" == "$upstream_commit" ]] || {
  say_error "build-client: upstream tag resolved to unexpected commit: $actual_commit"
  exit 65
}

shvpn_sha_file "$source_dir/go.mod" || exit 74
actual_mod_sha="$REPLY"
shvpn_sha_file "$source_dir/go.sum" || exit 74
actual_sum_sha="$REPLY"
[[ "$actual_mod_sha" == "$go_mod_sha" && "$actual_sum_sha" == "$go_sum_sha" ]] || {
  say_error "build-client: upstream module metadata hash mismatch"
  exit 65
}

"$git_bin" -C "$source_dir" apply --unidiff-zero --check "$patch_file"
"$git_bin" -C "$source_dir" apply --unidiff-zero "$patch_file"

(
  cd "$source_dir"
  GOTOOLCHAIN=local GOFLAGS=-mod=readonly "$go_bin" test ./client/atrust -count=1
  if [[ "$shvpn_os" == "Darwin" ]]; then
    GOTOOLCHAIN=local CGO_ENABLED=0 GOOS="$shvpn_goos" GOARCH="$shvpn_goarch" GOFLAGS=-mod=readonly MACOSX_DEPLOYMENT_TARGET=12.0 \
      "$go_bin" build -trimpath \
        -ldflags='-s -w -buildid= -X main.zjuConnectVersion=v1.2.2-shanghaitech-nodefix1' \
        -o "$build_tmp/zju-connect" .
  else
    GOTOOLCHAIN=local CGO_ENABLED=0 GOOS="$shvpn_goos" GOARCH="$shvpn_goarch" GOFLAGS=-mod=readonly \
      "$go_bin" build -trimpath \
        -ldflags='-s -w -buildid= -X main.zjuConnectVersion=v1.2.2-shanghaitech-nodefix1' \
        -o "$build_tmp/zju-connect" .
  fi
)

shvpn_sha_file "$source_dir/go.mod" || exit 74
post_mod_sha="$REPLY"
shvpn_sha_file "$source_dir/go.sum" || exit 74
post_sum_sha="$REPLY"
[[ "$post_mod_sha" == "$go_mod_sha" && "$post_sum_sha" == "$go_sum_sha" ]] || {
  say_error "build-client: module metadata changed during test/build"
  exit 65
}

if [[ -n "$codesign_bin" ]]; then
  "$codesign_bin" --verify --strict "$build_tmp/zju-connect"
fi
[[ "$("$build_tmp/zju-connect" -version)" == "ZJU Connect v1.2.2-shanghaitech-nodefix1" ]] || {
  say_error "build-client: built client failed its version smoke test"
  exit 65
}
mkdir -p "${output:h}"
if [[ -e "$output" || -L "$output" ]]; then
  [[ -f "$output" && ! -L "$output" ]] || {
    say_error "build-client: refusing unsafe output path: $output"
    exit 69
  }
fi
/bin/cp "$build_tmp/zju-connect" "$output"
/bin/chmod 755 "$output"
if [[ -n "$codesign_bin" ]]; then
  "$codesign_bin" --verify --strict "$output"
fi
print -r -- "Built verified zju-connect at $output"
