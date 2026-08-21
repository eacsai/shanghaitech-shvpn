#!/usr/bin/env zsh

set -u
setopt extendedglob
umask 077

typeset -gr client=@@CLIENT_Q@@
typeset -gr launcher=@@LAUNCHER_Q@@
typeset -gr self=@@SHVPN_Q@@
typeset -gr state_dir=@@STATE_DIR_Q@@
typeset -gr targets_file=@@TARGETS_Q@@
typeset -gr route=@@ROUTE_Q@@
typeset -gr expected_route_proxy=@@ROUTE_PROXY_Q@@
typeset -gr ssh_config=@@SSH_CONFIG_Q@@
typeset -gr manifest=@@MANIFEST_Q@@
typeset -gr config_helper=@@CONFIG_HELPER_Q@@
typeset -gr uninstall_helper=@@UNINSTALL_HELPER_Q@@
typeset -gr config_lock_file=@@CONFIG_LOCK_Q@@
typeset -gr login_helper=@@LOGIN_HELPER_Q@@
typeset -gr login_requirements=@@LOGIN_REQUIREMENTS_Q@@
typeset -gr login_packages=@@LOGIN_PACKAGES_Q@@
typeset -gr platform_id=@@PLATFORM_ID_Q@@
typeset -gr stat_bin=@@STAT_BIN_Q@@
typeset -gr sha_bin=@@SHA_BIN_Q@@
typeset -gr nc_bin=@@NC_BIN_Q@@
typeset -gr lsof_bin=@@LSOF_BIN_Q@@
typeset -gr ps_bin=@@PS_BIN_Q@@
typeset -gr pgrep_bin=@@PGREP_BIN_Q@@
typeset -gr zsh_bin=@@ZSH_BIN_Q@@
typeset -gr nohup_bin=@@NOHUP_BIN_Q@@
typeset -gr chrome_bin=@@CHROME_BIN_Q@@
typeset -gr ssh_root="${ssh_config:h}"
typeset -gr ssh_client=@@SSH_BIN_Q@@
typeset -gr client_data="$state_dir/client-data.json"
typeset -gr log_file="$state_dir/shvpn.log"
typeset -gr lock_file="$state_dir/shvpn.operation.lock"
typeset -gr bind_host="127.0.0.1"
typeset -gr bind_port="11080"
typeset -gr current_uid="$(/usr/bin/id -u)"
typeset -gr expected_client_command="$client -protocol atrust -server vpn.shanghaitech.edu.cn -port 443 -login-domain Shanghaitech.edu.cn -auth-type auth/cas -client-data-file $client_data -socks-bind $bind_host:$bind_port -http-bind  -auto-detect-interface"
typeset -gr expected_wrapper_command="$zsh_bin $launcher"
typeset -g operation_lock_fd
typeset -g config_lock_fd

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

usage() {
  print -u2 -r -- "usage: shvpn [start|stop|status|login|uninstall]"
  print -u2 -r -- "   or: shvpn add SSH_NAME_OR_HOST"
  print -u2 -r -- "   or: shvpn remove SSH_NAME_OR_HOST"
  print -u2 -r -- "   or: shvpn doctor [SSH_NAME ...]"
  print -u2 -r -- "   or: shvpn reconnect [SSH_NAME ...]"
}

typeset -ga target_hosts discovered_ssh_names candidate_ssh_names
typeset -gA target_set explicit_name_set
typeset -g alias_scan_incomplete=0
typeset -g resolved_host=""
typeset -g resolved_proxy=""

safe_owned_regular() {
  local file_path="$1"
  [[ -f "$file_path" && ! -L "$file_path" ]] || return 1
  stat_uid "$file_path" || return 1
  [[ "$REPLY" == "$current_uid" ]]
}

safe_owned_executable() {
  safe_owned_regular "$1" && [[ -x "$1" ]]
}

