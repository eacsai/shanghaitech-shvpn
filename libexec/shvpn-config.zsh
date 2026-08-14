#!/bin/zsh

set -eu
setopt extendedglob
umask 077

typeset -gr targets_file=@@TARGETS_Q@@
typeset -gr route=@@ROUTE_Q@@
typeset -gr expected_route_proxy=@@ROUTE_PROXY_Q@@
typeset -gr ssh_config=@@SSH_CONFIG_Q@@
typeset -gr manifest=@@MANIFEST_Q@@
typeset -gr self=@@CONFIG_HELPER_Q@@
typeset -gr config_lock=@@CONFIG_LOCK_Q@@
typeset -gr backup_root=@@BACKUP_ROOT_Q@@
typeset -gr ssh_root="${ssh_config:h}"
typeset -gr begin_ssh="# >>> shanghaitech-shvpn managed SSH targets >>>"
typeset -gr end_ssh="# <<< shanghaitech-shvpn managed SSH targets <<<"
typeset -gr current_uid="$(/usr/bin/id -u)"
typeset -g config_lock_fd
typeset -ga target_hosts discovered_ssh_names
typeset -gA target_set
typeset -g alias_scan_incomplete=0
typeset -g resolved_host=""
typeset -g resolved_proxy=""

say_error() {
  print -u2 -r -- "$*"
}

die() {
  say_error "shvpn $action: $2"
  exit "$1"
}

usage() {
  print -u2 -r -- "usage: shvpn add SSH_NAME_OR_HOST"
  print -u2 -r -- "   or: shvpn remove SSH_NAME_OR_HOST"
}

safe_owned_regular() {
  local file_path="$1"
  [[ -f "$file_path" && ! -L "$file_path" ]] || return 1
  [[ "$(/usr/bin/stat -f %u "$file_path" 2>/dev/null)" == "$current_uid" ]]
}

safe_owned_dir() {
  local dir_path="$1"
  [[ -d "$dir_path" && ! -L "$dir_path" ]] || return 1
  [[ "$(/usr/bin/stat -f %u "$dir_path" 2>/dev/null)" == "$current_uid" ]]
}

sha_file() {
  REPLY="$(/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}')" || return 1
}

manifest_get() {
  local key="$1"
  REPLY="$(/usr/bin/awk -F '\t' -v key="$key" '
    $1 == key { count++; value=$2 }
    END { if (count != 1 || value == "") exit 65; print value }
  ' "$manifest")" || return 1
}

