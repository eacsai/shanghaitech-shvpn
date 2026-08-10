#!/bin/zsh

set -eu
setopt extendedglob
umask 077

typeset -gr project_root="${0:A:h}"
typeset -gr begin_ssh="# >>> shanghaitech-shvpn managed SSH targets >>>"
typeset -gr end_ssh="# <<< shanghaitech-shvpn managed SSH targets <<<"
typeset -gr begin_path="# >>> shanghaitech-shvpn managed PATH >>>"
typeset -gr end_path="# <<< shanghaitech-shvpn managed PATH <<<"
typeset -gr current_uid="$(/usr/bin/id -u)"

say_error() {
  print -u2 -r -- "$*"
}

die() {
  say_error "install: $2"
  exit "$1"
}

usage() {
  print -u2 -r -- "usage: ./install.zsh"
  print -u2 -r -- "   or: ./install.zsh --non-interactive --target ALIAS HOST PORT USER_OR_DASH [--target ...] (--add-path|--no-path)"
}

sha_file() {
  REPLY="$(/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}')" || return 1
}

safe_regular_or_absent() {
  local file_path="$1"
  if [[ -e "$file_path" || -L "$file_path" ]]; then
    [[ -f "$file_path" && ! -L "$file_path" ]] || return 1
    [[ "$(/usr/bin/stat -f %u "$file_path" 2>/dev/null)" == "$current_uid" ]] || return 1
  fi
  return 0
}

ensure_private_dir() {
  local dir_path="$1"
  if [[ -e "$dir_path" || -L "$dir_path" ]]; then
    [[ -d "$dir_path" && ! -L "$dir_path" ]] || die 69 "unsafe directory: $dir_path"
    [[ "$(/usr/bin/stat -f %u "$dir_path" 2>/dev/null)" == "$current_uid" ]] || die 69 "directory is not owned by the current user: $dir_path"
  else
    /usr/bin/install -d -m 700 "$dir_path" || die 74 "cannot create directory: $dir_path"
  fi
  /bin/chmod 700 "$dir_path" || die 74 "cannot harden directory: $dir_path"
}

ensure_owned_dir() {
  local dir_path="$1"
  if [[ -e "$dir_path" || -L "$dir_path" ]]; then
    [[ -d "$dir_path" && ! -L "$dir_path" ]] || die 69 "unsafe directory: $dir_path"
    [[ "$(/usr/bin/stat -f %u "$dir_path" 2>/dev/null)" == "$current_uid" ]] || die 69 "directory is not owned by the current user: $dir_path"
  else
    /usr/bin/install -d -m 700 "$dir_path" || die 74 "cannot create directory: $dir_path"
  fi
}

marker_count() {
  local file="$1"
  local marker="$2"
  if [[ ! -f "$file" ]]; then
    REPLY=0
    return 0
  fi
  REPLY="$(/usr/bin/grep -Fxc -- "$marker" "$file" 2>/dev/null || true)"
  [[ "$REPLY" == <-> ]]
}

extract_marked_block() {
  local input="$1"
  local output="$2"
  local begin="$3"
  local end="$4"
  /usr/bin/awk -v begin="$begin" -v end="$end" '
    $0 == begin { if (inside) exit 65; inside=1 }
    inside { print }
    $0 == end { if (!inside) exit 65; inside=0; seen++ }
    END { if (inside || seen != 1) exit 65 }
  ' "$input" >"$output"
}

strip_marked_block() {
  local input="$1"
  local output="$2"
  local begin="$3"
  local end="$4"
  if [[ ! -f "$input" ]]; then
    : >"$output"
    return 0
  fi
  /usr/bin/awk -v begin="$begin" -v end="$end" '
    $0 == begin { if (inside) exit 65; inside=1; seen_begin++; next }
    $0 == end { if (!inside) exit 65; inside=0; seen_end++; next }
    !inside { print }
    END { if (inside || seen_begin > 1 || seen_end > 1 || seen_begin != seen_end) exit 65 }
  ' "$input" >"$output"
}

append_block() {
  local base="$1"
  local block="$2"
  local output="$3"
  /bin/cp "$base" "$output"
  if [[ -s "$output" ]]; then
    print >>"$output"
  fi
  /bin/cat "$block" >>"$output"
}

