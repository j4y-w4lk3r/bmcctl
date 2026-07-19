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
#   5. Headscale: mint single-use preauth key + one-shot HTTP serve.
#   6. Hand off to `bmcctl install-arch <label> --iso nfs://...`.
#   7. Post-install cleanup: eject ISO, clear boot override, power on.
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
  NO_COLOR=1     disable ANSI colours in the progress UI
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
LOG_DIR=$SCRIPT_DIR/logs
[[ -f "$TOML" ]] || { echo "no host config at $TOML" >&2; exit 64; }

# shellcheck source=lib/progress.sh
source "$SCRIPT_DIR/lib/progress.sh"

_headscale_enabled() {
	python3 - "$TOML" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    doc = tomllib.load(f)
print(doc.get("headscale", {}).get("enabled", False))
PY
}

HS_ON=0
[[ $(_headscale_enabled) == True ]] && HS_ON=1

EST_ISO=10
[[ $REBUILD -eq 1 || ! -f $OUT_DIR/$LABEL.iso ]] && EST_ISO=720
EST_HEADSCALE=0
[[ $HS_ON -eq 1 ]] && EST_HEADSCALE=30
EST_TOTAL=$(( 15 + 45 + EST_ISO + 25 + EST_HEADSCALE + WAIT_MIN * 60 + 20 ))
PROG_STEPS=7

mkdir -p "$LOG_DIR"
RUN_LOG=$LOG_DIR/install-host-${LABEL}-$(date -u +%Y%m%dT%H%M%SZ).log
exec > >(tee -a "$RUN_LOG") 2>&1

prog_init "$LABEL" "$PROG_STEPS" "$EST_TOTAL"
echo "log: $RUN_LOG"

# --------- headscale helpers ----------------------------------------

HS_KEY_SERVER_PID=""
HS_KEY_FILE=""

_stop_headscale_key_server() {
	[[ -n $HS_KEY_SERVER_PID ]] && kill "$HS_KEY_SERVER_PID" 2>/dev/null || true
	wait "$HS_KEY_SERVER_PID" 2>/dev/null || true
	if [[ -n $HS_KEY_FILE && -f $HS_KEY_FILE ]]; then
		shred -u "$HS_KEY_FILE" 2>/dev/null || rm -f "$HS_KEY_FILE"
	fi
	HS_KEY_SERVER_PID=""
	HS_KEY_FILE=""
}

_mint_headscale_key() {
	local exp="${HEADSCALE_KEY_EXPIRY:-1h}" vps_pw key
	prog_detail "minting single-use preauth key on Headscale VPS"
	vps_pw="${VPS_PW:-}"
	if [[ -z $vps_pw ]]; then
		vps_pw=$(op read "op://sut52ivubicrrzzp3sxd4g4wru/cbairpbkfyosp3c2qh6bqywdci/password" 2>/dev/null) || true
	fi
	[[ -n $vps_pw ]] || prog_die "headscale enabled but could not read VPS password from 1Password" 2
	key=$(sshpass -p "$vps_pw" ssh -o StrictHostKeyChecking=accept-new j4y@187.127.72.54 \
		"echo '$vps_pw' | sudo -S headscale preauthkeys create --user 1 --expiration ${exp} -o json 2>/dev/null" \
		| python3 -c 'import json,sys; print(json.load(sys.stdin).get("key",""))' 2>/dev/null) || true
	[[ -n $key && $key == hskey-auth-* ]] || prog_die "failed to mint Headscale preauth key on VPS" 2
	HEADSCALE_AUTHKEY="$key"
	prog_ok "single-use Headscale key minted (expires ${exp})"
}

_serve_headscale_key_once() {
	local bind_ip=$1 port="${HEADSCALE_KEY_PORT:-9765}"
	[[ -n $bind_ip && -n ${HEADSCALE_AUTHKEY:-} ]] || prog_die "headscale key server: missing bind IP or key" 2
	HS_KEY_FILE=$(mktemp)
	chmod 600 "$HS_KEY_FILE"
	printf '%s' "$HEADSCALE_AUTHKEY" >"$HS_KEY_FILE"
	unset HEADSCALE_AUTHKEY
	prog_detail "HTTP one-shot server on ${bind_ip}:${port}"
	python3 - "$bind_ip" "$port" "$HS_KEY_FILE" <<'PY' &
import socketserver, sys, http.server
bind, port, path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
class Handler(http.server.BaseHTTPRequestHandler):
    served = False
    def do_GET(self):
        if self.path not in ("/", "/headscale-key"):
            self.send_error(404)
            return
        if Handler.served:
            self.send_error(410)
            return
        Handler.served = True
        with open(path, "rb") as fh:
            body = fh.read()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
class Server(socketserver.TCPServer):
    allow_reuse_address = True
with Server((bind, port), Handler) as httpd:
    httpd.timeout = 3600
    while not Handler.served:
        httpd.handle_request()
PY
	HS_KEY_SERVER_PID=$!
	prog_ok "serving key at http://${bind_ip}:${port}/headscale-key (until installer fetches it)"
}

# --------- step 1: resolve label ------------------------------------

prog_begin_step 15 "Resolve label + bmcctl registry"
ENTRY_JSON=$("$BMCCTL" ls 2>/dev/null | awk -v L="$LABEL" 'tolower($1)==tolower(L){print $0}')
[[ -n "$ENTRY_JSON" ]] || prog_die "label '$LABEL' not in bmcctl registry — run bmcctl init/adopt first" 64
BMC_IP=$(echo "$ENTRY_JSON" | awk '{print $2}')
prog_ok "BMC $LABEL → $BMC_IP"
prog_end_step 15

# --------- step 2: AMI pre-flight (idempotent) ----------------------

