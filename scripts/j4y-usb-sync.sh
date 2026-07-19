#!/usr/bin/env bash
# j4y-usb-sync.sh — refresh J4Y-ROOT content without reformatting
# Usage: ./scripts/j4y-usb-sync.sh [/run/media/j4y/J4Y-ROOT]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$REPO/usb-j4y"
DEST="${1:-/run/media/${USER}/J4Y-ROOT}"

[[ -d "$TEMPLATE" ]] || { echo "missing $TEMPLATE"; exit 1; }
[[ -d "$DEST" ]] || { echo "mount J4Y-ROOT first (expected $DEST)"; exit 1; }

say() { printf '\033[1;35m> %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m  OK\033[0m %s\n' "$*"; }

say "Sync template → $DEST"
rsync -a --delete \
  --exclude '.j4y/logs/' \
  --exclude '.j4y/sessions.tsv' \
  --exclude '.j4y/ceremony.json' \
  "$TEMPLATE/" "$DEST/"

mkdir -p "$DEST/.j4y/logs" "$DEST/public/gpg/pubring" "$DEST/public/age" "$DEST/vault"

CREATED="$(date +%d/%m/%Y)"
REV="$(date +%Y%m%d)"
if [[ -f "$DEST/.j4y/version.json" ]]; then
  CREATED="$(python3 -c "import json; print(json.load(open('$DEST/.j4y/version.json')).get('created','$CREATED'))")"
fi

python3 - <<PY
import json, os
p = os.path.join("$DEST", ".j4y", "version.json")
d = {
    "profile": "j4y",
    "label": "J4Y-ROOT",
    "created": "$CREATED",
    "synced": "$(date +%d/%m/%Y)",
    "revision": int("$REV"),
    "format": "ext4",
}
os.makedirs(os.path.dirname(p), exist_ok=True)
if os.path.isfile(p):
    old = json.load(open(p))
    d["created"] = old.get("created", d["created"])
with open(p, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PY

chmod +x "$DEST/run" "$DEST/bootstrap/"*.sh 2>/dev/null || true
sync
ok "synced — run: cd $DEST && ./run"