manifest_get() {
  local key="$1"
  local manifest="$2"
  REPLY="$(/usr/bin/awk -F '\t' -v key="$key" '
    $1 == key { count++; value=$2 }
    END { if (count != 1 || value == "") exit 65; print value }
  ' "$manifest")" || return 1
}

snapshot_path() {
  local snapshot_dir="$1"
  local key="$2"
  local file_path="$3"
  safe_regular_or_absent "$file_path" || die 69 "refusing unsafe managed path: $file_path"
  if [[ -f "$file_path" ]]; then
    sha_file "$file_path" || die 74 "cannot hash: $file_path"
    local digest="$REPLY"
    local mode="$(/usr/bin/stat -f %Lp "$file_path")"
    print -r -- "present${TAB}${digest}${TAB}${mode}" >"$snapshot_dir/$key.state"
    /bin/cp -p "$file_path" "$snapshot_dir/$key.file" || die 74 "cannot back up: $file_path"
  else
    print -r -- "absent" >"$snapshot_dir/$key.state"
  fi
}

atomic_install() {
  local source="$1"
  local destination="$2"
  local mode="$3"
  local destination_dir="${destination:h}"
  local local_tmp
  local_tmp="$(/usr/bin/mktemp "$destination_dir/.shvpn-install.XXXXXX")" || return 1
  if ! /usr/bin/install -m "$mode" "$source" "$local_tmp"; then
    /bin/rm -f -- "$local_tmp"
    return 1
  fi
  if ! /bin/mv -f "$local_tmp" "$destination"; then
    /bin/rm -f -- "$local_tmp"
    return 1
  fi
}

restore_snapshot() {
  local snapshot_dir="$1"
  local key="$2"
  local destination="$3"
  local state_line state digest mode
  [[ -f "$snapshot_dir/$key.state" && ! -L "$snapshot_dir/$key.state" ]] || return 1
  state_line="$(<"$snapshot_dir/$key.state")"
  IFS=$'\t' read -r state digest mode <<<"$state_line"
  case "$state" in
    present)
      [[ -f "$snapshot_dir/$key.file" && ! -L "$snapshot_dir/$key.file" && "$digest" == [0-9a-f](#c64) && "$mode" == <-> ]] || return 1
      sha_file "$snapshot_dir/$key.file" || return 1
      [[ "$REPLY" == "$digest" ]] || return 1
      atomic_install "$snapshot_dir/$key.file" "$destination" "$mode"
      ;;
    absent)
      if [[ -e "$destination" || -L "$destination" ]]; then
        safe_regular_or_absent "$destination" || return 1
        /bin/rm -f -- "$destination"
      fi
      ;;
    *) return 1 ;;
  esac
}

