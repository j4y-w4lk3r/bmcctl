#!/usr/bin/env bash
# homelab-registry-push — report host install facts to the VPS registry.
#
# Called on first boot (after Headscale join) or manually:
#   homelab-registry-push.sh
#   homelab-registry-push.sh --dry-run
#
# Remote JSON: HLREG_PATH on HLREG_HOST (default: j4y-control-01).
set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

STAMP=/etc/bmcctl-install-id
REGISTRY_HOST="${HLREG_HOST:-j4y-control-01}"
REGISTRY_USER="${HLREG_USER:-j4y}"
REGISTRY_PATH="${HLREG_PATH:-/home/j4y/homelab/hosts.json}"

[[ -f $STAMP ]] || {
  echo "homelab-registry-push: $STAMP missing — not a bmcctl-installed host?" >&2
  exit 1
}

# shellcheck disable=SC1090
source <(grep -E '^[a-z_]+=' "$STAMP" | sed 's/^/export /')

: "${id:?install id missing in $STAMP}"
: "${hostname:?hostname missing in $STAMP}"

ts_ip=$(tailscale ip -4 2>/dev/null || true)
lan_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' || true)
kernel=$(uname -r 2>/dev/null || true)
reported_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

export hostname install_id="$id" installed_at="${installed_at:-}" \
  installer="${installer:-bmcctl-iso}" iso="${iso:-}" \
  tailscale_ip="$ts_ip" lan_ip="$lan_ip" kernel="$kernel" reported_at="$reported_at"

payload=$(
  python3 - <<'PY'
import json, os
print(json.dumps({
    "hostname": os.environ["hostname"],
    "install_id": os.environ["install_id"],
    "installed_at": os.environ.get("installed_at") or None,
    "installer": os.environ.get("installer") or None,
    "iso": os.environ.get("iso") or None,
    "tailscale_ip": os.environ.get("tailscale_ip") or None,
    "lan_ip": os.environ.get("lan_ip") or None,
    "kernel": os.environ.get("kernel") or None,
    "reported_at": os.environ["reported_at"],
}, separators=(",", ":")))
PY
)

if [[ $DRY_RUN == 1 ]]; then
  echo "dry-run: would push to ${REGISTRY_USER}@${REGISTRY_HOST}:${REGISTRY_PATH}"
  echo "$payload" | python3 -m json.tool
  exit 0
fi

ssh_target="${REGISTRY_USER}@${REGISTRY_HOST}"
use_tailscale=0
if command -v tailscale >/dev/null 2>&1; then
  if tailscale status 2>/dev/null | awk '{print $2}' | grep -qx "$REGISTRY_HOST"; then
    use_tailscale=1
  fi
fi

run_remote() {
  if (( use_tailscale )); then
    tailscale ssh "$ssh_target" "$@"
  else
    ssh -o BatchMode=yes -o ConnectTimeout=15 "$ssh_target" "$@"
  fi
}

payload_b64=$(printf '%s' "$payload" | base64 -w0 2>/dev/null || printf '%s' "$payload" | base64)

run_remote \
  "REGISTRY_PATH=$(printf '%q' "$REGISTRY_PATH") PAYLOAD_B64=$(printf '%q' "$payload_b64") python3 -" <<'PY'
import base64, json, os, sys
path = os.environ["REGISTRY_PATH"]
incoming = json.loads(base64.b64decode(os.environ["PAYLOAD_B64"]))
os.makedirs(os.path.dirname(path), exist_ok=True)
data = {"hosts": []}
if os.path.isfile(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except json.JSONDecodeError:
        data = {"hosts": []}
hosts = [
    h for h in data.get("hosts", [])
    if h.get("hostname") != incoming.get("hostname")
    and h.get("install_id") != incoming.get("install_id")
]
hosts.append(incoming)
data["hosts"] = sorted(hosts, key=lambda h: h.get("hostname") or "")
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
print(f"ok: {incoming.get('hostname')} -> {path} ({len(data['hosts'])} host(s))")
PY
