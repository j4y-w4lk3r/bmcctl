#!/usr/bin/env bash
# install-pikvm — cross-compile bmcctl for PiKVM (aarch64) and install on the box.
#
# PiKVM sits on the same LAN as the ASRock BMC, so it is the right place to
# run bmcctl for remote sites (e.g. Warsaw PLH1). Your laptop talks Tailscale
# to PiKVM; PiKVM talks Redfish to the BMC on 192.168.1.x.
#
# Usage (from a machine with Go + ssh to PiKVM):
#   ./scripts/install-pikvm.sh
#   PIKVM=root@100.64.0.8 ./scripts/install-pikvm.sh
#   ./scripts/install-pikvm.sh --hosts ~/.config/bmcctl/hosts.json
#
# After install, run bmcctl on PiKVM:
#   ssh root@pikvm1 bmcctl ls
#   ssh root@pikvm1 bmcctl power nas2 status
#
# Secrets still come from 1Password via `op` — install/sign in on PiKVM, or use
# scripts/bmcctl-via-pikvm.sh from j4ywa0 (forwards op session over SSH).
set -euo pipefail

PIKVM="${PIKVM:-root@100.64.0.8}"
HOSTS_SRC="${HOSTS_SRC:-$HOME/.config/bmcctl/hosts.json}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="/usr/local/bin/bmcctl"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

usage() {
	sed -n '2,20p' "$0" | sed -E 's/^# ?//'
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help) usage; exit 0 ;;
	--hosts)
		shift
		HOSTS_SRC=${1:?--hosts requires a path}
		shift
		;;
	*) echo "install-pikvm: unknown arg: $1" >&2; exit 2 ;;
	esac
done

echo "install-pikvm: building linux/arm64 from $REPO_ROOT"
(
	cd "$REPO_ROOT"
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags="-s -w" -o "$TMP" ./cmd/bmcctl
)

echo "install-pikvm: ensuring PiKVM root is read-write (pikvm rw)"
ssh "$PIKVM" "rw >/dev/null 2>&1 || mount -o remount,rw / 2>/dev/null || true"

echo "install-pikvm: installing to $PIKVM:$BIN"
ssh "$PIKVM" "mkdir -p /root/.config/bmcctl"
scp -q "$TMP" "$PIKVM:$BIN"
ssh "$PIKVM" "chmod 755 $BIN && $BIN -version 2>/dev/null || $BIN ls 2>&1 | head -1 || true"

if [[ -f $HOSTS_SRC ]]; then
	echo "install-pikvm: copying hosts registry from $HOSTS_SRC"
	scp -q "$HOSTS_SRC" "$PIKVM:/root/.config/bmcctl/hosts.json"
else
	echo "install-pikvm: no $HOSTS_SRC — create one with bmcctl init/adopt first"
fi

echo "install-pikvm: done"
echo "  ssh $PIKVM bmcctl ls"
echo "  ssh $PIKVM bmcctl power nas2 status"
