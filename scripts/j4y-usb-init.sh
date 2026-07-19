#!/usr/bin/env bash
# j4y-usb-init.sh — format removable disk as J4Y-ROOT (ext4) + sync template
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="${J4Y_USB_LABEL:-J4Y-ROOT}"

say()  { printf '\033[1;35m> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  OK\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m  %s\n' "$*"; }
die()  { warn "$*"; exit 1; }

[[ "$(id -u)" -eq 0 ]] && die "Run as normal user."

pick_device() {
  [[ -n "${1:-}" ]] && { echo "$1"; return; }
  lsblk -dpno NAME,TYPE,RM | awk '$2=="disk" && $3==1 {print $1; exit}'
}

DEV="${1:-$(pick_device)}"
[[ -b "$DEV" ]] || die "No device. Usage: $0 /dev/sdX"
say "Device: $DEV"
lsblk "$DEV" || true
echo
read -r -p "Type YES to erase $DEV as ${LABEL}: " confirm
[[ "$confirm" == YES ]] || die "Aborted."

say "Formatting ext4…"
sudo wipefs -a "$DEV"
sudo parted -s "$DEV" mklabel gpt mkpart primary ext4 1MiB 100%
PART="${DEV}1"
[[ -b "$PART" ]] || PART="${DEV}p1"
sudo mkfs.ext4 -F -L "$LABEL" "$PART"

sudo mkdir -p /mnt/j4y-usb-init
sudo mount "$PART" /mnt/j4y-usb-init
sudo chown -R "$(id -u):$(id -g)" /mnt/j4y-usb-init

CREATED="$(date +%d/%m/%Y)"
mkdir -p /mnt/j4y-usb-init/.j4y/logs
python3 - <<PY
import json
json.dump({
    "profile": "j4y",
    "label": "$LABEL",
    "created": "$CREATED",
    "synced": "$CREATED",
    "revision": 1,
    "format": "ext4",
}, open("/mnt/j4y-usb-init/.j4y/version.json", "w"), indent=2)
open("/mnt/j4y-usb-init/.j4y/version.json", "a").write("\n")
PY

bash "$REPO/scripts/j4y-usb-sync.sh" /mnt/j4y-usb-init

sync
sudo umount /mnt/j4y-usb-init
ok "Done. Label=$LABEL — plug in → cd .../J4Y-ROOT → ./run"