validate_target() {
  local alias="$1"
  local host="$2"
  local port="$3"
  local user="$4"
  [[ "$alias" == [A-Za-z0-9][A-Za-z0-9._-]# ]] || die 64 "invalid SSH alias: $alias"
  [[ "$host" == [A-Za-z0-9][A-Za-z0-9.-]# ]] || die 64 "invalid SSH host: $host"
  [[ "$port" == <-> && "$port" -ge 1 && "$port" -le 65535 ]] || die 64 "invalid SSH port: $port"
  [[ "$user" == "-" || "$user" == [A-Za-z_][A-Za-z0-9_.-]# ]] || die 64 "invalid SSH user: $user"
}

typeset -a target_aliases target_hosts target_ports target_users
target_aliases=()
target_hosts=()
target_ports=()
target_users=()
non_interactive=0
path_choice=""

while (( $# > 0 )); do
  case "$1" in
    --non-interactive)
      non_interactive=1
      shift
      ;;
    --target)
      (( $# >= 5 )) || { usage; exit 64; }
      target_aliases+=("$2")
      target_hosts+=("$3")
      target_ports+=("$4")
      target_users+=("$5")
      shift 5
      ;;
    --add-path)
      [[ -z "$path_choice" ]] || die 64 "choose only one PATH policy"
      path_choice="add"
      shift
      ;;
    --no-path)
      [[ -z "$path_choice" ]] || die 64 "choose only one PATH policy"
      path_choice="none"
      shift
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

if (( non_interactive )); then
  [[ -n "$path_choice" ]] || die 64 "non-interactive mode requires --add-path or --no-path"
else
  (( ${#target_aliases} == 0 )) || die 64 "--target requires --non-interactive"
  [[ -n "$path_choice" ]] || path_choice="add"
  print -r -- "配置需要通过 VPN 访问的 SSH 目标；alias 留空即可结束。"
  while true; do
    read "target_alias?SSH alias（例如 gpu）："
    [[ -n "$target_alias" ]] || break
    read "target_host?服务器地址："
    read "target_port?SSH 端口（通常为 22）："
    read "target_user?SSH 用户名（留空则不写 User）："
    [[ -n "$target_user" ]] || target_user="-"
    target_aliases+=("$target_alias")
    target_hosts+=("$target_host")
    target_ports+=("$target_port")
    target_users+=("$target_user")
  done
fi

typeset -A seen_aliases
for (( i = 1; i <= ${#target_aliases}; i++ )); do
  validate_target "${target_aliases[i]}" "${target_hosts[i]}" "${target_ports[i]}" "${target_users[i]}"
  [[ -z "${seen_aliases[${target_aliases[i]}]:-}" ]] || die 64 "duplicate SSH alias: ${target_aliases[i]}"
  seen_aliases[${target_aliases[i]}]=1
done

[[ "$(/usr/bin/uname -s)" == "Darwin" && "$(/usr/bin/uname -m)" == "arm64" ]] || die 69 "version 1 supports Apple Silicon macOS only"
for command_name in zsh git go codesign ssh nc shasum lsof lockf; do
  command -v "$command_name" >/dev/null 2>&1 || die 69 "required command not found: $command_name"
done

home_dir="${HOME:A}"
[[ -d "$home_dir" && ! -L "$home_dir" && "$home_dir" == /* ]] || die 69 "HOME is not a safe physical directory"
[[ "$home_dir" != *$'\n'* && "$home_dir" != *$'\r'* && "$home_dir" != *$'\t'* && "$home_dir" != *'|'* ]] || die 69 "HOME contains unsupported characters"
[[ "$(/usr/bin/stat -f %u "$home_dir")" == "$current_uid" ]] || die 69 "HOME is not owned by the current user"

bin_dir="$home_dir/.local/bin"
lib_dir="$home_dir/.local/lib/shanghaitech-shvpn"
baseline_dir="$lib_dir/baseline"
backup_root="$lib_dir/backups"
manifest="$lib_dir/install.manifest.tsv"
config_dir="$home_dir/.config/shanghaitech-shvpn"
targets_file="$config_dir/targets.tsv"
ssh_dir="$home_dir/.ssh"
ssh_config="$ssh_dir/config"
zshrc="$home_dir/.zshrc"
client="$bin_dir/zju-connect"
launcher="$bin_dir/shanghaitech-vpn"
shvpn="$bin_dir/shvpn"
route="$bin_dir/shanghaitech-ssh-route"
state_dir="$home_dir/Library/Application Support/ShanghaitechVPN"
TAB=$'\t'

for managed_path in "$client" "$launcher" "$shvpn" "$route" "$targets_file" "$ssh_config" "$zshrc" "$manifest"; do
  safe_regular_or_absent "$managed_path" || die 69 "refusing unsafe path: $managed_path"
done

existing_install=0
if [[ -f "$manifest" ]]; then
  existing_install=1
  [[ "$(/usr/bin/stat -f %Lp "$manifest")" == "600" ]] || die 69 "install manifest has unsafe mode"
  manifest_get format "$manifest" || die 65 "invalid install manifest"
  [[ "$REPLY" == "1" ]] || die 65 "unsupported install manifest"
  manifest_get path-choice "$manifest" || die 65 "invalid install manifest"
  [[ "$REPLY" == "$path_choice" ]] || die 65 "PATH policy changed; run uninstall.zsh before reinstalling"
  for spec in \
    "zju-connect:$client" \
    "shanghaitech-vpn:$launcher" \
    "shvpn:$shvpn" \
    "shanghaitech-ssh-route:$route" \
    "targets:$targets_file"; do
    key="${spec%%:*}"
    managed_path="${spec#*:}"
    [[ -f "$managed_path" ]] || die 65 "managed file is missing: $managed_path"
    manifest_get "$key" "$manifest" || die 65 "invalid install manifest entry: $key"
    expected_sha="$REPLY"
    sha_file "$managed_path" || die 74 "cannot hash managed file: $managed_path"
    [[ "$REPLY" == "$expected_sha" ]] || die 65 "managed file was modified; refusing overwrite: $managed_path"
  done
elif [[ -e "$lib_dir" || -L "$lib_dir" ]]; then
  [[ -d "$lib_dir" && ! -L "$lib_dir" ]] || die 69 "unsafe library directory: $lib_dir"
  die 65 "existing unrecognized installation metadata: $lib_dir"
fi

temp_parent="${TMPDIR:-/tmp}"
[[ -d "$temp_parent" && "$temp_parent" == /* ]] || die 69 "TMPDIR must name an existing absolute directory"
work_dir="$(/usr/bin/mktemp -d "$temp_parent/shvpn-install.XXXXXX")"
install_complete=0
writes_started=0
fresh_namespace=$(( ! existing_install ))
cleanup_work() {
  if [[ -n "${work_dir:-}" && -d "$work_dir" && "$work_dir" == "$temp_parent"/shvpn-install.* ]]; then
    /bin/rm -rf -- "$work_dir"
  fi
}
rollback_install() {
  (( writes_started )) || return 0
  local rollback_failed=0
  restore_snapshot "$history_dir" zju-connect "$client" || rollback_failed=1
  restore_snapshot "$history_dir" shanghaitech-vpn "$launcher" || rollback_failed=1
  restore_snapshot "$history_dir" shvpn "$shvpn" || rollback_failed=1
  restore_snapshot "$history_dir" shanghaitech-ssh-route "$route" || rollback_failed=1
  restore_snapshot "$history_dir" targets "$targets_file" || rollback_failed=1
  restore_snapshot "$history_dir" ssh-config "$ssh_config" || rollback_failed=1
  restore_snapshot "$history_dir" zshrc "$zshrc" || rollback_failed=1
  restore_snapshot "$history_dir" manifest "$manifest" || rollback_failed=1
  (( rollback_failed == 0 )) || say_error "install: automatic rollback was incomplete; inspect $history_dir"
  return "$rollback_failed"
}
on_exit() {
  local rc="$1"
  if (( rc != 0 && ! install_complete )); then
    local rollback_ok=1
    rollback_install || rollback_ok=0
    if (( fresh_namespace && rollback_ok )) && [[ "$lib_dir" == "$home_dir/.local/lib/shanghaitech-shvpn" && -d "$lib_dir" && ! -L "$lib_dir" ]]; then
      /bin/rm -rf -- "$lib_dir"
    fi
  fi
  cleanup_work
  return "$rc"
}
trap 'on_exit $?' EXIT
trap 'exit 130' INT TERM

"$project_root/libexec/build-client.zsh" "$work_dir/zju-connect"

quote_for_zsh() {
  REPLY="${(qqq)1}"
}
quote_for_zsh "$client"; client_q="$REPLY"
quote_for_zsh "$launcher"; launcher_q="$REPLY"
quote_for_zsh "$shvpn"; shvpn_q="$REPLY"
quote_for_zsh "$state_dir"; state_dir_q="$REPLY"
quote_for_zsh "$targets_file"; targets_q="$REPLY"
quote_for_zsh "$route"; route_command_q="$REPLY"

content="$(<"$project_root/libexec/shanghaitech-vpn.zsh")"
content="${content//@@CLIENT_Q@@/$client_q}"
content="${content//@@STATE_DIR_Q@@/$state_dir_q}"
[[ "$content" != *'@@'* ]] || die 65 "unresolved launcher template token"
print -rn -- "$content" >"$work_dir/shanghaitech-vpn"

content="$(<"$project_root/libexec/shvpn.zsh")"
content="${content//@@CLIENT_Q@@/$client_q}"
content="${content//@@LAUNCHER_Q@@/$launcher_q}"
content="${content//@@SHVPN_Q@@/$shvpn_q}"
content="${content//@@STATE_DIR_Q@@/$state_dir_q}"
[[ "$content" != *'@@'* ]] || die 65 "unresolved shvpn template token"
print -rn -- "$content" >"$work_dir/shvpn"

content="$(<"$project_root/libexec/shanghaitech-ssh-route.zsh")"
content="${content//@@SHVPN_Q@@/$shvpn_q}"
content="${content//@@TARGETS_Q@@/$targets_q}"
[[ "$content" != *'@@'* ]] || die 65 "unresolved route template token"
print -rn -- "$content" >"$work_dir/shanghaitech-ssh-route"

/bin/chmod 700 "$work_dir/shanghaitech-vpn" "$work_dir/shvpn" "$work_dir/shanghaitech-ssh-route"
/bin/zsh -n "$work_dir/shanghaitech-vpn" "$work_dir/shvpn" "$work_dir/shanghaitech-ssh-route" || die 65 "rendered helper syntax check failed"

: >"$work_dir/targets.tsv"
: >"$work_dir/ssh.block"
print -r -- "$begin_ssh" >>"$work_dir/ssh.block"
for (( i = 1; i <= ${#target_aliases}; i++ )); do
  print -r -- "${target_aliases[i]}${TAB}${target_hosts[i]}${TAB}${target_ports[i]}${TAB}${target_users[i]}" >>"$work_dir/targets.tsv"
  print -r -- "Host ${target_aliases[i]}" >>"$work_dir/ssh.block"
  print -r -- "    HostName ${target_hosts[i]}" >>"$work_dir/ssh.block"
  print -r -- "    Port ${target_ports[i]}" >>"$work_dir/ssh.block"
  if [[ "${target_users[i]}" != "-" ]]; then
    print -r -- "    User ${target_users[i]}" >>"$work_dir/ssh.block"
  fi
  print -r -- "    ProxyCommand $route_command_q %h %p" >>"$work_dir/ssh.block"
done
print -r -- "$end_ssh" >>"$work_dir/ssh.block"

marker_count "$ssh_config" "$begin_ssh" || die 65 "cannot inspect SSH markers"
ssh_begin_count="$REPLY"
marker_count "$ssh_config" "$end_ssh" || die 65 "cannot inspect SSH markers"
ssh_end_count="$REPLY"
[[ "$ssh_begin_count" == "$ssh_end_count" && ( "$ssh_begin_count" == 0 || "$ssh_begin_count" == 1 ) ]] || die 65 "ambiguous SSH marker state"
if (( ssh_begin_count == 1 )); then
  (( existing_install )) || die 65 "SSH marker exists without a trusted install manifest"
  extract_marked_block "$ssh_config" "$work_dir/old-ssh.block" "$begin_ssh" "$end_ssh" || die 65 "malformed SSH marker block"
  sha_file "$work_dir/old-ssh.block" || die 74 "cannot hash SSH block"
  current_block_sha="$REPLY"
  manifest_get ssh-block "$manifest" || die 65 "missing SSH block manifest entry"
  [[ "$current_block_sha" == "$REPLY" ]] || die 65 "managed SSH block was modified; refusing overwrite"
fi
strip_marked_block "$ssh_config" "$work_dir/ssh.base" "$begin_ssh" "$end_ssh" || die 65 "cannot prepare SSH config"
append_block "$work_dir/ssh.base" "$work_dir/ssh.block" "$work_dir/ssh.config"

discovered_ssh="$(command -v ssh)"
typeset -a ssh_candidates
typeset -A seen_ssh_clients
ssh_candidates=(/usr/bin/ssh /opt/homebrew/bin/ssh "$discovered_ssh")
for (( i = 1; i <= ${#target_aliases}; i++ )); do
  validated_ssh_clients=0
  seen_ssh_clients=()
  for ssh_client in "${ssh_candidates[@]}"; do
    [[ -x "$ssh_client" ]] || continue
    ssh_client="${ssh_client:A}"
    [[ -f "$ssh_client" && -x "$ssh_client" ]] || continue
    [[ -z "${seen_ssh_clients[$ssh_client]:-}" ]] || continue
    seen_ssh_clients[$ssh_client]=1
    ssh_output="$($ssh_client -F "$work_dir/ssh.config" -G "${target_aliases[i]}" 2>/dev/null)" || die 65 "ssh -G rejected target ${target_aliases[i]}"
    resolved_host="$(print -r -- "$ssh_output" | /usr/bin/awk '$1 == "hostname" {print $2; exit}')"
    resolved_port="$(print -r -- "$ssh_output" | /usr/bin/awk '$1 == "port" {print $2; exit}')"
    resolved_proxy="$(print -r -- "$ssh_output" | /usr/bin/awk '$1 == "proxycommand" {$1=""; sub(/^ /, ""); print; exit}')"
    [[ "$resolved_host" == "${target_hosts[i]}" && "$resolved_port" == "${target_ports[i]}" && "$resolved_proxy" == "$route_command_q %h %p" ]] || die 65 "SSH target ${target_aliases[i]} resolves outside the managed configuration"
    if [[ "${target_users[i]}" != "-" ]]; then
      resolved_user="$(print -r -- "$ssh_output" | /usr/bin/awk '$1 == "user" {print $2; exit}')"
      [[ "$resolved_user" == "${target_users[i]}" ]] || die 65 "SSH user mismatch for ${target_aliases[i]}"
    fi
    validated_ssh_clients=$(( validated_ssh_clients + 1 ))
  done
  (( validated_ssh_clients > 0 )) || die 69 "no usable OpenSSH client validated target ${target_aliases[i]}"
done

marker_count "$zshrc" "$begin_path" || die 65 "cannot inspect PATH markers"
path_begin_count="$REPLY"
marker_count "$zshrc" "$end_path" || die 65 "cannot inspect PATH markers"
path_end_count="$REPLY"
[[ "$path_begin_count" == "$path_end_count" && ( "$path_begin_count" == 0 || "$path_begin_count" == 1 ) ]] || die 65 "ambiguous PATH marker state"
if (( path_begin_count == 1 )); then
  (( existing_install )) || die 65 "PATH marker exists without a trusted install manifest"
  extract_marked_block "$zshrc" "$work_dir/old-path.block" "$begin_path" "$end_path" || die 65 "malformed PATH block"
  sha_file "$work_dir/old-path.block" || die 74 "cannot hash PATH block"
  current_path_block_sha="$REPLY"
  manifest_get path-block "$manifest" || die 65 "missing PATH block manifest entry"
  [[ "$current_path_block_sha" == "$REPLY" ]] || die 65 "managed PATH block was modified; refusing overwrite"
fi

if [[ "$path_choice" == "add" ]]; then
  strip_marked_block "$zshrc" "$work_dir/zshrc.base" "$begin_path" "$end_path" || die 65 "cannot prepare .zshrc"
  quote_for_zsh "$bin_dir"; bin_dir_q="$REPLY"
  {
    print -r -- "$begin_path"
    print -r -- "export PATH=${bin_dir_q}:\"\$PATH\""
    print -r -- "$end_path"
  } >"$work_dir/path.block"
  append_block "$work_dir/zshrc.base" "$work_dir/path.block" "$work_dir/zshrc"
else
  (( path_begin_count == 0 )) || die 65 "managed PATH block exists; uninstall before changing to --no-path"
fi

ensure_owned_dir "$bin_dir"
ensure_owned_dir "$home_dir/.local/lib"
ensure_private_dir "$lib_dir"
ensure_private_dir "$backup_root"
ensure_private_dir "$config_dir"
ensure_owned_dir "$ssh_dir"
ensure_private_dir "$state_dir"

if (( ! existing_install )); then
  baseline_stage="$work_dir/baseline"
  /usr/bin/install -d -m 700 "$baseline_stage"
  snapshot_path "$baseline_stage" zju-connect "$client"
  snapshot_path "$baseline_stage" shanghaitech-vpn "$launcher"
  snapshot_path "$baseline_stage" shvpn "$shvpn"
  snapshot_path "$baseline_stage" shanghaitech-ssh-route "$route"
  snapshot_path "$baseline_stage" targets "$targets_file"
  snapshot_path "$baseline_stage" ssh-config "$ssh_config"
  snapshot_path "$baseline_stage" zshrc "$zshrc"
  print -r -- "complete" >"$baseline_stage/COMPLETE"
  [[ ! -e "$baseline_dir" && ! -L "$baseline_dir" ]] || die 65 "unexpected baseline metadata"
  /bin/mv "$baseline_stage" "$baseline_dir" || die 74 "cannot install baseline metadata"
else
  [[ -f "$baseline_dir/COMPLETE" && ! -L "$baseline_dir" ]] || die 65 "baseline metadata is incomplete"
fi

backup_id="$(/bin/date -u +%Y%m%dT%H%M%SZ)-$$"
history_dir="$backup_root/$backup_id"
/usr/bin/install -d -m 700 "$history_dir"
snapshot_path "$history_dir" zju-connect "$client"
snapshot_path "$history_dir" shanghaitech-vpn "$launcher"
snapshot_path "$history_dir" shvpn "$shvpn"
snapshot_path "$history_dir" shanghaitech-ssh-route "$route"
snapshot_path "$history_dir" targets "$targets_file"
snapshot_path "$history_dir" ssh-config "$ssh_config"
snapshot_path "$history_dir" zshrc "$zshrc"
snapshot_path "$history_dir" manifest "$manifest"

writes_started=1
atomic_install "$work_dir/zju-connect" "$client" 755 || die 74 "cannot install zju-connect"
/usr/bin/codesign --verify --strict "$client" || die 65 "installed zju-connect signature verification failed"
atomic_install "$work_dir/shanghaitech-vpn" "$launcher" 755 || die 74 "cannot install launcher"
atomic_install "$work_dir/shvpn" "$shvpn" 755 || die 74 "cannot install shvpn"
atomic_install "$work_dir/shanghaitech-ssh-route" "$route" 755 || die 74 "cannot install route helper"
atomic_install "$work_dir/targets.tsv" "$targets_file" 600 || die 74 "cannot install target allowlist"
atomic_install "$work_dir/ssh.config" "$ssh_config" 600 || die 74 "cannot install SSH config"
if [[ "$path_choice" == "add" ]]; then
  atomic_install "$work_dir/zshrc" "$zshrc" 600 || die 74 "cannot install PATH block"
fi

for spec in \
  "zju-connect:$client" \
  "shanghaitech-vpn:$launcher" \
  "shvpn:$shvpn" \
  "shanghaitech-ssh-route:$route" \
  "targets:$targets_file"; do
  key="${spec%%:*}"
  managed_path="${spec#*:}"
  sha_file "$managed_path" || die 74 "cannot hash installed file: $managed_path"
  print -r -- "$key${TAB}$REPLY" >>"$work_dir/install.manifest.tsv"
done
sha_file "$work_dir/ssh.block"; ssh_block_sha="$REPLY"
sha_file "$ssh_config"; ssh_full_sha="$REPLY"
{
  print -r -- "format${TAB}1"
  print -r -- "path-choice${TAB}$path_choice"
  /bin/cat "$work_dir/install.manifest.tsv"
  print -r -- "ssh-block${TAB}$ssh_block_sha"
  print -r -- "ssh-full${TAB}$ssh_full_sha"
  if [[ "$path_choice" == "add" ]]; then
    sha_file "$work_dir/path.block"; path_block_sha="$REPLY"
    sha_file "$zshrc"; path_full_sha="$REPLY"
    print -r -- "path-block${TAB}$path_block_sha"
    print -r -- "path-full${TAB}$path_full_sha"
  fi
} >"$work_dir/manifest"
atomic_install "$work_dir/manifest" "$manifest" 600 || die 74 "cannot install manifest"

install_complete=1
print -r -- "安装完成。新开一个终端后可以使用："
if [[ "$path_choice" == "add" ]]; then
  print -r -- "  shvpn login    # 首次登录或登录过期时"
  print -r -- "  shvpn          # 后台启动"
  print -r -- "  shvpn status"
  print -r -- "  shvpn stop"
else
  print -r -- "  $shvpn login"
  print -r -- "  $shvpn"
  print -r -- "  $shvpn status"
  print -r -- "  $shvpn stop"
fi
for target_alias in "${target_aliases[@]}"; do
  print -r -- "  ssh $target_alias"
done
print -r -- "安装器没有启动 VPN，也没有修改 Clash 或 macOS 系统代理。"