safe_login_python() {
  local python_bin="$1"
  local resolved mode owner permission
  [[ -x "$python_bin" ]] || return 1
  resolved="${python_bin:A}"
  [[ -f "$resolved" && -x "$resolved" && ! -L "$resolved" ]] || return 1
  stat_uid "$resolved" || return 1
  owner="$REPLY"
  [[ "$owner" == 0 || "$owner" == "$current_uid" ]] || return 1
  stat_mode "$resolved" || return 1
  mode="$REPLY"
  [[ "$mode" == <-> ]] || return 1
  permission=$(( 8#$mode ))
  (( (permission & 8#022) == 0 ))
}

safe_chrome_executable() {
  local chrome_path="$1"
  local resolved mode owner permission
  [[ -x "$chrome_path" ]] || return 1
  resolved="${chrome_path:A}"
  [[ -f "$resolved" && -x "$resolved" && ! -L "$resolved" ]] || return 1
  stat_uid "$resolved" || return 1
  owner="$REPLY"
  [[ "$owner" == 0 || "$owner" == "$current_uid" ]] || return 1
  stat_mode "$resolved" || return 1
  mode="$REPLY"
  [[ "$mode" == <-> ]] || return 1
  permission=$(( 8#$mode ))
  (( (permission & 8#002) == 0 ))
}

sha_file() {
  if [[ "$platform_id" == darwin-* ]]; then
    REPLY="$("$sha_bin" -a 256 -- "$1" | /usr/bin/awk '{print $1}')" || return 1
  else
    REPLY="$("$sha_bin" -- "$1" | /usr/bin/awk '{print $1}')" || return 1
  fi
  [[ "$REPLY" == [0-9a-f](#c64) ]]
}

manifest_get() {
  local key="$1"
  REPLY="$(/usr/bin/awk -F '\t' -v key="$key" '
    $1 == key { count++; value=$2 }
    END { if (count != 1 || value == "") exit 65; print value }
  ' "$manifest")" || return 1
}

verify_installed_helper() {
  local key="$1"
  local helper="$2"
  local mode expected
  if ! safe_owned_regular "$manifest"; then
    say_error "shvpn: install manifest is missing or unsafe"
    return 69
  fi
  stat_mode "$manifest" || return 69
  mode="$REPLY"
  if [[ "$mode" != "600" ]]; then
    say_error "shvpn: install manifest mode is unsafe"
    return 69
  fi
  manifest_get format || { say_error "shvpn: invalid install manifest"; return 65; }
  if [[ "$REPLY" != "4" ]]; then
    say_error "shvpn: this command requires install manifest format 4; reinstall shvpn"
    return 65
  fi
  manifest_get platform || { say_error "shvpn: install manifest has no platform entry"; return 65; }
  [[ "$REPLY" == "$platform_id" ]] || { say_error "shvpn: install manifest belongs to another platform"; return 65; }
  manifest_get state-dir || { say_error "shvpn: install manifest has no state directory"; return 65; }
  [[ "$REPLY" == "$state_dir" ]] || { say_error "shvpn: install manifest state directory does not match"; return 65; }
  if ! safe_owned_executable "$helper"; then
    say_error "shvpn: managed helper is missing or unsafe: $helper"
    return 69
  fi
  stat_mode "$helper" || return 69
  mode="$REPLY"
  if [[ "$mode" != "700" ]]; then
    say_error "shvpn: managed helper mode is unsafe: $helper"
    return 69
  fi
  manifest_get "$key" || { say_error "shvpn: missing install manifest entry: $key"; return 65; }
  expected="$REPLY"
  sha_file "$helper" || return 74
  if [[ "$REPLY" != "$expected" ]]; then
    say_error "shvpn: managed helper was modified; refusing: $helper"
    return 2
  fi
  return 0
}

verify_login_runtime() {
  local key expected python_bin python_version python_sha actual_version actual_sha actual_tree mode
  safe_owned_regular "$manifest" || { say_error "shvpn: install manifest is missing or unsafe"; return 69; }
  stat_mode "$manifest" || return 69
  mode="$REPLY"
  [[ "$mode" == "600" ]] || { say_error "shvpn: install manifest mode is unsafe"; return 69; }
  manifest_get format || return 65
  [[ "$REPLY" == "4" ]] || { say_error "shvpn: automatic login requires reinstalling shvpn"; return 65; }
  manifest_get platform || return 65
  [[ "$REPLY" == "$platform_id" ]] || { say_error "shvpn: install manifest belongs to another platform"; return 65; }
  manifest_get state-dir || return 65
  [[ "$REPLY" == "$state_dir" ]] || { say_error "shvpn: install manifest state directory does not match"; return 65; }

  for key in login-helper login-requirements; do
    case "$key" in
      login-helper) safe_owned_regular "$login_helper" && stat_mode "$login_helper" && [[ "$REPLY" == "700" ]] || { say_error "shvpn: automatic login helper is missing or unsafe"; return 69; }; sha_file "$login_helper" ;;
      login-requirements) safe_owned_regular "$login_requirements" && stat_mode "$login_requirements" && [[ "$REPLY" == "600" ]] || { say_error "shvpn: login dependency lock is missing or unsafe"; return 69; }; sha_file "$login_requirements" ;;
    esac || return 74
    actual_sha="$REPLY"
    manifest_get "$key" || return 65
    [[ "$actual_sha" == "$REPLY" ]] || { say_error "shvpn: managed $key was modified; refusing"; return 2; }
  done

  manifest_get login-python || return 65
  python_bin="$REPLY"
  manifest_get login-python-version || return 65
  python_version="$REPLY"
  manifest_get login-python-sha256 || return 65
  python_sha="$REPLY"
  safe_login_python "$python_bin" || { say_error "shvpn: recorded Python interpreter is unavailable or unsafe; reinstall shvpn"; return 69; }
  actual_version="$("$python_bin" -I -B -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)" || return 69
  [[ "$actual_version" == "$python_version" ]] || { say_error "shvpn: recorded Python version changed; reinstall shvpn"; return 69; }
  sha_file "${python_bin:A}" || return 74
  [[ "$REPLY" == "$python_sha" ]] || { say_error "shvpn: recorded Python executable changed; reinstall shvpn"; return 69; }
  [[ -d "$login_packages" && ! -L "$login_packages" ]] && stat_uid "$login_packages" && [[ "$REPLY" == "$current_uid" ]] || { say_error "shvpn: managed Python packages are missing or unsafe"; return 69; }
  actual_tree="$("$python_bin" -I -B "$login_helper" --tree-digest "$login_packages" 2>/dev/null)" || { say_error "shvpn: managed Python package tree is unsafe"; return 69; }
  manifest_get login-packages || return 65
  [[ "$actual_tree" == "$REPLY" ]] || { say_error "shvpn: managed Python package tree was modified; refusing"; return 2; }
  "$python_bin" -I -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import playwright.sync_api' "$login_packages" >/dev/null 2>&1 || { say_error "shvpn: managed Playwright runtime cannot be imported"; return 69; }
  REPLY="$python_bin"
  return 0
}

validate_ssh_name() {
  [[ "$1" == [A-Za-z0-9][A-Za-z0-9._-]# ]]
}

load_targets() {
  local line owner mode
  target_hosts=()
  target_set=()

  if ! safe_owned_regular "$targets_file"; then
    say_error "shvpn: target allowlist is missing or unsafe"
    return 2
  fi
  stat_uid "$targets_file" || return 2
  owner="$REPLY"
  stat_mode "$targets_file" || return 2
  mode="$REPLY"
  if [[ "$owner" != "$current_uid" || "$mode" != "600" ]]; then
    say_error "shvpn: target allowlist ownership or mode is unsafe"
    return 2
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" != [A-Za-z0-9][A-Za-z0-9.-]# || -n "${target_set[$line]:-}" ]]; then
      say_error "shvpn: target allowlist is malformed"
      return 2
    fi
    target_set[$line]=1
    target_hosts+=("$line")
  done <"$targets_file"
  if (( ${#target_hosts} == 0 )); then
    say_error "shvpn: target allowlist is empty"
    return 2
  fi
  return 0
}

mark_alias_scan_incomplete() {
  alias_scan_incomplete=1
}

collect_literal_ssh_names() {
  local root_config="$1"
  local config_file physical_file line first_word keyword first_arg word value
  local include_arg include_pattern include_match physical_match
  local queue_index=1
  local depth next_depth
  local -a file_queue depth_queue words directive_args include_matches
  local -A seen_files seen_names

  discovered_ssh_names=()
  alias_scan_incomplete=0
  file_queue=("$root_config")
  depth_queue=(0)

  while (( queue_index <= ${#file_queue} )); do
    config_file="${file_queue[$queue_index]}"
    depth="${depth_queue[$queue_index]}"
    queue_index=$(( queue_index + 1 ))
    physical_file="${config_file:A}"
    [[ -z "${seen_files[$physical_file]:-}" ]] || continue
    seen_files[$physical_file]=1

    if ! safe_owned_regular "$config_file" || [[ "$physical_file" != "$ssh_root"/* ]]; then
      mark_alias_scan_incomplete
      continue
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
      words=("${(z)line}")
      (( ${#words} > 0 )) || continue
      first_word="${(Q)words[1]}"
      [[ "$first_word" != \#* ]] || continue
      directive_args=()
      if [[ "$first_word" == *=* ]]; then
        keyword="${${first_word%%=*}:l}"
        first_arg="${first_word#*=}"
        [[ -n "$first_arg" ]] && directive_args+=("$first_arg")
      else
        keyword="${first_word:l}"
      fi
      for word in "${words[@]:1}"; do
        value="${(Q)word}"
        [[ "$value" != \#* ]] || break
        directive_args+=("$value")
      done

      case "$keyword" in
        host)
          for value in "${directive_args[@]}"; do
            if validate_ssh_name "$value"; then
              if [[ -z "${seen_names[$value]:-}" ]]; then
                if (( ${#discovered_ssh_names} >= 4096 )); then
                  mark_alias_scan_incomplete
                  break
                fi
                seen_names[$value]=1
                discovered_ssh_names+=("$value")
              fi
            fi
          done
          ;;
        include)
          if (( depth >= 8 )); then
            (( ${#directive_args} == 0 )) || mark_alias_scan_incomplete
            continue
          fi
          for include_arg in "${directive_args[@]}"; do
            if [[ -z "$include_arg" || "$include_arg" == *[$'\n\r\t'\|\;\<\>\`\$\(\)\{\}]* ]]; then
              mark_alias_scan_incomplete
              continue
            fi
            case "$include_arg" in
              /*) include_pattern="$include_arg" ;;
              '~/'*) include_pattern="$HOME/${include_arg#\~/}" ;;
              *) include_pattern="$ssh_root/$include_arg" ;;
            esac
            if [[ "$include_pattern" != "$ssh_root"/* || "/$include_pattern/" == */../* ]]; then
              mark_alias_scan_incomplete
              continue
            fi
            include_matches=( ${~include_pattern}(N) )
            for include_match in "${include_matches[@]}"; do
              physical_match="${include_match:A}"
              if ! safe_owned_regular "$include_match" || [[ "$physical_match" != "$ssh_root"/* ]]; then
                mark_alias_scan_incomplete
                continue
              fi
              [[ -z "${seen_files[$physical_match]:-}" ]] || continue
              if (( ${#file_queue} >= 64 )); then
                mark_alias_scan_incomplete
                continue
              fi
              next_depth=$(( depth + 1 ))
              file_queue+=("$include_match")
              depth_queue+=("$next_depth")
            done
          done
          ;;
      esac
    done <"$config_file"
  done
}

resolve_ssh_name() {
  local ssh_name="$1"
  local output
  resolved_host=""
  resolved_proxy=""
  output="$($ssh_client -F "$ssh_config" -G -- "$ssh_name" 2>/dev/null)" || return 1
  resolved_host="$(print -r -- "$output" | /usr/bin/awk '$1 == "hostname" {print $2; exit}')"
  resolved_proxy="$(print -r -- "$output" | /usr/bin/awk '$1 == "proxycommand" {$1=""; sub(/^ /, ""); print; exit}')"
  [[ -n "$resolved_host" ]]
}

prepare_ssh_diagnostics() {
  local spec label file_path mode permission

  for spec in "VPN client:$client" "VPN launcher:$launcher" "shvpn command:$self" "SSH route helper:$route"; do
    label="${spec%%:*}"
    file_path="${spec#*:}"
    if ! safe_owned_executable "$file_path"; then
      say_error "shvpn: managed $label is missing or unsafe"
      return 2
    fi
  done
  if ! safe_owned_regular "$ssh_config"; then
    say_error "shvpn: SSH config is missing or unsafe"
    return 2
  fi
  stat_mode "$ssh_config" || return 2
  mode="$REPLY"
  [[ "$mode" == <-> ]] || return 2
  permission=$(( 8#$mode ))
  if (( (permission & 8#022) != 0 )); then
    say_error "shvpn: SSH config is writable by group or others"
    return 2
  fi
  [[ -x "$ssh_client" && -f "$ssh_client" ]] || {
    say_error "shvpn: system OpenSSH client is unavailable: $ssh_client"
    return 2
  }
  load_targets || return $?
  return 0
}

collect_candidate_ssh_names() {
  local name
  local -A seen_names
  candidate_ssh_names=()
  explicit_name_set=()

  for name in "$@"; do
    if ! validate_ssh_name "$name"; then
      say_error "shvpn: invalid SSH name: $name"
      return 64
    fi
    explicit_name_set[$name]=1
  done

  collect_literal_ssh_names "$ssh_config"
  for name in "${target_hosts[@]}" "${discovered_ssh_names[@]}" "$@"; do
    [[ -n "$name" && -z "${seen_names[$name]:-}" ]] || continue
    seen_names[$name]=1
    candidate_ssh_names+=("$name")
  done
  return 0
}

check_vscode_and_codex() {
  local settings_file skill_file
  local -a vscode_extensions settings_files skill_files

  vscode_extensions=(
    "$HOME"/.vscode/extensions/ms-vscode-remote.remote-ssh-[0-9]*(N)
    "$HOME"/.vscode-insiders/extensions/ms-vscode-remote.remote-ssh-[0-9]*(N)
  )
  if (( ${#vscode_extensions} > 0 )); then
    print -r -- "doctor: VS Code Remote-SSH extension detected."
  else
    print -r -- "doctor: VS Code Remote-SSH extension not detected (optional)."
  fi

  if [[ "$platform_id" == darwin-* ]]; then
    settings_files=(
      "$HOME/Library/Application Support/Code/User/settings.json"
      "$HOME/Library/Application Support/Code - Insiders/User/settings.json"
    )
  else
    settings_files=(
      "$HOME/.config/Code/User/settings.json"
      "$HOME/.config/Code - Insiders/User/settings.json"
    )
  fi
  for settings_file in "${settings_files[@]}"; do
    [[ -e "$settings_file" || -L "$settings_file" ]] || continue
    if ! safe_owned_regular "$settings_file"; then
      say_error "doctor: warning: VS Code settings file is unsafe; integration was not inspected"
      doctor_warnings=$(( doctor_warnings + 1 ))
      continue
    fi
    if /usr/bin/grep -Eq '"remote\.SSH\.(configFile|path)"[[:space:]]*:' "$settings_file"; then
      say_error "doctor: warning: VS Code selects a custom SSH path or config; verify that it uses this OpenSSH configuration"
      doctor_warnings=$(( doctor_warnings + 1 ))
    fi
  done

  skill_files=(
    "$HOME/.agents/skills/ssh-remote/SKILL.md"
    "$HOME/.codex/skills/ssh-remote/SKILL.md"
  )
  for skill_file in "${skill_files[@]}"; do
    if safe_owned_regular "$skill_file"; then
      print -r -- "doctor: Codex SSH skill detected; verified system OpenSSH routing applies."
      return 0
    fi
  done
  print -r -- "doctor: Codex SSH skill not detected; verified system OpenSSH routing is ready for tools that call ssh."
  return 0
}

doctor_shvpn() {
  local name rc
  local doctor_failures=0
  typeset -g doctor_warnings=0

  prepare_ssh_diagnostics || return $?
  if verify_login_runtime; then
    print -r -- "doctor: automatic CAS login runtime OK."
  else
    doctor_failures=$(( doctor_failures + 1 ))
  fi
  if safe_chrome_executable "$chrome_bin"; then
    print -r -- "doctor: Google Chrome detected."
  else
    say_error "doctor: warning: Google Chrome is not installed; 'shvpn login' needs Chrome"
    doctor_warnings=$(( doctor_warnings + 1 ))
  fi
  collect_candidate_ssh_names "$@" || return $?

  show_status
  rc=$?
  case "$rc" in
    0|1) ;;
    *) doctor_failures=$(( doctor_failures + 1 )) ;;
  esac

  if (( alias_scan_incomplete )); then
    say_error "doctor: warning: SSH alias discovery was incomplete because of Include, safety, or scan limits; pass names explicitly"
    doctor_warnings=$(( doctor_warnings + 1 ))
  fi

  for name in "${candidate_ssh_names[@]}"; do
    if ! resolve_ssh_name "$name"; then
      if [[ -n "${target_set[$name]:-}" ]]; then
        say_error "doctor: target $name was rejected by ssh -G"
        doctor_failures=$(( doctor_failures + 1 ))
      elif [[ -n "${explicit_name_set[$name]:-}" ]]; then
        say_error "doctor: warning: SSH name $name was rejected by ssh -G"
        doctor_warnings=$(( doctor_warnings + 1 ))
      fi
      continue
    fi

    if [[ -n "${target_set[$name]:-}" && "$resolved_host" != "$name" ]]; then
      say_error "doctor: target $name resolves to a different HostName"
      doctor_failures=$(( doctor_failures + 1 ))
      continue
    fi
    if [[ -n "${target_set[$resolved_host]:-}" ]]; then
      if [[ "$resolved_proxy" != "$expected_route_proxy" ]]; then
        say_error "doctor: SSH name $name has an earlier ProxyCommand or ProxyJump"
        doctor_failures=$(( doctor_failures + 1 ))
      elif [[ "$name" == "$resolved_host" ]]; then
        print -r -- "doctor: target $name: managed route OK."
      else
        print -r -- "doctor: alias $name -> $resolved_host: managed route OK."
      fi
    elif [[ -n "${explicit_name_set[$name]:-}" ]]; then
      say_error "doctor: warning: $name is not managed; its HostName must exactly equal an installed target"
      doctor_warnings=$(( doctor_warnings + 1 ))
    fi
  done

  check_vscode_and_codex
  if (( doctor_failures > 0 )); then
    say_error "doctor: core checks failed ($doctor_failures failure(s), $doctor_warnings warning(s))."
    return 2
  fi
  if (( doctor_warnings > 0 )); then
    say_error "doctor: core route is healthy with $doctor_warnings warning(s)."
    return 1
  fi
  print -r -- "doctor: all checks passed."
  return 0
}

reconnect_ssh() {
  local name rc
  local reconnect_failures=0
  local reconnect_warnings=0
  local closed=0
  local -a eligible_names

  prepare_ssh_diagnostics || return $?
  collect_candidate_ssh_names "$@" || return $?
  if (( alias_scan_incomplete )); then
    say_error "reconnect: warning: SSH alias discovery was incomplete because of Include, safety, or scan limits; pass names explicitly"
    reconnect_warnings=$(( reconnect_warnings + 1 ))
  fi

  eligible_names=()
  for name in "${candidate_ssh_names[@]}"; do
    if ! resolve_ssh_name "$name"; then
      if [[ -n "${target_set[$name]:-}" ]]; then
        say_error "reconnect: target $name was rejected by ssh -G"
        return 2
      elif [[ -n "${explicit_name_set[$name]:-}" ]]; then
        say_error "reconnect: SSH name $name was rejected by ssh -G"
        return 64
      fi
      continue
    fi
    if [[ -n "${target_set[$resolved_host]:-}" ]]; then
      if [[ "$resolved_proxy" != "$expected_route_proxy" ]]; then
        say_error "reconnect: SSH name $name is not using the managed route; refusing"
        return 2
      fi
      eligible_names+=("$name")
    elif [[ -n "${explicit_name_set[$name]:-}" ]]; then
      say_error "reconnect: $name is not managed; its HostName must exactly equal an installed target"
      return 64
    fi
  done

  print -r -- "reconnect: checking configured masters for ShanghaiTech targets; active matching sessions may close."
  for name in "${eligible_names[@]}"; do
    if "$ssh_client" -F "$ssh_config" -O check -- "$name" >/dev/null 2>&1; then
      if "$ssh_client" -F "$ssh_config" -O exit -- "$name" >/dev/null 2>&1; then
        print -r -- "reconnect: closed configured master for $name."
        closed=$(( closed + 1 ))
      else
        say_error "reconnect: failed to close the checked master for $name"
        reconnect_failures=$(( reconnect_failures + 1 ))
      fi
    fi
  done

  if (( reconnect_failures > 0 )); then
    return 2
  fi
  if (( closed == 0 )); then
    print -r -- "reconnect: no active configured master was found."
  fi
  if (( reconnect_warnings > 0 )); then
    return 1
  fi
  return 0
}

get_listener_pid() {
  REPLY=""
  local output line
  local rc
  local -a pids
  pids=()

  output="$("$lsof_bin" -nP -a -iTCP@${bind_host}:${bind_port} -sTCP:LISTEN -Fpu 2>/dev/null)"
  rc=$?
  if (( rc != 0 )); then
    if "$nc_bin" -z "$bind_host" "$bind_port" >/dev/null 2>&1; then
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

  output="$("$lsof_bin" -nP -a -p "$pid" -d txt -Fn 2>/dev/null)" || return 1
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

  uid="$("$ps_bin" -p "$pid" -o uid= 2>/dev/null)" || return 1
  uid="${uid//[[:space:]]/}"
  [[ "$uid" == <-> ]] || return 1
  REPLY="$uid"
  return 0
}

get_process_command() {
  REPLY=""
  local pid="$1"
  local command_line

  command_line="$("$ps_bin" -ww -p "$pid" -o command= 2>/dev/null)" || return 1
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
  [[ "$executable" == "$zsh_bin" ]] || return 1
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

acquire_config_lock() {
  if [[ -e "$config_lock_file" && ( ! -f "$config_lock_file" || -L "$config_lock_file" ) ]]; then
    say_error "shvpn: unsafe configuration lock: $config_lock_file"
    return 69
  fi
  /usr/bin/touch "$config_lock_file" || return 69
  /bin/chmod 600 "$config_lock_file" || return 69
  if ! zmodload zsh/system; then
    say_error "shvpn: zsh/system locking support is unavailable"
    return 69
  fi
  if ! zsystem flock -t 0 -f config_lock_fd -e "$config_lock_file"; then
    say_error "shvpn: another shvpn configuration or lifecycle operation is in progress"
    return 75
  fi
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

  children_text="$("$pgrep_bin" -P "$wrapper_pid" 2>/dev/null)"
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
  "$nohup_bin" "$launcher" </dev/null >>"$log_file" 2>&1 &
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
  local pid rc python_bin

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

  if [[ "$platform_id" == linux-* && -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    say_error "shvpn: Linux CAS login needs a graphical desktop session (DISPLAY or WAYLAND_DISPLAY is unset)"
    return 69
  fi

  verify_login_runtime || return $?
  python_bin="$REPLY"
  print -r -- "shvpn: opening the dedicated ShanghaiTech CAS login window..."
  "$python_bin" -I -B "$login_helper" \
    --package-dir "$login_packages" \
    --launcher "$launcher" \
    --chrome-executable "$chrome_bin" \
    --state-dir "$state_dir" || return $?
  start_vpn
  return $?
}

if (( $# == 0 )); then
  action="start"
else
  action="$1"
  shift
fi
case "$action" in
  status)
    (( $# == 0 )) || { usage; exit 64; }
    show_status
    exit $?
    ;;
  doctor)
    doctor_shvpn "$@"
    exit $?
    ;;
  reconnect)
    reconnect_ssh "$@"
    exit $?
    ;;
  add|remove)
    (( $# == 1 )) || { usage; exit 64; }
    verify_installed_helper config-helper "$config_helper" || exit $?
    "$config_helper" "$action" "$1"
    exit $?
    ;;
  uninstall)
    (( $# == 0 )) || { usage; exit 64; }
    verify_installed_helper uninstall-helper "$uninstall_helper" || exit $?
    "$uninstall_helper"
    exit $?
    ;;
  start|stop|login)
    (( $# == 0 )) || { usage; exit 64; }
    prepare_runtime || exit $?
    acquire_config_lock || exit $?
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
