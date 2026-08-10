#!/bin/zsh

set -u
setopt extendedglob
umask 077

typeset -gr shvpn=@@SHVPN_Q@@
typeset -gr targets_file=@@TARGETS_Q@@
typeset -gr socks_host="127.0.0.1"
typeset -gr socks_port="11080"
typeset -gr current_uid="$(/usr/bin/id -u)"

unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy

say_error() {
  print -u2 -r -- "$*"
}

if (( $# != 2 )); then
  say_error "ShanghaiTech SSH route: expected host and port"
  exit 64
fi

host="$1"
port="$2"
if [[ -z "$host" || "$host" == *[[:cntrl:]]* || "$port" != <-> || "$port" -lt 1 || "$port" -gt 65535 ]]; then
  say_error "ShanghaiTech SSH route: invalid destination"
  exit 64
fi

if [[ ! -f "$targets_file" || -L "$targets_file" ]]; then
  say_error "ShanghaiTech SSH route: target allowlist is missing or unsafe"
  exit 255
fi
owner="$(/usr/bin/stat -f %u "$targets_file" 2>/dev/null)" || exit 255
mode="$(/usr/bin/stat -f %Lp "$targets_file" 2>/dev/null)" || exit 255
if [[ "$owner" != "$current_uid" || "$mode" != "600" ]]; then
  say_error "ShanghaiTech SSH route: target allowlist ownership or mode is unsafe"
  exit 255
fi

matched=0
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "$line" ]] || {
    say_error "ShanghaiTech SSH route: malformed target allowlist"
    exit 255
  }
  without_tabs="${line//$'\t'/}"
  (( ${#line} - ${#without_tabs} == 3 )) || {
    say_error "ShanghaiTech SSH route: malformed target allowlist"
    exit 255
  }
  IFS=$'\t' read -r target_alias target_host target_port target_user <<<"$line"
  if [[ "$target_alias" != [A-Za-z0-9][A-Za-z0-9._-]# ||
        "$target_host" != [A-Za-z0-9][A-Za-z0-9.-]# ||
        "$target_port" != <-> || "$target_port" -lt 1 || "$target_port" -gt 65535 ||
        ( "$target_user" != "-" && "$target_user" != [A-Za-z_][A-Za-z0-9_.-]# ) ]]; then
    say_error "ShanghaiTech SSH route: malformed target allowlist"
    exit 255
  fi
  if [[ "$target_host" == "$host" && "$target_port" == "$port" ]]; then
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
    exec /usr/bin/nc -x "$socks_host:$socks_port" -X 5 "$host" "$port"
    ;;
  1)
    exec /usr/bin/nc "$host" "$port"
    ;;
  *)
    say_error "ShanghaiTech SSH route: shvpn state is unsafe or cannot be verified"
    exit 255
    ;;
esac
