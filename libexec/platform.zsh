#!/usr/bin/env zsh

# Build/install-time platform helpers. Installed runtime programs receive the
# resolved platform id and absolute command paths as rendered constants; they do
# not source this file from a mutable user directory.

typeset -g shvpn_os=""
typeset -g shvpn_machine=""
typeset -g shvpn_platform_id=""
typeset -g shvpn_goos=""
typeset -g shvpn_goarch=""
typeset -g shvpn_stat=""
typeset -g shvpn_sha256=""

shvpn_resolve_command() {
  local command_name="$1"
  local resolved
  resolved="$(command -v -- "$command_name" 2>/dev/null)" || return 1
  [[ "$resolved" == /* ]] || return 1
  resolved="${resolved:A}"
  [[ -f "$resolved" && -x "$resolved" ]] || return 1
  REPLY="$resolved"
}

shvpn_detect_platform() {
  local uname_bin
  shvpn_resolve_command uname || return 1
  uname_bin="$REPLY"
  shvpn_os="$($uname_bin -s)" || return 1
  shvpn_machine="$($uname_bin -m)" || return 1

  case "$shvpn_os:$shvpn_machine" in
    Darwin:arm64)
      shvpn_platform_id="darwin-arm64"
      shvpn_goos="darwin"
      shvpn_goarch="arm64"
      ;;
    Linux:x86_64|Linux:amd64)
      shvpn_platform_id="linux-amd64"
      shvpn_goos="linux"
      shvpn_goarch="amd64"
      ;;
    Linux:aarch64|Linux:arm64)
      shvpn_platform_id="linux-arm64"
      shvpn_goos="linux"
      shvpn_goarch="arm64"
      ;;
    *)
      return 1
      ;;
  esac

  shvpn_resolve_command stat || return 1
  shvpn_stat="$REPLY"
  if [[ "$shvpn_os" == "Darwin" ]]; then
    shvpn_resolve_command shasum || return 1
  else
    shvpn_resolve_command sha256sum || return 1
  fi
  shvpn_sha256="$REPLY"
}

shvpn_stat_uid() {
  if [[ "$shvpn_os" == "Darwin" ]]; then
    REPLY="$($shvpn_stat -f %u -- "$1" 2>/dev/null)" || return 1
  else
    REPLY="$($shvpn_stat -c %u -- "$1" 2>/dev/null)" || return 1
  fi
  [[ "$REPLY" == <-> ]]
}

shvpn_stat_mode() {
  if [[ "$shvpn_os" == "Darwin" ]]; then
    REPLY="$($shvpn_stat -f %Lp -- "$1" 2>/dev/null)" || return 1
  else
    REPLY="$($shvpn_stat -c %a -- "$1" 2>/dev/null)" || return 1
  fi
  [[ "$REPLY" == <-> ]]
}

shvpn_sha_file() {
  if [[ "$shvpn_os" == "Darwin" ]]; then
    REPLY="$($shvpn_sha256 -a 256 -- "$1" | /usr/bin/awk '{print $1}')" || return 1
  else
    REPLY="$($shvpn_sha256 -- "$1" | /usr/bin/awk '{print $1}')" || return 1
  fi
  [[ "$REPLY" == [0-9a-f](#c64) ]]
}
