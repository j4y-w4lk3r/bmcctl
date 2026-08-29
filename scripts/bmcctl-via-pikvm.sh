#!/usr/bin/env bash
# bmcctl-via-pikvm — run bmcctl on PiKVM from j4ywa0 over Tailscale.
#
# PiKVM can reach the BMC on the local LAN; your laptop usually cannot when
# you are at the other site. This script SSHes to PiKVM and runs bmcctl there.
#
# PiKVM OS is read-only by default and has no 1Password CLI, so when `op` is
# missing on PiKVM we fetch credentials on j4ywa0 and issue Redfish calls via
# curl on PiKVM (power/info/discover still work; full bmcctl needs op on PiKVM).
#
#   ./scripts/bmcctl-via-pikvm.sh power nas2 status
#   ./scripts/bmcctl-via-pikvm.sh power nas2 on
#   ./scripts/bmcctl-via-pikvm.sh discover --cidr 192.168.1.0/24
#
# Set FORWARD_OP=1 and install `op` on PiKVM to use native bmcctl for all cmds.
set -euo pipefail

PIKVM="${PIKVM:-root@100.64.0.8}"
FORWARD_OP="${FORWARD_OP:-1}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOSTS="${BMCCTL_CONFIG:-$HOME/.config/bmcctl/hosts.json}"

remote_has_op() {
	ssh -o BatchMode=yes "$PIKVM" 'command -v op >/dev/null 2>&1' 2>/dev/null
}

lookup_host() {
	local label=$1 field=$2
	python3 - "$label" "$field" "$HOSTS" <<'PY'
import json, sys
label, field, path = sys.argv[1:4]
data = json.load(open(path))
for h in data.get("hosts", []):
    if h.get("label", "").lower() == label.lower():
        print(h.get(field, ""))
        break
PY
}

run_with_local_op() {
	local cmd=$1 label=$2
	local host uuid user pass
	host=$(lookup_host "$label" host)
	uuid=$(lookup_host "$label" op_item_uuid)
	[[ -n $host && -n $uuid ]] || {
		echo "bmcctl-via-pikvm: label $label not in $HOSTS" >&2
		exit 1
	}
	# shellcheck disable=SC1091
	eval "$("$REPO_ROOT/scripts/op-ensure-auth.sh" export 2>/dev/null || true)"
	user=$(op item get "$uuid" --fields username --reveal)
	pass=$(op item get "$uuid" --fields password --reveal)
	case "$cmd" in
	status)
		ssh "$PIKVM" "curl -sk -u $(printf '%q:%q' "$user" "$pass") https://${host}/redfish/v1/Systems/Self" |
			python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('PowerState','?'))"
		;;
	on)
		ssh "$PIKVM" "curl -sk -u $(printf '%q:%q' "$user" "$pass") -X POST -H 'Content-Type: application/json' -d '{\"ResetType\":\"On\"}' https://${host}/redfish/v1/Systems/Self/Actions/ComputerSystem.Reset" >/dev/null
		echo "power on sent to $host"
		;;
	off)
		ssh "$PIKVM" "curl -sk -u $(printf '%q:%q' "$user" "$pass") -X POST -H 'Content-Type: application/json' -d '{\"ResetType\":\"ForceOff\"}' https://${host}/redfish/v1/Systems/Self/Actions/ComputerSystem.Reset" >/dev/null
		echo "power off sent to $host"
		;;
	*)
		echo "bmcctl-via-pikvm: local-op fallback only supports power <label> status|on|off" >&2
		exit 1
		;;
	esac
}

if [[ $# -ge 3 && ${1:-} == power && ${3:-} =~ ^(status|on|off)$ ]] && ! remote_has_op; then
	run_with_local_op "${3}" "${2}"
	exit 0
fi

env_prefix=""
if [[ $FORWARD_OP == 1 ]] && [[ -f "$REPO_ROOT/scripts/op-ensure-auth.sh" ]]; then
	# shellcheck disable=SC1091
	eval "$("$REPO_ROOT/scripts/op-ensure-auth.sh" export 2>/dev/null || true)"
	for var in OP_ACCOUNT OP_BIOMETRIC_UNLOCK_ENABLED OP_SERVICE_ACCOUNT_TOKEN; do
		[[ -n ${!var:-} ]] && env_prefix+="export ${var}=$(printf %q "${!var}"); "
	done
	while IFS= read -r name; do
		[[ -n $name ]] || continue
		env_prefix+="export ${name}=$(printf %q "${!name}"); "
	done < <(compgen -v | grep -E '^OP_SESSION_' || true)
fi

if [[ -n $env_prefix ]]; then
	exec ssh -t "$PIKVM" "${env_prefix}bmcctl $(printf ' %q' "$@")"
fi

exec ssh -t "$PIKVM" bmcctl "$@"
