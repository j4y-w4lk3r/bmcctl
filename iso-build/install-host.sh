#!/usr/bin/env bash
# install-host — one-shot wrapper around the full bring-up pipeline.
#
# Replays everything we did manually for the first router install:
#
#   1. Resolve <label> -> hosts/<label>.toml + bmcctl host registry entry.
#   2. Pre-flight the BMC (AMI MegaRAC quirks):
#        - POST .../EnableRMedia       (no-op if already enabled)
#        - POST .../ConfigureCDInstance(1)  (no-op if already 1+)
#      Both actions are idempotent on AMI; redoing them costs nothing
#      but the first time on a fresh BMC is mandatory or the
#      VirtualMedia collection stays empty.
#   3. Build the ISO if missing (or with --rebuild even if present).
#      Produces out/<label>.iso (a single-dot symlink) so AMI's URL
#      parser doesn't choke on the date-stamped filename.
#   4. Make sure an NFS export covering iso-build/out/ is up on the
#      build host and reachable from the BMC's LAN. We assume the
#      build host is the local machine; for cross-host setups, set
#      ISO_HOST_IP and ISO_HOST_PATH in the env or as flags.
#   5. Hand off to `bmcctl install-arch <label> --iso nfs://...`.
#      That orchestrates eject + insert + boot=cd/once + power
#      (state-aware: Off->On, On->PowerCycle) and waits for the
#      canonical On->Off transition.
#   6. Post-install cleanup:
#        - eject the ISO from CD1
#        - clear the boot override
#        - power the host back on so it boots from disk
#
# Usage:
#   ./install-host.sh router
#   ./install-host.sh router --rebuild       # force rebuild of the ISO
#   ./install-host.sh router --no-cleanup    # keep ISO mounted + leave host off
#   ISO_HOST_IP=192.168.1.44 ./install-host.sh router
#
# Exit codes:
#   0   install completed (PowerState reached Off after On)
#   1   bmcctl said no
#   2   pre-flight (RMedia / slot config) failed
#   3   ISO build failed
#   4   NFS export not reachable

set -euo pipefail

# --------- arg parsing ----------------------------------------------

LABEL=""
REBUILD=0
NO_CLEANUP=0
WAIT_MIN=30

usage() {
	cat <<USAGE
usage: install-host.sh <label> [--rebuild] [--no-cleanup] [--wait MIN]

Reads:
  iso-build/hosts/<label>.toml
  bmcctl host registry (~/.config/bmcctl or platform-specific path)

Env overrides:
  ISO_HOST_IP    NFS server IP the BMC will pull from (default: this
                 machine's primary LAN address as detected by route)
  ISO_HOST_PATH  Absolute path on the NFS server where ISOs live
                 (default: \$(pwd)/out)
  BMCCTL         Path to the bmcctl binary (default: 'bmcctl' on PATH)
USAGE
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--rebuild)    REBUILD=1; shift ;;
		--no-cleanup) NO_CLEANUP=1; shift ;;
		--wait)       WAIT_MIN="$2"; shift 2 ;;
		-h|--help)    usage; exit 0 ;;
		-*)           echo "unknown flag: $1" >&2; usage >&2; exit 64 ;;
		*)            if [[ -z "$LABEL" ]]; then LABEL="$1"; shift
		              else echo "unexpected arg: $1" >&2; usage >&2; exit 64
		              fi ;;
	esac
done

[[ -n "$LABEL" ]] || { usage >&2; exit 64; }

BMCCTL=${BMCCTL:-bmcctl}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT_DIR=$SCRIPT_DIR/out
TOML=$SCRIPT_DIR/hosts/$LABEL.toml
[[ -f "$TOML" ]] || { echo "no host config at $TOML" >&2; exit 64; }

# --------- helpers --------------------------------------------------

step()  { printf '\n\033[1;36m::: %s\033[0m\n' "$*"; }
ok()    { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit "${2:-1}"; }

# --------- step 1: resolve label ------------------------------------