prog_begin_step 45 "BMC pre-flight (virtual media)"
prog_detail "checking BMC reachability"
"$BMCCTL" info "$LABEL" >/dev/null || prog_die "BMC $BMC_IP not reachable" 2

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
[[ -n "$PW" ]] || prog_die "could not resolve BMC password (op signin or BMC_PW=)" 2

prog_detail "EnableRMedia + ConfigureCDInstance"
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
[[ "$CD_COUNT" -ge 1 ]] || prog_die "BMC exposes 0 VirtualMedia slots after pre-flight" 2
prog_ok "$CD_COUNT VirtualMedia slot(s) ready"
prog_end_step 45

ISO_HOST_IP=${ISO_HOST_IP:-$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')}
ISO_HOST_PATH=${ISO_HOST_PATH:-$OUT_DIR}

# --------- step 3: build / locate ISO -------------------------------

prog_begin_step "$EST_ISO" "Build installer ISO"
ISO_PATH=$OUT_DIR/$LABEL.iso
if [[ ! -f "$ISO_PATH" || $REBUILD -eq 1 ]]; then
	[[ -n $ISO_HOST_IP ]] || prog_die "set ISO_HOST_IP=... (could not auto-detect LAN IP)" 3
	prog_detail "make iso HOST=$LABEL (mkarchiso — this is the slow part)"
	prog_start_tick
	(cd "$SCRIPT_DIR" && HEADSCALE_KEY_FETCH_HOST="$ISO_HOST_IP" make iso HOST="$LABEL") \
		|| prog_die "make iso failed" 3
	prog_stop_tick
else
	prog_detail "reusing existing $(basename "$ISO_PATH")"
fi
[[ -f "$ISO_PATH" ]] || prog_die "ISO not found at $ISO_PATH" 3
REAL_ISO=$(readlink -f "$ISO_PATH")
prog_ok "ISO ready: $(basename "$REAL_ISO") ($(du -h "$REAL_ISO" | cut -f1))"
prog_end_step "$EST_ISO"

# --------- step 4: NFS export reachable -----------------------------

prog_begin_step 25 "NFS export for BMC virtual media"
[[ -n "$ISO_HOST_IP" ]] || prog_die "set ISO_HOST_IP=..." 4

if ! sudo exportfs -v 2>/dev/null | grep -q "$ISO_HOST_PATH"; then
	prog_warn "configuring nfs-server export for $ISO_HOST_PATH"
	command -v exportfs >/dev/null || sudo pacman -S --noconfirm --needed nfs-utils
	echo "$ISO_HOST_PATH 192.168.0.0/16(ro,no_subtree_check,all_squash,insecure)" | sudo tee -a /etc/exports >/dev/null
	sudo exportfs -ra
	sudo systemctl enable --now nfs-server
fi
prog_ok "NFS export: $ISO_HOST_IP:$ISO_HOST_PATH"
NFS_URL="nfs://$ISO_HOST_IP$ISO_HOST_PATH/$LABEL.iso"
prog_end_step 25

# --------- step 5: Headscale single-use key -------------------------

prog_begin_step "$EST_HEADSCALE" "Headscale preauth key (single-use)"
if [[ $HS_ON -eq 1 ]]; then
	trap _stop_headscale_key_server EXIT
	_mint_headscale_key
	_serve_headscale_key_once "$ISO_HOST_IP"
else
	prog_ok "headscale disabled in TOML — skipped"
fi
prog_end_step "$EST_HEADSCALE"

# --------- step 6: install-arch -------------------------------------

prog_begin_step $((WAIT_MIN * 60)) "bmcctl install-arch (unattended install, --wait ${WAIT_MIN}m)"
prog_detail "mount ISO → boot CD → power on → wait for install"
INSTALL_OK=1
if ! prog_run_logged "$RUN_LOG.install-arch" \
	"$BMCCTL" install-arch "$LABEL" --iso "$NFS_URL" --wait "$WAIT_MIN"; then
	INSTALL_OK=0
fi
prog_end_step $((WAIT_MIN * 60))

# --------- step 7: cleanup ------------------------------------------

prog_begin_step 20 "Post-install cleanup"

if [[ $NO_CLEANUP -eq 1 ]]; then
	prog_warn "--no-cleanup: leaving ISO mounted + boot override set"
	[[ $INSTALL_OK -eq 1 ]] || prog_warn "install-arch did NOT confirm completion"
	prog_end_step 20
	prog_finish
	exit 0
fi

if [[ $INSTALL_OK -eq 1 ]]; then
	prog_detail "eject ISO, clear boot override, power on"
	"$BMCCTL" eject-iso "$LABEL" --slot CD1 || prog_warn "eject-iso failed (non-fatal)"
	"$BMCCTL" boot "$LABEL" none || prog_warn "boot none failed (non-fatal)"
	"$BMCCTL" power "$LABEL" on
	prog_ok "host powered on — booting from disk"
	prog_end_step 20
	prog_finish
	echo "next: ssh j4y@<dhcp-ip>   (key: homelab-ssh-key ensure, or ~/.ssh/id_ed25519)"
	echo "      bmcctl kvm $LABEL    (watch first boot)"
	[[ $HS_ON -eq 1 ]] && echo "      tailscale status   (nas should appear after first-boot join)"
	exit 0
fi

prog_warn "install-arch timed out after ${WAIT_MIN}m"
prog_detail "safe de-landmine: clear boot override + eject ISO"
"$BMCCTL" boot "$LABEL" none || prog_warn "boot none failed (non-fatal)"
"$BMCCTL" eject-iso "$LABEL" --slot CD1 || prog_warn "eject-iso failed (non-fatal)"
prog_fail
prog_die "install not confirmed — inspect via bmcctl kvm $LABEL, then re-run install-host.sh" 1
