#!/usr/bin/env zsh

set -eu
umask 077

(( $# == 3 )) || {
  print -u2 -r -- "usage: build-login-runtime.zsh PYTHON REQUIREMENTS OUTPUT_DIR"
  exit 64
}

python_bin="$1"
requirements="$2"
output_dir="$3"

[[ -x "$python_bin" && -f "$python_bin" ]] || {
  print -u2 -r -- "build-login-runtime: Python is unavailable"
  exit 69
}
[[ -f "$requirements" && ! -L "$requirements" ]] || {
  print -u2 -r -- "build-login-runtime: requirements file is unavailable"
  exit 69
}
[[ ! -e "$output_dir" && ! -L "$output_dir" ]] || {
  print -u2 -r -- "build-login-runtime: output already exists"
  exit 65
}

/usr/bin/install -d -m 700 "$output_dir"
"$python_bin" -I -B -m pip install \
  --target "$output_dir" \
  --only-binary=:all: \
  --require-hashes \
  --no-compile \
  --no-input \
  --disable-pip-version-check \
  -r "$requirements"

# pip may leave cache metadata writable according to the caller's umask.
/bin/chmod -R go-w "$output_dir"
