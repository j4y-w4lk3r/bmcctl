#!/usr/bin/env bash
# First-boot: join this host to Headscale via the Tailscale client.
# Config: /etc/bmcctl/headscale.env (written during install.sh from a
# single-use key fetched over HTTP from the build host — not from the ISO).
set -euo pipefail

MARKER=/var/lib/bmcctl/headscale-done
ENV_FILE=/etc/bmcctl/headscale.env
LOG=/var/log/bmcctl-headscale.log

[[ -f $MARKER ]] && exit 0
[[ -f $ENV_FILE ]] || {
  echo "headscale-join: $ENV_FILE missing — was headscale disabled in TOML?" >>"$LOG"
  exit 0
}

exec >>"$LOG" 2>&1
echo "::: bmcctl headscale join $(date -Is)"

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${HEADSCALE_LOGIN_SERVER:?HEADSCALE_LOGIN_SERVER missing in $ENV_FILE}"
: "${HEADSCALE_AUTHKEY:?HEADSCALE_AUTHKEY missing — install.sh should have fetched it from the build host during install}"

HOSTNAME="${HEADSCALE_HOSTNAME:-}"
ACCEPT_ROUTES="${HEADSCALE_ACCEPT_ROUTES:-true}"
ACCEPT_DNS="${HEADSCALE_ACCEPT_DNS:-true}"

for i in $(seq 1 90); do
  ping -c1 -W2 "${HEADSCALE_LOGIN_SERVER#https://}" &>/dev/null && break
  sleep 2
done

systemctl enable --now tailscaled.service

args=( --login-server="$HEADSCALE_LOGIN_SERVER" --authkey="$HEADSCALE_AUTHKEY" --ssh )
[[ $ACCEPT_ROUTES != false ]] && args+=( --accept-routes )
[[ $ACCEPT_DNS != false ]] && args+=( --accept-dns )
[[ -n $HOSTNAME ]] && args+=( --hostname="$HOSTNAME" )

tailscale up "${args[@]}"

ip=$(tailscale ip -4 2>/dev/null || true)
echo "::: joined headscale ip=${ip:-?} hostname=${HOSTNAME:-$(hostname)}"

# Report install stamp to VPS registry (best-effort; needs mesh SSH).
if [[ -x /usr/local/lib/bmcctl/homelab-registry-push.sh ]]; then
  /usr/local/lib/bmcctl/homelab-registry-push.sh \
    || echo "WARN: homelab registry push failed (non-fatal)"
fi

install -d /var/lib/bmcctl
date -Is >"$MARKER"
