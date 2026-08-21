#!/usr/bin/env zsh
set -u
umask 077

client=@@CLIENT_Q@@
state_dir=@@STATE_DIR_Q@@
nc_bin=@@NC_BIN_Q@@
client_data="$state_dir/client-data.json"

# Keep this VPN path independent from any Clash/proxy environment inherited by
# the launching terminal. This changes only this script and its child process.
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy

harden_client_data() {
  if [[ -f "$client_data" ]]; then
    /bin/chmod 600 "$client_data"
  fi
}
trap harden_client_data EXIT

if [[ ! -x "$client" ]]; then
  print -u2 "zju-connect is not installed or executable: $client"
  exit 1
fi

/usr/bin/install -d -m 700 "$state_dir"

if "$nc_bin" -z -w 1 127.0.0.1 11080 >/dev/null 2>&1; then
  print -u2 "127.0.0.1:11080 is already in use; not starting another VPN client."
  exit 1
fi

"$client" \
  -protocol atrust \
  -server vpn.shanghaitech.edu.cn \
  -port 443 \
  -login-domain Shanghaitech.edu.cn \
  -auth-type auth/cas \
  -client-data-file "$client_data" \
  -socks-bind 127.0.0.1:11080 \
  -http-bind "" \
  -auto-detect-interface
client_status=$?

harden_client_data

exit "$client_status"
