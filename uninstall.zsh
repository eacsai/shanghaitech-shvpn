#!/bin/zsh

set -eu
setopt extendedglob
umask 077

typeset -gr begin_ssh="# >>> shanghaitech-shvpn managed SSH targets >>>"
typeset -gr end_ssh="# <<< shanghaitech-shvpn managed SSH targets <<<"
typeset -gr begin_path="# >>> shanghaitech-shvpn managed PATH >>>"
typeset -gr end_path="# <<< shanghaitech-shvpn managed PATH <<<"
typeset -gr current_uid="$(/usr/bin/id -u)"
typeset -g config_lock_fd

say_error() {
  print -u2 -r -- "$*"
}

die() {
  say_error "uninstall: $2"
  exit "$1"
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

safe_owned_dir() {
  [[ -d "$1" && ! -L "$1" && "$(/usr/bin/stat -f %u "$1" 2>/dev/null)" == "$current_uid" ]]
}

safe_login_python() {
  local python_bin="$1"
  local resolved mode owner permission
  [[ -x "$python_bin" ]] || return 1
  resolved="${python_bin:A}"
  [[ -f "$resolved" && -x "$resolved" && ! -L "$resolved" ]] || return 1
  owner="$(/usr/bin/stat -f %u "$resolved" 2>/dev/null)" || return 1
  [[ "$owner" == 0 || "$owner" == "$current_uid" ]] || return 1
  mode="$(/usr/bin/stat -f %Lp "$resolved" 2>/dev/null)" || return 1
  [[ "$mode" == <-> ]] || return 1
  permission=$(( 8#$mode ))
  (( (permission & 8#022) == 0 ))
}

manifest_get() {
  local key="$1"
  local manifest_file="$2"
  REPLY="$(/usr/bin/awk -F '\t' -v key="$key" '
    $1 == key { count++; value=$2 }
    END { if (count != 1 || value == "") exit 65; print value }
  ' "$manifest_file")" || return 1
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
  /usr/bin/awk -v begin="$begin" -v end="$end" '
    $0 == begin { if (inside) exit 65; inside=1; seen_begin++; next }
    $0 == end { if (!inside) exit 65; inside=0; seen_end++; next }
    !inside { print }
    END { if (inside || seen_begin != 1 || seen_end != 1) exit 65 }
  ' "$input" >"$output"
}

atomic_install() {
  local source="$1"
  local destination="$2"
  local mode="$3"
  local destination_dir="${destination:h}"
  local local_tmp
  local_tmp="$(/usr/bin/mktemp "$destination_dir/.shvpn-uninstall.XXXXXX")" || return 1
  if ! /usr/bin/install -m "$mode" "$source" "$local_tmp"; then
    /bin/rm -f -- "$local_tmp"
    return 1
  fi
  if ! /bin/mv -f "$local_tmp" "$destination"; then
    /bin/rm -f -- "$local_tmp"
    return 1
  fi
}

archive_current() {
  local key="$1"
  local file_path="$2"
  if [[ -f "$file_path" && ! -L "$file_path" ]]; then
    /bin/cp -p "$file_path" "$archive_dir/$key.file" || return 1
    sha_file "$file_path" || return 1
    print -r -- "$REPLY" >"$archive_dir/$key.sha256"
  fi
}

restore_baseline() {
  local key="$1"
  local destination="$2"
  local state_line state digest mode
  [[ -f "$baseline_dir/$key.state" && ! -L "$baseline_dir/$key.state" ]] || return 1
  state_line="$(<"$baseline_dir/$key.state")"
  IFS=$'\t' read -r state digest mode <<<"$state_line"
  case "$state" in
    present)
      [[ -f "$baseline_dir/$key.file" && ! -L "$baseline_dir/$key.file" && "$digest" == [0-9a-f](#c64) && "$mode" == <-> ]] || return 1
      sha_file "$baseline_dir/$key.file" || return 1
      [[ "$REPLY" == "$digest" ]] || return 1
      atomic_install "$baseline_dir/$key.file" "$destination" "$mode"
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

acquire_config_lock() {
  local lock_dir="${config_lock:h}"
  if [[ -e "$lock_dir" || -L "$lock_dir" ]]; then
    [[ -d "$lock_dir" && ! -L "$lock_dir" && "$(/usr/bin/stat -f %u "$lock_dir" 2>/dev/null)" == "$current_uid" ]] || die 69 "unsafe state directory: $lock_dir"
  else
    /usr/bin/install -d -m 700 "$lock_dir" || die 74 "cannot create state directory"
  fi
  /bin/chmod 700 "$lock_dir" || die 74 "cannot harden state directory"
  if [[ -e "$config_lock" || -L "$config_lock" ]]; then
    safe_regular_or_absent "$config_lock" || die 69 "unsafe configuration lock: $config_lock"
  fi
  /usr/bin/touch "$config_lock" || die 74 "cannot create configuration lock"
  /bin/chmod 600 "$config_lock" || die 74 "cannot harden configuration lock"
  zmodload zsh/system || die 69 "zsh/system locking support is unavailable"
  zsystem flock -t 0 -f config_lock_fd -e "$config_lock" || die 75 "another shvpn configuration or lifecycle operation is in progress"
}

home_dir="${HOME:A}"
[[ -d "$home_dir" && ! -L "$home_dir" && "$home_dir" == /* ]] || die 69 "HOME is not a safe physical directory"
[[ "$home_dir" != *$'\n'* && "$home_dir" != *$'\r'* && "$home_dir" != *$'\t'* && "$home_dir" != *'|'* ]] || die 69 "HOME contains unsupported characters"
[[ "$(/usr/bin/stat -f %u "$home_dir")" == "$current_uid" ]] || die 69 "HOME is not owned by the current user"

bin_dir="$home_dir/.local/bin"
lib_dir="$home_dir/.local/lib/shanghaitech-shvpn"
baseline_dir="$lib_dir/baseline"
manifest="$lib_dir/install.manifest.tsv"
targets_file="$home_dir/.config/shanghaitech-shvpn/targets.tsv"
ssh_config="$home_dir/.ssh/config"
zshrc="$home_dir/.zshrc"
client="$bin_dir/zju-connect"
launcher="$bin_dir/shanghaitech-vpn"
shvpn="$bin_dir/shvpn"
route="$bin_dir/shanghaitech-ssh-route"
config_helper="$lib_dir/configure-targets.zsh"
uninstall_helper="$lib_dir/uninstall.zsh"
login_helper="$lib_dir/python-login-helper.py"
login_requirements="$lib_dir/requirements-login.txt"
login_packages="$lib_dir/python-packages"
state_dir="$home_dir/Library/Application Support/ShanghaitechVPN"
config_lock="$state_dir/shvpn.config.lock"

[[ -d "$lib_dir" && ! -L "$lib_dir" && "$(/usr/bin/stat -f %u "$lib_dir" 2>/dev/null)" == "$current_uid" ]] || die 69 "trusted installation metadata was not found"
[[ -f "$manifest" && ! -L "$manifest" && "$(/usr/bin/stat -f %Lp "$manifest")" == "600" ]] || die 69 "trusted install manifest was not found"
[[ -d "$baseline_dir" && ! -L "$baseline_dir" && -f "$baseline_dir/COMPLETE" ]] || die 65 "baseline metadata is incomplete"
manifest_get format "$manifest" || die 65 "invalid install manifest"
install_format="$REPLY"
[[ "$install_format" == "1" || "$install_format" == "2" || "$install_format" == "3" ]] || die 65 "unsupported install manifest"
manifest_get path-choice "$manifest" || die 65 "invalid PATH policy in manifest"
path_choice="$REPLY"
[[ "$path_choice" == "add" || "$path_choice" == "none" ]] || die 65 "invalid PATH policy in manifest"

for managed_path in "$client" "$launcher" "$shvpn" "$route" "$targets_file" "$ssh_config" "$zshrc" "$config_lock"; do
  safe_regular_or_absent "$managed_path" || die 69 "unsafe managed path: $managed_path"
done
if [[ "$install_format" == "2" || "$install_format" == "3" ]]; then
  for managed_path in "$config_helper" "$uninstall_helper"; do
    safe_regular_or_absent "$managed_path" || die 69 "unsafe managed helper: $managed_path"
    [[ ! -f "$managed_path" || "$(/usr/bin/stat -f %Lp "$managed_path")" == "700" ]] || die 69 "managed helper has unsafe mode: $managed_path"
  done
fi
if [[ "$install_format" == "3" ]]; then
  for managed_path in "$login_helper" "$login_requirements"; do
    safe_regular_or_absent "$managed_path" || die 69 "unsafe managed login file: $managed_path"
  done
  safe_owned_dir "$login_packages" || die 69 "unsafe managed Python package tree"
fi

temp_parent="${TMPDIR:-/tmp}"
[[ -d "$temp_parent" && "$temp_parent" == /* ]] || die 69 "TMPDIR must name an existing absolute directory"
work_dir="$(/usr/bin/mktemp -d "$temp_parent/shvpn-uninstall.XXXXXX")"
cleanup_work() {
  if [[ -n "${work_dir:-}" && -d "$work_dir" && "$work_dir" == "$temp_parent"/shvpn-uninstall.* ]]; then
    /bin/rm -rf -- "$work_dir"
  fi
}
trap cleanup_work EXIT
trap 'exit 130' INT TERM

preflight_failed=0
preflight_file() {
  local key="$1"
  local destination="$2"
  local expected_sha
  manifest_get "$key" "$manifest" || die 65 "missing manifest entry for $key"
  expected_sha="$REPLY"
  if [[ ! -f "$destination" ]]; then
    say_error "uninstall: managed file is missing: $destination"
    preflight_failed=1
    return
  fi
  sha_file "$destination" || die 74 "cannot hash $destination"
  if [[ "$REPLY" != "$expected_sha" ]]; then
    say_error "uninstall: managed file was modified: $destination"
    preflight_failed=1
  fi
}

preflight_block() {
  local key="$1"
  local full_key="$2"
  local destination="$3"
  local begin="$4"
  local end="$5"
  local label="$6"
  local expected_block expected_full begin_count end_count
  manifest_get "$key" "$manifest" || die 65 "missing block manifest entry: $key"
  expected_block="$REPLY"
  manifest_get "$full_key" "$manifest" || die 65 "missing full-file manifest entry: $full_key"
  expected_full="$REPLY"
  if [[ ! -f "$destination" ]]; then
    say_error "uninstall: managed config is missing: $destination"
    preflight_failed=1
    return
  fi
  sha_file "$destination" || die 74 "cannot hash $destination"
  [[ "$REPLY" == "$expected_full" ]] && return
  marker_count "$destination" "$begin" || die 65 "cannot inspect markers in $destination"
  begin_count="$REPLY"
  marker_count "$destination" "$end" || die 65 "cannot inspect markers in $destination"
  end_count="$REPLY"
  if [[ "$begin_count" != 1 || "$end_count" != 1 ]]; then
    say_error "uninstall: ambiguous $label marker state: $destination"
    preflight_failed=1
    return
  fi
  extract_marked_block "$destination" "$work_dir/preflight-$label.block" "$begin" "$end" || die 65 "malformed $label block"
  sha_file "$work_dir/preflight-$label.block" || die 74 "cannot hash $label block"
  if [[ "$REPLY" != "$expected_block" ]]; then
    say_error "uninstall: managed $label block was modified: $destination"
    preflight_failed=1
  fi
}

run_preflight() {
  preflight_failed=0
  preflight_file zju-connect "$client"
  preflight_file shanghaitech-vpn "$launcher"
  preflight_file shvpn "$shvpn"
  preflight_file shanghaitech-ssh-route "$route"
  preflight_file targets "$targets_file"
  if [[ "$install_format" == "2" || "$install_format" == "3" ]]; then
    preflight_file config-helper "$config_helper"
    preflight_file uninstall-helper "$uninstall_helper"
  fi
  if [[ "$install_format" == "3" ]]; then
    preflight_file login-helper "$login_helper"
    preflight_file login-requirements "$login_requirements"
    if (( preflight_failed != 0 )); then
      return 1
    fi
    manifest_get login-python "$manifest" || die 65 "missing recorded Python"
    login_python="$REPLY"
    safe_login_python "$login_python" || die 69 "recorded Python is unavailable or unsafe"
    manifest_get login-python-version "$manifest" || die 65 "missing recorded Python version"
    expected_python_version="$REPLY"
    actual_python_version="$("$login_python" -I -B -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)" || die 69 "cannot inspect recorded Python"
    [[ "$actual_python_version" == "$expected_python_version" ]] || die 69 "recorded Python version changed"
    manifest_get login-python-sha256 "$manifest" || die 65 "missing recorded Python hash"
    expected_python_sha="$REPLY"
    sha_file "${login_python:A}" || die 74 "cannot hash recorded Python"
    [[ "$REPLY" == "$expected_python_sha" ]] || die 69 "recorded Python executable changed"
    manifest_get login-packages "$manifest" || die 65 "missing Python package digest"
    expected_packages_sha="$REPLY"
    actual_packages_sha="$("$login_python" -I -B "$login_helper" --tree-digest "$login_packages" 2>/dev/null)" || die 69 "cannot verify Python package tree"
    if [[ "$actual_packages_sha" != "$expected_packages_sha" ]]; then
      say_error "uninstall: managed Python package tree was modified"
      preflight_failed=1
    fi
  fi
  preflight_block ssh-block ssh-full "$ssh_config" "$begin_ssh" "$end_ssh" ssh
  if [[ "$path_choice" == "add" ]]; then
    preflight_block path-block path-full "$zshrc" "$begin_path" "$end_path" path
  fi
  (( preflight_failed == 0 ))
}

run_preflight || die 2 "nothing was changed; resolve the reported modified or ambiguous files first"

set +e
"$shvpn" status >/dev/null 2>&1
vpn_status=$?
set -e
case "$vpn_status" in
  0)
    "$shvpn" stop || die 75 "trusted VPN process could not be stopped safely"
    ;;
  1)
    ;;
  2)
    say_error "uninstall: port 127.0.0.1:11080 is untrusted or ambiguous; leaving that process untouched and continuing"
    ;;
  *)
    die 75 "unexpected shvpn status: $vpn_status"
    ;;
esac

acquire_config_lock
run_preflight || die 2 "nothing was changed; installation state changed while uninstall was waiting"
set +e
"$shvpn" status >/dev/null 2>&1
vpn_status=$?
set -e
case "$vpn_status" in
  1)
    ;;
  2)
    say_error "uninstall: port 127.0.0.1:11080 is untrusted or ambiguous; leaving that process untouched and continuing"
    ;;
  0)
    die 75 "VPN restarted while uninstall was waiting for the configuration lock; nothing was changed"
    ;;
  *)
    die 75 "unexpected shvpn status after locking: $vpn_status"
    ;;
esac

archive_root="$lib_dir/uninstall-archives"
if [[ -e "$archive_root" || -L "$archive_root" ]]; then
  [[ -d "$archive_root" && ! -L "$archive_root" && "$(/usr/bin/stat -f %u "$archive_root")" == "$current_uid" ]] || die 69 "unsafe uninstall archive directory"
else
  /usr/bin/install -d -m 700 "$archive_root"
fi
archive_id="$(/bin/date -u +%Y%m%dT%H%M%SZ)-$$"
archive_dir="$archive_root/$archive_id"
retired_dir="$home_dir/.local/lib/shanghaitech-shvpn.uninstalled-$archive_id"
[[ ! -e "$retired_dir" && ! -L "$retired_dir" ]] || die 65 "uninstall archive destination already exists: $retired_dir"
/usr/bin/install -d -m 700 "$archive_dir"

unresolved=0

restore_managed_file() {
  local key="$1"
  local destination="$2"
  local expected_sha
  manifest_get "$key" "$manifest" || {
    say_error "uninstall: missing manifest entry for $key"
    unresolved=1
    return
  }
  expected_sha="$REPLY"
  if [[ ! -f "$destination" ]]; then
    say_error "uninstall: managed file is missing; leaving baseline untouched: $destination"
    unresolved=1
    return
  fi
  sha_file "$destination" || {
    unresolved=1
    return
  }
  if [[ "$REPLY" != "$expected_sha" ]]; then
    say_error "uninstall: managed file was modified and was left untouched: $destination"
    unresolved=1
    return
  fi
  archive_current "$key" "$destination" || die 74 "cannot archive $destination"
  restore_baseline "$key" "$destination" || die 74 "cannot restore baseline for $destination"
}

restore_managed_block() {
  local key="$1"
  local full_key="$2"
  local destination="$3"
  local begin="$4"
  local end="$5"
  local baseline_key="$6"
  local expected_block expected_full begin_count end_count current_full current_block
  [[ -f "$destination" ]] || {
    say_error "uninstall: managed config is missing and was left unresolved: $destination"
    unresolved=1
    return
  }
  manifest_get "$key" "$manifest" || die 65 "missing block manifest entry: $key"
  expected_block="$REPLY"
  manifest_get "$full_key" "$manifest" || die 65 "missing full-file manifest entry: $full_key"
  expected_full="$REPLY"
  sha_file "$destination" || die 74 "cannot hash $destination"
  current_full="$REPLY"
  archive_current "$baseline_key" "$destination" || die 74 "cannot archive $destination"
  if [[ "$current_full" == "$expected_full" ]]; then
    restore_baseline "$baseline_key" "$destination" || die 74 "cannot restore baseline for $destination"
    return
  fi
  marker_count "$destination" "$begin" || die 65 "cannot inspect markers in $destination"
  begin_count="$REPLY"
  marker_count "$destination" "$end" || die 65 "cannot inspect markers in $destination"
  end_count="$REPLY"
  if [[ "$begin_count" != 1 || "$end_count" != 1 ]]; then
    say_error "uninstall: ambiguous managed block was left untouched: $destination"
    unresolved=1
    return
  fi
  extract_marked_block "$destination" "$work_dir/$baseline_key.block" "$begin" "$end" || die 65 "malformed managed block in $destination"
  sha_file "$work_dir/$baseline_key.block" || die 74 "cannot hash managed block"
  current_block="$REPLY"
  if [[ "$current_block" != "$expected_block" ]]; then
    say_error "uninstall: modified managed block was left untouched: $destination"
    unresolved=1
    return
  fi
  strip_marked_block "$destination" "$work_dir/$baseline_key.stripped" "$begin" "$end" || die 65 "cannot remove managed block from $destination"
  atomic_install "$work_dir/$baseline_key.stripped" "$destination" 600 || die 74 "cannot update $destination"
}

restore_managed_block ssh-block ssh-full "$ssh_config" "$begin_ssh" "$end_ssh" ssh-config
if [[ "$path_choice" == "add" ]]; then
  restore_managed_block path-block path-full "$zshrc" "$begin_path" "$end_path" zshrc
fi

restore_managed_file targets "$targets_file"
restore_managed_file shanghaitech-ssh-route "$route"
restore_managed_file shanghaitech-vpn "$launcher"
restore_managed_file shvpn "$shvpn"
restore_managed_file zju-connect "$client"

if (( unresolved )); then
  say_error "uninstall: some user-modified or ambiguous files were left untouched"
  say_error "uninstall: review the archive and manifest under $lib_dir"
  exit 2
fi

/bin/cp -p "$manifest" "$archive_dir/install.manifest.tsv"
sha_file "$manifest"
print -r -- "$REPLY" >"$archive_dir/install.manifest.sha256"
/bin/mv "$manifest" "$archive_dir/consumed-install.manifest.tsv"

/bin/mv "$lib_dir" "$retired_dir" || die 74 "cannot retire installation metadata"
retired_archive="$retired_dir/uninstall-archives/$archive_id"

print -r -- "卸载完成。安装前的文件已恢复；本次归档保存在："
print -r -- "  $retired_archive"
print -r -- "VPN 登录状态和日志未删除。"