step "resolving $LABEL"
ENTRY_JSON=$("$BMCCTL" ls 2>/dev/null | awk -v L="$LABEL" 'tolower($1)==tolower(L){print $0}')
[[ -n "$ENTRY_JSON" ]] || die "label '$LABEL' not in bmcctl registry — run \`bmcctl init\` or \`bmcctl adopt\` first" 64
BMC_IP=$(echo "$ENTRY_JSON" | awk '{print $2}')
ok "BMC label=$LABEL ip=$BMC_IP"

# --------- step 2: AMI pre-flight (idempotent) ----------------------

step "BMC pre-flight: enable RMedia + configure 1+ CD slot"
"$BMCCTL" info "$LABEL" >/dev/null || die "BMC $BMC_IP not reachable" 2

# Both actions return 200/202 with a "DelayInActionCompletion" message
# on first run, and a similarly benign error on no-op. We don't parse
# the response; we just verify a CD slot exists afterwards.
#
# We need the plaintext password for these raw OEM curl calls. Read it
# from the registry's op_vault/op_item_uuid via `op read` — the op://
# reference carries the vault, so this works for both interactive and
# service-account sessions. An explicit BMC_PW env always wins.
PW="${BMC_PW:-}"
if [[ -z "$PW" ]]; then
	REG=""
	for cand in "${BMCCTL_CONFIG:-}" \
	            "${XDG_CONFIG_HOME:-$HOME/.config}/bmcctl/hosts.json" \
	            "$HOME/.config/bmcctl/hosts.json" \
	            "$HOME/Library/Application Support/bmcctl/hosts.json"; do
		[[ -n "$cand" && -f "$cand" ]] && { REG="$cand"; break; }
	done
	if [[ -n "$REG" ]]; then
		PW_REF=$(LABEL="$LABEL" python3 -c 'import json,os,sys
d=json.load(open(sys.argv[1]))
for h in d.get("hosts",[]):
    if h.get("label","").lower()==os.environ["LABEL"].lower():
        v=h.get("op_vault",""); u=h.get("op_item_uuid","")
        if v and u: print(f"op://{v}/{u}/password")
        break' "$REG" 2>/dev/null || true)
		[[ -n "$PW_REF" ]] && PW=$(op read "$PW_REF" 2>/dev/null || true)
	fi
fi
[[ -n "$PW" ]] || die "could not resolve BMC password — set BMC_PW=<pw> or ensure op is authed (OP_SERVICE_ACCOUNT_TOKEN or \`op signin\`) and the registry has op_vault+op_item_uuid for $LABEL" 2

curl -ksu "admin:$PW" -X POST -H 'Content-Type: application/json' \
	-d '{"RMediaState":"Enable"}' \
	"https://$BMC_IP/redfish/v1/Managers/Self/Actions/Oem/AMIVirtualMedia.EnableRMedia" \
	>/dev/null 2>&1 || true
curl -ksu "admin:$PW" -X POST -H 'Content-Type: application/json' \
	-d '{"CDInstance":1}' \
	"https://$BMC_IP/redfish/v1/Managers/Self/Actions/Oem/AMIVirtualMedia.ConfigureCDInstance" \
	>/dev/null 2>&1 || true
sleep 5

CD_COUNT=$(curl -ksu "admin:$PW" "https://$BMC_IP/redfish/v1/Managers/Self/VirtualMedia" 2>/dev/null \
	| python3 -c 'import json,sys; print(json.load(sys.stdin).get("Members@odata.count",0))')
[[ "$CD_COUNT" -ge 1 ]] || die "after EnableRMedia/ConfigureCDInstance the BMC still exposes 0 VirtualMedia slots" 2
ok "BMC reports $CD_COUNT VirtualMedia slot(s)"

# --------- step 3: build / locate ISO -------------------------------

ISO_PATH=$OUT_DIR/$LABEL.iso
if [[ ! -f "$ISO_PATH" || $REBUILD -eq 1 ]]; then
	step "building ISO (make iso HOST=$LABEL)"
	(cd "$SCRIPT_DIR" && make iso HOST="$LABEL") || die "make iso failed" 3
fi
[[ -f "$ISO_PATH" ]] || die "ISO not built and no out/$LABEL.iso symlink" 3
REAL_ISO=$(readlink -f "$ISO_PATH")
ok "ISO ready: $(basename "$REAL_ISO") ($(du -h "$REAL_ISO" | cut -f1))"

# --------- step 4: NFS export reachable -----------------------------

step "verifying NFS export"
ISO_HOST_IP=${ISO_HOST_IP:-$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')}
ISO_HOST_PATH=${ISO_HOST_PATH:-$OUT_DIR}
[[ -n "$ISO_HOST_IP" ]] || die "could not auto-detect this host's LAN IP; set ISO_HOST_IP=..." 4

if ! sudo exportfs -v 2>/dev/null | grep -q "$ISO_HOST_PATH"; then
	warn "no NFS export covering $ISO_HOST_PATH — installing/configuring nfs-server"
	command -v exportfs >/dev/null || sudo pacman -S --noconfirm --needed nfs-utils
	echo "$ISO_HOST_PATH 192.168.0.0/16(ro,no_subtree_check,all_squash,insecure)" | sudo tee -a /etc/exports >/dev/null
	sudo exportfs -ra
	sudo systemctl enable --now nfs-server
fi
ok "NFS export live: $ISO_HOST_IP:$ISO_HOST_PATH"
NFS_URL="nfs://$ISO_HOST_IP$ISO_HOST_PATH/$LABEL.iso"

# --------- step 5: install-arch -------------------------------------

step "bmcctl install-arch $LABEL --iso $NFS_URL --wait $WAIT_MIN"
INSTALL_OK=1
"$BMCCTL" install-arch "$LABEL" --iso "$NFS_URL" --wait "$WAIT_MIN" || INSTALL_OK=0

# --------- step 6: cleanup ------------------------------------------
#
# Two distinct outcomes, and BOTH must clear the boot override. Leaving
# a "boot from CD (Continuous)" override + a mounted installer ISO on a
# host is a re-wipe landmine: the very next reboot re-runs the unattended
# installer and nukes the disk. install-arch confirming completion is the
# happy path; if it could NOT confirm (the wait timed out), we still tear
# down the override so an unattended box can never re-wipe itself — we
# just don't power-cycle, so an operator can inspect via SOL.

if [[ $NO_CLEANUP -eq 1 ]]; then
	warn "--no-cleanup: leaving ISO mounted, boot override set, host as-is"
	[[ $INSTALL_OK -eq 1 ]] || warn "(note: install-arch did NOT confirm completion)"
	exit 0
fi

if [[ $INSTALL_OK -eq 1 ]]; then
	step "cleanup: eject + clear boot + power on"
	"$BMCCTL" eject-iso "$LABEL" --slot CD1 || warn "eject-iso failed (non-fatal)"
	"$BMCCTL" boot "$LABEL" none || warn "boot none failed (non-fatal)"
	"$BMCCTL" power "$LABEL" on
	ok "host powered on; boot from disk imminent"
	echo
	echo "next: ssh into the new host once it DHCPs (try \`avahi-resolve -n4 $LABEL.local\` if mDNS is on it,"
	echo "      or scan the LAN — the install embedded \$HOME/.ssh/id_ed25519.pub)"
	exit 0
fi

# install-arch could not confirm completion. Defuse the landmine without
# disturbing a possibly-still-running install: clear the boot override
# (only affects the NEXT boot) and eject the media, but do NOT power-cycle.
warn "install-arch did not confirm completion within --wait $WAIT_MIN min"
step "safe de-landmine: clearing boot override + ejecting ISO (no power change)"
"$BMCCTL" boot "$LABEL" none || warn "boot none failed (non-fatal)"
"$BMCCTL" eject-iso "$LABEL" --slot CD1 || warn "eject-iso failed (non-fatal)"
die "could not confirm install completion — boot override cleared so the host
    cannot re-wipe itself on reboot. Inspect via SOL/KVM (the installer drops to
    a root shell on failure), then re-run \`install-host.sh $LABEL --rebuild\` if needed." 1
