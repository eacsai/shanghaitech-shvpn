#!/bin/zsh

set -u
umask 077

typeset -gr client=@@CLIENT_Q@@
typeset -gr launcher=@@LAUNCHER_Q@@
typeset -gr self=@@SHVPN_Q@@
typeset -gr state_dir=@@STATE_DIR_Q@@
typeset -gr client_data="$state_dir/client-data.json"
typeset -gr log_file="$state_dir/shvpn.log"
typeset -gr lock_file="$state_dir/shvpn.operation.lock"
typeset -gr bind_host="127.0.0.1"
typeset -gr bind_port="11080"
typeset -gr current_uid="$(/usr/bin/id -u)"
typeset -gr expected_client_command="$client -protocol atrust -server vpn.shanghaitech.edu.cn -port 443 -login-domain Shanghaitech.edu.cn -auth-type auth/cas -client-data-file $client_data -socks-bind $bind_host:$bind_port -http-bind  -auto-detect-interface"
typeset -gr expected_wrapper_command="/bin/zsh $launcher"
typeset -g operation_lock_fd

unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy

say_error() {
  print -u2 -r -- "$*"
}

usage() {
  print -u2 -r -- "usage: shvpn [start|stop|status|login]"
}

get_listener_pid() {
  REPLY=""
  local output line
  local rc
  local -a pids
  pids=()

  output="$(/usr/sbin/lsof -nP -a -iTCP@${bind_host}:${bind_port} -sTCP:LISTEN -Fpu 2>/dev/null)"
  rc=$?
  if (( rc != 0 )); then
    if /usr/bin/nc -z "$bind_host" "$bind_port" >/dev/null 2>&1; then
      return 2
    fi
    return 1
  fi

  for line in ${(f)output}; do
    if [[ "$line" == p<-> ]]; then
      pids+=("${line#p}")
    fi
  done

  (( ${#pids} == 1 )) || return 2
  REPLY="${pids[1]}"
  return 0
}

get_process_executable() {
  REPLY=""
  local pid="$1"
  local output line

  output="$(/usr/sbin/lsof -nP -a -p "$pid" -d txt -Fn 2>/dev/null)" || return 1
  for line in ${(f)output}; do
    if [[ "$line" == n* ]]; then
      REPLY="${line#n}"
      return 0
    fi
  done
  return 1
}

get_process_uid() {
  REPLY=""
  local pid="$1"
  local uid

  uid="$(/bin/ps -p "$pid" -o uid= 2>/dev/null)" || return 1
  uid="${uid//[[:space:]]/}"
  [[ "$uid" == <-> ]] || return 1
  REPLY="$uid"
  return 0
}

get_process_command() {
  REPLY=""
  local pid="$1"
  local command_line

  command_line="$(/bin/ps -ww -p "$pid" -o command= 2>/dev/null)" || return 1
  [[ -n "$command_line" ]] || return 1
  REPLY="$command_line"
  return 0
}

trusted_client_pid() {
  local pid="$1"
  local uid executable command_line

  [[ "$pid" == <-> ]] || return 1
  get_process_uid "$pid" || return 1
  uid="$REPLY"
  [[ "$uid" == "$current_uid" ]] || return 1
  get_process_executable "$pid" || return 1
  executable="$REPLY"
  [[ "$executable" == "$client" ]] || return 1
  get_process_command "$pid" || return 1
  command_line="$REPLY"
  [[ "$command_line" == "$expected_client_command" ]] || return 1
  return 0
}

trusted_wrapper_pid() {
  local pid="$1"
  local uid executable command_line

  [[ "$pid" == <-> ]] || return 1
  get_process_uid "$pid" || return 1
  uid="$REPLY"
  [[ "$uid" == "$current_uid" ]] || return 1
  get_process_executable "$pid" || return 1
  executable="$REPLY"
  [[ "$executable" == "/bin/zsh" ]] || return 1
  get_process_command "$pid" || return 1
  command_line="$REPLY"
  [[ "$command_line" == "$expected_wrapper_command" ]] || return 1
  return 0
}

prepare_runtime() {
  if [[ ! -f "$client" || -L "$client" || ! -x "$client" ]]; then
    say_error "shvpn: trusted client is unavailable: $client"
    return 69
  fi
  if [[ ! -f "$launcher" || -L "$launcher" || ! -x "$launcher" ]]; then
    say_error "shvpn: trusted launcher is unavailable: $launcher"
    return 69
  fi
  if [[ -e "$state_dir" && ( ! -d "$state_dir" || -L "$state_dir" ) ]]; then
    say_error "shvpn: unsafe state directory: $state_dir"
    return 69
  fi
  /usr/bin/install -d -m 700 "$state_dir" || return 69
  /bin/chmod 700 "$state_dir" || return 69
  if [[ -e "$log_file" && ( ! -f "$log_file" || -L "$log_file" ) ]]; then
    say_error "shvpn: unsafe log path: $log_file"
    return 69
  fi
  /usr/bin/touch "$log_file" || return 69
  /bin/chmod 600 "$log_file" || return 69
  return 0
}

acquire_operation_lock() {
  if [[ -e "$lock_file" && ( ! -f "$lock_file" || -L "$lock_file" ) ]]; then
    say_error "shvpn: unsafe lock path: $lock_file"
    return 69
  fi
  /usr/bin/touch "$lock_file" || return 69
  /bin/chmod 600 "$lock_file" || return 69
  if ! zmodload zsh/system; then
    say_error "shvpn: zsh/system locking support is unavailable"
    return 69
  fi
  if ! zsystem flock -t 0 -f operation_lock_fd -e "$lock_file"; then
    say_error "shvpn: another start, stop, or login operation is in progress"
    return 75
  fi
  return 0
}

show_status() {
  local pid rc

  get_listener_pid
  rc=$?
  case "$rc" in
    0)
      pid="$REPLY"
      if trusted_client_pid "$pid"; then
        print -r -- "ShanghaiTech VPN is running (PID $pid, SOCKS ${bind_host}:${bind_port})."
        return 0
      fi
      say_error "shvpn: port ${bind_host}:${bind_port} is owned by an untrusted process; refusing"
      return 2
      ;;
    1)
      print -r -- "ShanghaiTech VPN is stopped."
      return 1
      ;;
    *)
      say_error "shvpn: cannot identify the listener on ${bind_host}:${bind_port}; refusing"
      return 2
      ;;
  esac
}

