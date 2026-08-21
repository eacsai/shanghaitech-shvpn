#!/usr/bin/env zsh

set -u
setopt extendedglob
umask 077

typeset -gr shvpn=@@SHVPN_Q@@
typeset -gr targets_file=@@TARGETS_Q@@
typeset -gr platform_id=@@PLATFORM_ID_Q@@
typeset -gr stat_bin=@@STAT_BIN_Q@@
typeset -gr nc_bin=@@NC_BIN_Q@@
typeset -gr socks_host="127.0.0.1"
typeset -gr socks_port="11080"
typeset -gr current_uid="$(/usr/bin/id -u)"

unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy

say_error() {
  print -u2 -r -- "$*"
}

stat_uid() {
  if [[ "$platform_id" == darwin-* ]]; then
    REPLY="$("$stat_bin" -f %u -- "$1" 2>/dev/null)" || return 1
  else
    REPLY="$("$stat_bin" -c %u -- "$1" 2>/dev/null)" || return 1
  fi
  [[ "$REPLY" == <-> ]]
}

stat_mode() {
  if [[ "$platform_id" == darwin-* ]]; then
    REPLY="$("$stat_bin" -f %Lp -- "$1" 2>/dev/null)" || return 1
  else
    REPLY="$("$stat_bin" -c %a -- "$1" 2>/dev/null)" || return 1
  fi
  [[ "$REPLY" == <-> ]]
}

if (( $# != 2 )); then
  say_error "ShanghaiTech SSH route: expected host and port"
  exit 64
fi

host="$1"
port="$2"
if [[ "$host" != [A-Za-z0-9][A-Za-z0-9.-]# || "$port" != <-> || "$port" -lt 1 || "$port" -gt 65535 ]]; then
  say_error "ShanghaiTech SSH route: invalid destination"
  exit 64
fi

if [[ ! -f "$targets_file" || -L "$targets_file" ]]; then
  say_error "ShanghaiTech SSH route: target allowlist is missing or unsafe"
  exit 255
fi
stat_uid "$targets_file" || exit 255
owner="$REPLY"
stat_mode "$targets_file" || exit 255
mode="$REPLY"
if [[ "$owner" != "$current_uid" || "$mode" != "600" ]]; then
  say_error "ShanghaiTech SSH route: target allowlist ownership or mode is unsafe"
  exit 255
fi

matched=0
typeset -A seen_targets
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" != [A-Za-z0-9][A-Za-z0-9.-]# || "$line" == *$'\t'* || -n "${seen_targets[$line]:-}" ]]; then
    say_error "ShanghaiTech SSH route: malformed target allowlist"
    exit 255
  fi
  seen_targets[$line]=1
  if [[ "$line" == "$host" ]]; then
    matched=$(( matched + 1 ))
  fi
done <"$targets_file"

if (( matched == 0 )); then
  say_error "ShanghaiTech SSH route: refusing unexpected destination $host:$port"
  exit 64
fi

if [[ ! -f "$shvpn" || -L "$shvpn" || ! -x "$shvpn" ]]; then
  say_error "ShanghaiTech SSH route: trusted shvpn helper is unavailable"
  exit 255
fi

"$shvpn" status >/dev/null 2>&1
vpn_status=$?
case "$vpn_status" in
  0)
    exec "$nc_bin" -x "$socks_host:$socks_port" -X 5 "$host" "$port"
    ;;
  1)
    exec "$nc_bin" "$host" "$port"
    ;;
  *)
    say_error "ShanghaiTech SSH route: shvpn state is unsafe or cannot be verified"
    exit 255
    ;;
esac
