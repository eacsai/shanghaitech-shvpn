#!/bin/zsh

set -eu
umask 077

typeset -gr upstream_url="https://github.com/Mythologyli/zju-connect.git"
typeset -gr upstream_tag="v1.2.2"
typeset -gr upstream_commit="a759261b76ed653900911559400005b40a31392a"
typeset -gr go_mod_sha="d06b5a0423a5ce23887222d1e3f2b06b0f1c63f16873d87887c0c1147a5f7204"
typeset -gr go_sum_sha="8af52b375ebe736a54883a39bdffff6cdfb8f55face981cbbd13e3362e2e0572"
typeset -gr required_go="go1.25.6"
typeset -gr project_root="${0:A:h:h}"
typeset -gr patch_file="$project_root/patches/zju-connect-v1.2.2-node-selection.patch"

say_error() {
  print -u2 -r -- "$*"
}

if (( $# != 1 )); then
  say_error "usage: build-client.zsh OUTPUT"
  exit 64
fi

output="${1:A}"
if [[ "$(/usr/bin/uname -s)" != "Darwin" || "$(/usr/bin/uname -m)" != "arm64" ]]; then
  say_error "build-client: version 1 supports Apple Silicon macOS (Darwin/arm64) only"
  exit 69
fi

for command_name in git go shasum mktemp; do
  command -v "$command_name" >/dev/null 2>&1 || {
    say_error "build-client: required command not found: $command_name"
    exit 69
  }
done

go_version="$(go version)"
if [[ "$go_version" != "go version ${required_go} darwin/arm64" ]]; then
  say_error "build-client: Go ${required_go} for darwin/arm64 is required; found: $go_version"
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
build_tmp="$(mktemp -d "$temp_parent/shvpn-build.XXXXXX")"
cleanup() {
  if [[ -n "${build_tmp:-}" && -d "$build_tmp" && "$build_tmp" == "$temp_parent"/shvpn-build.* ]]; then
    /bin/rm -rf -- "$build_tmp"
  fi
}
trap cleanup EXIT INT TERM

source_dir="$build_tmp/source"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$upstream_tag" \
  "$upstream_url" "$source_dir"

actual_commit="$(git -C "$source_dir" rev-parse HEAD)"
[[ "$actual_commit" == "$upstream_commit" ]] || {
  say_error "build-client: upstream tag resolved to unexpected commit: $actual_commit"
  exit 65
}

actual_mod_sha="$(shasum -a 256 "$source_dir/go.mod" | /usr/bin/awk '{print $1}')"
actual_sum_sha="$(shasum -a 256 "$source_dir/go.sum" | /usr/bin/awk '{print $1}')"
[[ "$actual_mod_sha" == "$go_mod_sha" && "$actual_sum_sha" == "$go_sum_sha" ]] || {
  say_error "build-client: upstream module metadata hash mismatch"
  exit 65
}

git -C "$source_dir" apply --unidiff-zero --check "$patch_file"
git -C "$source_dir" apply --unidiff-zero "$patch_file"

(
  cd "$source_dir"
  GOTOOLCHAIN=local GOFLAGS=-mod=readonly go test ./client/atrust -count=1
  GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 GOFLAGS=-mod=readonly MACOSX_DEPLOYMENT_TARGET=12.0 \
    go build -trimpath \
      -ldflags='-s -w -buildid= -X main.zjuConnectVersion=v1.2.2-shanghaitech-nodefix1' \
      -o "$build_tmp/zju-connect" .
)

post_mod_sha="$(shasum -a 256 "$source_dir/go.mod" | /usr/bin/awk '{print $1}')"
post_sum_sha="$(shasum -a 256 "$source_dir/go.sum" | /usr/bin/awk '{print $1}')"
[[ "$post_mod_sha" == "$go_mod_sha" && "$post_sum_sha" == "$go_sum_sha" ]] || {
  say_error "build-client: module metadata changed during test/build"
  exit 65
}

/usr/bin/codesign --verify --strict "$build_tmp/zju-connect"
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
/usr/bin/codesign --verify --strict "$output"
print -r -- "Built verified zju-connect at $output"