cleanup_started_job() {
  local wrapper_pid="$1"
  local children_text child_pid
  local wrapper_owned=0
  local signal_sent=0
  local alive=0
  local i
  local -a owned_children residuals
  owned_children=()
  residuals=()

  if trusted_wrapper_pid "$wrapper_pid"; then
    wrapper_owned=1
  fi

  children_text="$(/usr/bin/pgrep -P "$wrapper_pid" 2>/dev/null)"
  for child_pid in ${(f)children_text}; do
    if trusted_client_pid "$child_pid"; then
      owned_children+=("$child_pid")
    fi
  done

  for child_pid in "${owned_children[@]}"; do
    if trusted_client_pid "$child_pid"; then
      if /bin/kill -INT "$child_pid" 2>/dev/null; then
        signal_sent=1
      fi
    fi
  done
  if (( wrapper_owned )); then
    if trusted_wrapper_pid "$wrapper_pid"; then
      if /bin/kill -INT "$wrapper_pid" 2>/dev/null; then
        signal_sent=1
      fi
    fi
  fi

  for (( i = 0; i < 40; i++ )); do
    alive=0
    if /bin/kill -0 "$wrapper_pid" 2>/dev/null; then
      alive=1
    fi
    for child_pid in "${owned_children[@]}"; do
      if /bin/kill -0 "$child_pid" 2>/dev/null; then
        alive=1
      fi
    done
    (( alive == 0 )) && break
    /bin/sleep 0.25
  done

  if (( alive == 0 )); then
    wait "$wrapper_pid" 2>/dev/null || true
    [[ -f "$client_data" ]] && /bin/chmod 600 "$client_data"
    return 0
  fi

  if /bin/kill -0 "$wrapper_pid" 2>/dev/null; then
    residuals+=("wrapper PID $wrapper_pid")
  fi
  for child_pid in "${owned_children[@]}"; do
    if /bin/kill -0 "$child_pid" 2>/dev/null; then
      residuals+=("client PID $child_pid")
    fi
  done
  if (( ${#residuals} == 0 )); then
    wait "$wrapper_pid" 2>/dev/null || true
    [[ -f "$client_data" ]] && /bin/chmod 600 "$client_data"
    return 0
  fi

  if (( signal_sent )); then
    say_error "shvpn: residual start job after SIGINT: ${(j:, :)residuals}; no stronger signal was sent"
  else
    say_error "shvpn: no SIGINT was successfully sent; residual start job: ${(j:, :)residuals}; no stronger signal was sent"
  fi
  return 3
}

start_vpn() {
  local pid rc wrapper_pid wrapper_rc cleanup_rc
  local final_class=1
  local ambiguous_count=0
  local i

  get_listener_pid
  rc=$?
  if (( rc == 0 )); then
    pid="$REPLY"
    if trusted_client_pid "$pid"; then
      print -r -- "ShanghaiTech VPN is already running (PID $pid)."
      return 0
    fi
    say_error "shvpn: port ${bind_host}:${bind_port} is owned by an untrusted process; refusing"
    return 2
  elif (( rc == 2 )); then
    say_error "shvpn: cannot safely identify port ${bind_host}:${bind_port}; refusing"
    return 2
  fi

  print -r -- "=== shvpn start $(/bin/date -u +%Y-%m-%dT%H:%M:%SZ) command-pid=$$ ===" >>"$log_file"
  /usr/bin/nohup "$launcher" </dev/null >>"$log_file" 2>&1 &
  wrapper_pid=$!

  for (( i = 0; i < 80; i++ )); do
    get_listener_pid
    rc=$?
    if (( rc == 0 )); then
      pid="$REPLY"
      if trusted_client_pid "$pid"; then
        print -r -- "ShanghaiTech VPN started (PID $pid, SOCKS ${bind_host}:${bind_port})."
        return 0
      fi
      say_error "shvpn: an untrusted process claimed port ${bind_host}:${bind_port} during start"
      cleanup_started_job "$wrapper_pid"
      cleanup_rc=$?
      (( cleanup_rc == 0 )) && return 2
      return "$cleanup_rc"
    elif (( rc == 2 )); then
      ambiguous_count=$(( ambiguous_count + 1 ))
      if (( ambiguous_count < 4 )); then
        /bin/sleep 0.25
        continue
      fi
      say_error "shvpn: listener identity became ambiguous during start"
      cleanup_started_job "$wrapper_pid"
      cleanup_rc=$?
      (( cleanup_rc == 0 )) && return 2
      return "$cleanup_rc"
    else
      ambiguous_count=0
    fi

    if ! /bin/kill -0 "$wrapper_pid" 2>/dev/null; then
      wait "$wrapper_pid" 2>/dev/null
      wrapper_rc=$?
      [[ -f "$client_data" ]] && /bin/chmod 600 "$client_data"
      say_error "shvpn: VPN start exited with status $wrapper_rc; see $log_file"
      say_error "shvpn: if login expired, run: shvpn login"
      return 1
    fi
    /bin/sleep 0.25
  done

  get_listener_pid
  rc=$?
  if (( rc == 0 )); then
    pid="$REPLY"
    if trusted_client_pid "$pid"; then
      print -r -- "ShanghaiTech VPN started (PID $pid, SOCKS ${bind_host}:${bind_port})."
      return 0
    fi
    say_error "shvpn: an untrusted process owns port ${bind_host}:${bind_port} after the start timeout"
    final_class=2
  elif (( rc == 2 )); then
    say_error "shvpn: listener identity is ambiguous after the start timeout"
    final_class=2
  fi

  cleanup_started_job "$wrapper_pid"
  cleanup_rc=$?
  (( cleanup_rc != 0 )) && return "$cleanup_rc"
  (( final_class == 2 )) && return 2
  say_error "shvpn: VPN did not become ready within 20 seconds; see $log_file"
  say_error "shvpn: if login expired, run: shvpn login"
  return 1
}

stop_vpn() {
  local pid rc
  local i

  get_listener_pid
  rc=$?
  if (( rc == 1 )); then
    print -r -- "ShanghaiTech VPN is already stopped."
    return 0
  elif (( rc != 0 )); then
    say_error "shvpn: cannot safely identify port ${bind_host}:${bind_port}; refusing"
    return 2
  fi

  pid="$REPLY"
  if ! trusted_client_pid "$pid"; then
    say_error "shvpn: port ${bind_host}:${bind_port} is owned by an untrusted process; refusing"
    return 2
  fi

  if ! /bin/kill -INT "$pid"; then
    if ! /bin/kill -0 "$pid" 2>/dev/null; then
      get_listener_pid
      rc=$?
      if (( rc == 1 )); then
        [[ -f "$client_data" ]] && /bin/chmod 600 "$client_data"
        print -r -- "ShanghaiTech VPN stopped."
        return 0
      fi
      say_error "shvpn: the original VPN exited but port ${bind_host}:${bind_port} is now occupied; refusing"
      return 2
    fi
    say_error "shvpn: failed to send SIGINT to trusted PID $pid"
    return 3
  fi
  for (( i = 0; i < 40; i++ )); do
    if ! /bin/kill -0 "$pid" 2>/dev/null; then
      get_listener_pid
      rc=$?
      if (( rc == 1 )); then
        [[ -f "$client_data" ]] && /bin/chmod 600 "$client_data"
        print -r -- "ShanghaiTech VPN stopped."
        return 0
      fi
      say_error "shvpn: the original VPN exited but port ${bind_host}:${bind_port} is now occupied; refusing"
      return 2
    fi
    /bin/sleep 0.25
  done

  say_error "shvpn: PID $pid did not exit after 10 seconds; no stronger signal was sent"
  return 3
}

login_vpn() {
  local pid rc

  get_listener_pid
  rc=$?
  if (( rc == 0 )); then
    pid="$REPLY"
    if trusted_client_pid "$pid"; then
      say_error "shvpn: VPN is already running; use 'shvpn stop' before an interactive login"
    else
      say_error "shvpn: port ${bind_host}:${bind_port} is owned by an untrusted process; refusing"
    fi
    return 2
  elif (( rc == 2 )); then
    say_error "shvpn: cannot safely identify port ${bind_host}:${bind_port}; refusing"
    return 2
  fi

  "$launcher"
  return $?
}

if (( $# > 1 )); then
  usage
  exit 64
fi

action="${1:-start}"
case "$action" in
  status)
    show_status
    exit $?
    ;;
  start|stop|login)
    prepare_runtime || exit $?
    acquire_operation_lock || exit $?
    case "$action" in
      start) start_vpn ;;
      stop) stop_vpn ;;
      login) login_vpn ;;
    esac
    exit $?
    ;;
  *)
    usage
    exit 64
    ;;
esac
