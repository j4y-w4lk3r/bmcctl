#!/usr/bin/env bash
# ceremony.sh — JSON checklist for j4y key ceremony
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/j4y-lib.sh
source "$ROOT/bootstrap/lib/j4y-lib.sh"

CEREMONY_JSON="$ROOT/.j4y/ceremony.json"

ceremony_init() {
  mkdir -p "$ROOT/.j4y"
  [[ -f "$CEREMONY_JSON" ]] && return 0
  cat >"$CEREMONY_JSON" <<'JSON'
{
  "profile": "j4y",
  "updated": "",
  "steps": [
    {"id": "keys_present", "title": "Bio + Mini-C plugged in and detected", "done": false, "done_at": null},
    {"id": "token2_setup", "title": "token2-linux-setup.sh (pcscd, udev, age plugin)", "done": false, "done_at": null},
    {"id": "fido_pins", "title": "FIDO PIN set on Bio and Mini (not factory defaults)", "done": false, "done_at": null},
    {"id": "openpgp_bio", "title": "OpenPGP subkeys on Bio (FIDO+PGP applet mode)", "done": false, "done_at": null},
    {"id": "openpgp_clone", "title": "OpenPGP subkeys cloned to Mini (safe backup)", "done": false, "done_at": null},
    {"id": "openpgp_pin", "title": "OpenPGP user PIN changed from factory 123456", "done": false, "done_at": null},
    {"id": "age_bio", "title": "age identity on Bio (token2 bio-setup)", "done": false, "done_at": null},
    {"id": "age_mini", "title": "Second age identity on Mini (dual-recipient backups)", "done": false, "done_at": null},
    {"id": "age_test", "title": "Test vault/test.age encrypted to both recipients", "done": false, "done_at": null},
    {"id": "fido_backup", "title": "Mini registered as backup FIDO on a test account", "done": false, "done_at": null},
    {"id": "pubkeys_usb", "title": "Public keys only copied to public/gpg and public/age", "done": false, "done_at": null}
  ]
}
JSON
  ceremony_touch
}

ceremony_touch() {
  python3 - <<PY
import json, datetime
p = "$CEREMONY_JSON"
with open(p) as f: d = json.load(f)
d["updated"] = datetime.datetime.now().strftime("%d/%m/%Y %H:%M")
with open(p, "w") as f: json.dump(d, f, indent=2)
PY
}

ceremony_status() {
  ceremony_init
  python3 - <<PY
import json
with open("$CEREMONY_JSON") as f: d = json.load(f)
done = sum(1 for s in d["steps"] if s["done"])
total = len(d["steps"])
print(f"ceremony j4y — {done}/{total}  (updated {d.get('updated','?')})")
print()
for s in d["steps"]:
    mark = "x" if s["done"] else " "
    at = f"  [{s['done_at']}]" if s.get("done_at") else ""
    print(f"  [{mark}] {s['id']}: {s['title']}{at}")
PY
}

ceremony_done() {
  local id="${1:?step id}"
  ceremony_init
  python3 - <<PY
import json, datetime
id_ = "$id"
with open("$CEREMONY_JSON") as f: d = json.load(f)
found = False
for s in d["steps"]:
    if s["id"] == id_:
        s["done"] = True
        s["done_at"] = datetime.datetime.now().strftime("%d/%m/%Y %H:%M")
        found = True
        break
if not found:
    raise SystemExit(f"unknown step: {id_}")
d["updated"] = datetime.datetime.now().strftime("%d/%m/%Y %H:%M")
with open("$CEREMONY_JSON", "w") as f: json.dump(d, f, indent=2)
print(f"done: {id_}")
PY
}

ceremony_undo() {
  local id="${1:?step id}"
  ceremony_init
  python3 - <<PY
import json, datetime
id_ = "$id"
with open("$CEREMONY_JSON") as f: d = json.load(f)
for s in d["steps"]:
    if s["id"] == id_:
        s["done"] = False
        s["done_at"] = None
        break
else:
    raise SystemExit(f"unknown step: {id_}")
d["updated"] = datetime.datetime.now().strftime("%d/%m/%Y %H:%M")
with open("$CEREMONY_JSON", "w") as f: json.dump(d, f, indent=2)
print(f"undo: {id_}")
PY
}

ceremony_auto_keys() {
  j4y_check_keys
  if [[ "$J4Y_KEY_BIO" -ge 1 && "$J4Y_KEY_MINI" -ge 1 ]]; then
    ceremony_done keys_present 2>/dev/null || true
  fi
}

usage() {
  cat <<'EOF'
ceremony.sh — j4y key ceremony (JSON in .j4y/ceremony.json)

  ceremony.sh status
  ceremony.sh done <step-id>
  ceremony.sh undo <step-id>
  ceremony.sh auto          detect keys → mark keys_present if both seen
EOF
}

cmd="${1:-status}"
case "$cmd" in
  status|list) ceremony_status ;;
  done) ceremony_done "${2:?id}" ;;
  undo) ceremony_undo "${2:?id}" ;;
  auto) ceremony_auto_keys; ceremony_status ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