validate_name() {
  [[ "$1" == [A-Za-z0-9][A-Za-z0-9._-]# ]]
}

validate_target() {
  [[ "$1" == [A-Za-z0-9][A-Za-z0-9.-]# ]]
}

marker_count() {
  local file="$1"
  local marker="$2"
  REPLY="$(/usr/bin/grep -Fxc -- "$marker" "$file" 2>/dev/null || true)"
  [[ "$REPLY" == <-> ]]
}

extract_marked_block() {
  local input="$1"
  local output="$2"
  /usr/bin/awk -v begin="$begin_ssh" -v end="$end_ssh" '
    $0 == begin { if (inside) exit 65; inside=1 }
    inside { print }
    $0 == end { if (!inside) exit 65; inside=0; seen++ }
    END { if (inside || seen != 1) exit 65 }
  ' "$input" >"$output"
}

strip_marked_block() {
  local input="$1"
  local output="$2"
  /usr/bin/awk -v begin="$begin_ssh" -v end="$end_ssh" '
    $0 == begin { if (inside) exit 65; inside=1; seen_begin++; next }
    $0 == end { if (!inside) exit 65; inside=0; seen_end++; next }
    !inside { print }
    END { if (inside || seen_begin != 1 || seen_end != 1) exit 65 }
  ' "$input" >"$output"
}

append_block() {
  local base="$1"
  local block="$2"
  local output="$3"
  /bin/cp "$base" "$output"
  [[ ! -s "$output" ]] || print >>"$output"
  /bin/cat "$block" >>"$output"
}

atomic_install() {
  local source="$1"
  local destination="$2"
  local mode="$3"
  local local_tmp
  local_tmp="$(/usr/bin/mktemp "${destination:h}/.shvpn-config.XXXXXX")" || return 1
  if ! /usr/bin/install -m "$mode" "$source" "$local_tmp"; then
    /bin/rm -f -- "$local_tmp"
    return 1
  fi
  if ! /bin/mv -f "$local_tmp" "$destination"; then
    /bin/rm -f -- "$local_tmp"
    return 1
  fi
}

acquire_config_lock() {
  local lock_dir="${config_lock:h}"
  safe_owned_dir "$lock_dir" || die 69 "unsafe state directory: $lock_dir"
  if [[ -e "$config_lock" || -L "$config_lock" ]]; then
    safe_owned_regular "$config_lock" || die 69 "unsafe configuration lock: $config_lock"
  fi
  /usr/bin/touch "$config_lock" || die 74 "cannot create configuration lock"
  /bin/chmod 600 "$config_lock" || die 74 "cannot harden configuration lock"
  zmodload zsh/system || die 69 "zsh/system locking support is unavailable"
  zsystem flock -t 0 -f config_lock_fd -e "$config_lock" || die 75 "another shvpn configuration or lifecycle operation is in progress"
}

load_targets() {
  local line mode
  target_hosts=()
  target_set=()
  safe_owned_regular "$targets_file" || die 69 "target allowlist is missing or unsafe"
  mode="$(/usr/bin/stat -f %Lp "$targets_file")" || die 74 "cannot inspect target allowlist"
  [[ "$mode" == "600" ]] || die 69 "target allowlist mode is unsafe"
  while IFS= read -r line || [[ -n "$line" ]]; do
    validate_target "$line" || die 65 "target allowlist is malformed"
    [[ -z "${target_set[$line]:-}" ]] || die 65 "target allowlist contains a duplicate"
    target_set[$line]=1
    target_hosts+=("$line")
  done <"$targets_file"
  (( ${#target_hosts} > 0 )) || die 65 "target allowlist is empty"
}

resolve_name() {
  local name="$1"
  local output
  resolved_host=""
  resolved_proxy=""
  output="$(/usr/bin/ssh -F "$ssh_config" -G -- "$name" 2>/dev/null)" || return 1
  resolved_host="$(print -r -- "$output" | /usr/bin/awk '$1 == "hostname" {print $2; exit}')"
  resolved_proxy="$(print -r -- "$output" | /usr/bin/awk '$1 == "proxycommand" {$1=""; sub(/^ /, ""); print; exit}')"
  [[ -n "$resolved_host" ]]
}

mark_alias_scan_incomplete() {
  alias_scan_incomplete=1
}

collect_literal_ssh_names() {
  local root_config="$1"
  local config_file physical_file line first_word keyword first_arg word value
  local include_arg include_pattern include_match physical_match
  local queue_index=1 depth next_depth
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
    if ! safe_owned_regular "$config_file" || { [[ "$config_file" != "$root_config" ]] && [[ "$physical_file" != "$ssh_root"/* ]]; }; then
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
            if validate_name "$value" && [[ -z "${seen_names[$value]:-}" ]]; then
              if (( ${#discovered_ssh_names} >= 4096 )); then
                mark_alias_scan_incomplete
                break
              fi
              seen_names[$value]=1
              discovered_ssh_names+=("$value")
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

verify_manifest_and_state() {
  local key expected mode begin_count end_count
  safe_owned_regular "$manifest" || die 69 "install manifest is missing or unsafe"
  mode="$(/usr/bin/stat -f %Lp "$manifest")" || die 74 "cannot inspect install manifest"
  [[ "$mode" == "600" ]] || die 69 "install manifest mode is unsafe"
  manifest_get format || die 65 "invalid install manifest"
  [[ "$REPLY" == "3" ]] || die 65 "dynamic target management requires install manifest format 3; reinstall shvpn"
  for key in config-helper shanghaitech-ssh-route targets; do
    manifest_get "$key" || die 65 "missing install manifest entry: $key"
    expected="$REPLY"
    case "$key" in
      config-helper) safe_owned_regular "$self" && [[ -x "$self" && "$(/usr/bin/stat -f %Lp "$self" 2>/dev/null)" == "700" ]] || die 69 "configuration helper is missing or unsafe"; sha_file "$self" ;;
      shanghaitech-ssh-route) safe_owned_regular "$route" && [[ -x "$route" && "$(/usr/bin/stat -f %Lp "$route" 2>/dev/null)" == "755" ]] || die 69 "route helper is missing or unsafe"; sha_file "$route" ;;
      targets) safe_owned_regular "$targets_file" || die 69 "target allowlist is missing or unsafe"; sha_file "$targets_file" ;;
    esac || die 74 "cannot hash managed $key"
    [[ "$REPLY" == "$expected" ]] || die 2 "managed $key was modified; refusing"
  done
  safe_owned_regular "$ssh_config" || die 69 "SSH config is missing or unsafe"
  mode="$(/usr/bin/stat -f %Lp "$ssh_config")" || die 74 "cannot inspect SSH config"
  [[ "$mode" == <-> ]] || die 69 "SSH config mode is invalid"
  (( (8#$mode & 8#022) == 0 )) || die 69 "SSH config is writable by group or others"
  marker_count "$ssh_config" "$begin_ssh" || die 65 "cannot inspect SSH markers"
  begin_count="$REPLY"
  marker_count "$ssh_config" "$end_ssh" || die 65 "cannot inspect SSH markers"
  end_count="$REPLY"
  [[ "$begin_count" == 1 && "$end_count" == 1 ]] || die 2 "managed SSH marker state is ambiguous"
  extract_marked_block "$ssh_config" "$work_dir/current-ssh.block" || die 65 "managed SSH block is malformed"
  sha_file "$work_dir/current-ssh.block" || die 74 "cannot hash managed SSH block"
  expected="$REPLY"
  manifest_get ssh-block || die 65 "missing SSH block manifest entry"
  [[ "$expected" == "$REPLY" ]] || die 2 "managed SSH block was modified; refusing"
  load_targets
}

validate_candidate() {
  local name output host proxy
  local -A seen_names
  [[ -x /usr/bin/ssh && -f /usr/bin/ssh ]] || die 69 "system OpenSSH client is unavailable"
  for name in "${target_hosts[@]}"; do
    output="$(/usr/bin/ssh -F "$work_dir/ssh.config" -G -- "$name" 2>/dev/null)" || die 2 "ssh -G rejected target $name"
    host="$(print -r -- "$output" | /usr/bin/awk '$1 == "hostname" {print $2; exit}')"
    proxy="$(print -r -- "$output" | /usr/bin/awk '$1 == "proxycommand" {$1=""; sub(/^ /, ""); print; exit}')"
    [[ "$host" == "$name" && "$proxy" == "$expected_route_proxy" ]] || die 2 "SSH target $name resolves outside the managed configuration"
  done
  collect_literal_ssh_names "$work_dir/ssh.base"
  for name in "${discovered_ssh_names[@]}"; do
    [[ -z "${seen_names[$name]:-}" ]] || continue
    seen_names[$name]=1
    output="$(/usr/bin/ssh -F "$work_dir/ssh.config" -G -- "$name" 2>/dev/null)" || die 2 "ssh -G rejected discovered alias $name"
    host="$(print -r -- "$output" | /usr/bin/awk '$1 == "hostname" {print $2; exit}')"
    if [[ -n "${target_set[$host]:-}" ]]; then
      proxy="$(print -r -- "$output" | /usr/bin/awk '$1 == "proxycommand" {$1=""; sub(/^ /, ""); print; exit}')"
      [[ "$proxy" == "$expected_route_proxy" ]] || die 2 "SSH alias $name has an earlier ProxyCommand or ProxyJump; refusing incomplete routing"
    fi
  done
  if (( alias_scan_incomplete )); then
    say_error "shvpn $action: warning: SSH alias discovery was incomplete because of Include, safety, or scan limits; run 'shvpn doctor ALIAS' for names not checked automatically"
  fi
}

write_updated_manifest() {
  local target_sha="$1"
  local block_sha="$2"
  local full_sha="$3"
  /usr/bin/awk -F '\t' -v OFS='\t' -v targets="$target_sha" -v block="$block_sha" -v full="$full_sha" '
    $1 == "targets" { if (++targets_seen > 1) exit 65; $2=targets }
    $1 == "ssh-block" { if (++block_seen > 1) exit 65; $2=block }
    $1 == "ssh-full" { if (++full_seen > 1) exit 65; $2=full }
    { print }
    END { if (targets_seen != 1 || block_seen != 1 || full_seen != 1) exit 65 }
  ' "$manifest" >"$work_dir/manifest"
}

snapshot_for_update() {
  local backup_id
  safe_owned_dir "$backup_root" || die 69 "backup directory is missing or unsafe"
  backup_id="$(/bin/date -u +%Y%m%dT%H%M%SZ)-$$"
  backup_dir="$backup_root/$backup_id-config-$action"
  [[ ! -e "$backup_dir" && ! -L "$backup_dir" ]] || die 65 "configuration backup destination already exists"
  /usr/bin/install -d -m 700 "$backup_dir" || die 74 "cannot create configuration backup"
  /bin/cp -p "$targets_file" "$backup_dir/targets.file" || die 74 "cannot back up target allowlist"
  /bin/cp -p "$ssh_config" "$backup_dir/ssh-config.file" || die 74 "cannot back up SSH config"
  /bin/cp -p "$manifest" "$backup_dir/manifest.file" || die 74 "cannot back up install manifest"
}

restore_backup() {
  local failed=0
  [[ -n "${backup_dir:-}" && -d "$backup_dir" && ! -L "$backup_dir" ]] || return 1
  if (( manifest_written )); then
    atomic_install "$backup_dir/manifest.file" "$manifest" 600 || failed=1
  fi
  if (( targets_written )); then
    atomic_install "$backup_dir/targets.file" "$targets_file" 600 || failed=1
  fi
  if (( ssh_written )); then
    atomic_install "$backup_dir/ssh-config.file" "$ssh_config" 600 || failed=1
  fi
  return "$failed"
}

(( $# == 2 )) || { usage; exit 64; }
action="$1"
requested="$2"
[[ "$action" == add || "$action" == remove ]] || { usage; exit 64; }
validate_name "$requested" || die 64 "invalid SSH name or host: $requested"

temp_parent="${TMPDIR:-/tmp}"
[[ -d "$temp_parent" && "$temp_parent" == /* ]] || die 69 "TMPDIR must name an existing absolute directory"
work_dir="$(/usr/bin/mktemp -d "$temp_parent/shvpn-config.XXXXXX")" || die 74 "cannot create temporary directory"
writes_started=0
ssh_written=0
targets_written=0
manifest_written=0
complete=0
backup_dir=""
cleanup() {
  local rc="$?"
  if (( rc != 0 && writes_started && ! complete )); then
    restore_backup || say_error "shvpn $action: automatic rollback was incomplete; inspect $backup_dir"
  fi
  if [[ -d "$work_dir" && "$work_dir" == "$temp_parent"/shvpn-config.* ]]; then
    /bin/rm -rf -- "$work_dir"
  fi
  return "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

acquire_config_lock
verify_manifest_and_state

if [[ "$action" == add && -n "${target_set[$requested]:-}" ]]; then
  print -r -- "shvpn add: $requested is already managed."
  complete=1
  exit 0
fi

if [[ "$action" == add ]]; then
  resolve_name "$requested" || die 64 "cannot resolve SSH name: $requested"
  validate_target "$resolved_host" || die 64 "resolved HostName is not a supported target: $resolved_host"
  if [[ -n "${target_set[$resolved_host]:-}" ]]; then
    print -r -- "shvpn add: $requested already resolves to managed target $resolved_host."
    complete=1
    exit 0
  fi
  target_hosts+=("$resolved_host")
  target_set[$resolved_host]=1
  changed_target="$resolved_host"
else
  if [[ -n "${target_set[$requested]:-}" ]]; then
    changed_target="$requested"
  else
    resolve_name "$requested" || die 64 "cannot resolve SSH name: $requested"
    validate_target "$resolved_host" || die 64 "resolved HostName is not a supported target: $resolved_host"
    [[ -n "${target_set[$resolved_host]:-}" ]] || die 64 "$requested does not resolve to a managed target"
    [[ "$resolved_proxy" == "$expected_route_proxy" ]] || die 64 "$requested is not using the managed route"
    changed_target="$resolved_host"
  fi
  (( ${#target_hosts} > 1 )) || die 64 "cannot remove the last target; use 'shvpn uninstall' to remove shvpn"
  new_targets=()
  for host in "${target_hosts[@]}"; do
    [[ "$host" == "$changed_target" ]] || new_targets+=("$host")
  done
  target_hosts=("${new_targets[@]}")
  unset "target_set[$changed_target]"
fi

: >"$work_dir/targets.tsv"
: >"$work_dir/ssh.block"
print -r -- "$begin_ssh" >>"$work_dir/ssh.block"
for host in "${target_hosts[@]}"; do
  print -r -- "$host" >>"$work_dir/targets.tsv"
done
print -r -- "Match final host ${(j:,:)target_hosts}" >>"$work_dir/ssh.block"
print -r -- "    ProxyCommand $expected_route_proxy" >>"$work_dir/ssh.block"
print -r -- "$end_ssh" >>"$work_dir/ssh.block"
strip_marked_block "$ssh_config" "$work_dir/ssh.base" || die 65 "cannot prepare SSH config"
append_block "$work_dir/ssh.base" "$work_dir/ssh.block" "$work_dir/ssh.config"
validate_candidate
sha_file "$work_dir/targets.tsv" || die 74 "cannot hash target candidate"
target_sha="$REPLY"
sha_file "$work_dir/ssh.block" || die 74 "cannot hash SSH block candidate"
block_sha="$REPLY"
sha_file "$work_dir/ssh.config" || die 74 "cannot hash SSH config candidate"
full_sha="$REPLY"
write_updated_manifest "$target_sha" "$block_sha" "$full_sha" || die 65 "cannot compose install manifest"

snapshot_for_update
writes_started=1
atomic_install "$work_dir/ssh.config" "$ssh_config" 600 || die 74 "cannot update SSH config"
ssh_written=1
atomic_install "$work_dir/targets.tsv" "$targets_file" 600 || die 74 "cannot update target allowlist"
targets_written=1
atomic_install "$work_dir/manifest" "$manifest" 600 || die 74 "cannot update install manifest"
manifest_written=1
sha_file "$ssh_config" || die 74 "cannot verify SSH config"
[[ "$REPLY" == "$full_sha" ]] || die 74 "SSH config verification failed"
sha_file "$targets_file" || die 74 "cannot verify target allowlist"
[[ "$REPLY" == "$target_sha" ]] || die 74 "target allowlist verification failed"
sha_file "$work_dir/manifest" || die 74 "cannot verify manifest candidate"
candidate_manifest_sha="$REPLY"
sha_file "$manifest" || die 74 "cannot verify installed manifest"
[[ "$REPLY" == "$candidate_manifest_sha" ]] || die 74 "install manifest verification failed"
complete=1

if [[ "$action" == add ]]; then
  if [[ "$requested" == "$changed_target" ]]; then
    print -r -- "Added managed target $changed_target. Existing SSH sessions were not changed."
  else
    print -r -- "Added managed target $requested -> $changed_target. Existing SSH sessions were not changed."
  fi
else
  if [[ "$requested" == "$changed_target" ]]; then
    print -r -- "Removed managed target $changed_target. SSH aliases sharing this HostName no longer receive the managed route. Existing SSH sessions were not changed."
  else
    print -r -- "Removed managed target $requested -> $changed_target. SSH aliases sharing this HostName no longer receive the managed route. Existing SSH sessions were not changed."
  fi
fi
print -r -- "Backup: $backup_dir"
