# j4y-lib.sh — shared helpers for J4Y-ROOT (source only)
# Portable bash; no secrets. Works on Arch and most Linux.

[[ -n "${_J4Y_LIB_LOADED:-}" ]] && return 0
_J4Y_LIB_LOADED=1

J4Y_VENDOR_ID="${J4Y_VENDOR_ID:-349e}"

j4y_say()  { printf '\033[1;35m> %s\033[0m\n' "$*"; }
j4y_ok()   { printf '\033[1;32m  OK\033[0m %s\n' "$*"; }
j4y_warn() { printf '\033[1;33m  !\033[0m  %s\n' "$*"; }
j4y_fail() { printf '\033[1;31m  NO\033[0m %s\n' "$*"; }

# Resolve USB root (directory containing .j4y/)
j4y_find_root() {
  local d="${1:-$(pwd)}"
  while [[ "$d" != "/" ]]; do
    [[ -d "$d/.j4y" ]] && { printf '%s\n' "$d"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

j4y_date_display() {
  date +%d/%m/%Y
}

j4y_timestamp() {
  date +%Y-%m-%dT%H:%M:%S%z
}

j4y_log_file() {
  local root="$1"
  mkdir -p "$root/.j4y/logs"
  printf '%s/.j4y/logs/%s.log\n' "$root" "$(date +%d-%m-%Y_%H-%M-%S)"
}

j4y_log_init() {
  local root="$1"
  j4y_log_file "$root"
}

j4y_log() {
  local root="$1" msg="$2" log="${3:-}"
  [[ -n "$log" ]] || return 0
  printf '[%s] %s\n' "$(j4y_timestamp)" "$msg" >>"$log"
}

j4y_session_append() {
  local root="$1" event="$2" log="$3"
  mkdir -p "$root/.j4y"
  printf '%s\t%s\t%s\n' "$(j4y_timestamp)" "$event" "$log" >>"$root/.j4y/sessions.tsv"
}

# Is this block device / mount J4Y-ROOT?
j4y_usb_mounted() {
  local root="$1"
  local dev mount label
  mount="$(findmnt -n -o SOURCE --target "$root" 2>/dev/null || true)"
  [[ -n "$mount" ]] || return 1
  label="$(lsblk -no LABEL "$mount" 2>/dev/null || true)"
  [[ "$label" == "J4Y-ROOT" ]] && return 0
  [[ -f "$root/.j4y/version.json" ]] && return 0
  return 1
}

j4y_count_token2_usb() {
  lsusb -d "${J4Y_VENDOR_ID}:" 2>/dev/null | wc -l
}

j4y_token2_usb_lines() {
  lsusb -d "${J4Y_VENDOR_ID}:" 2>/dev/null || true
}

j4y_classify_keys() {
  # Sets: J4Y_KEY_BIO J4Y_KEY_MINI J4Y_KEY_COUNT J4Y_KEY_OTHER
  J4Y_KEY_BIO=0 J4Y_KEY_MINI=0 J4Y_KEY_OTHER=0 J4Y_KEY_COUNT=0
  local line low
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    (( J4Y_KEY_COUNT++ )) || true
    low="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"
    if [[ "$low" == *bio* ]]; then
      (( J4Y_KEY_BIO++ )) || true
    elif [[ "$low" == *mini* ]]; then
      (( J4Y_KEY_MINI++ )) || true
    else
      (( J4Y_KEY_OTHER++ )) || true
    fi
  done < <(j4y_token2_usb_lines)
}

j4y_pcsc_ok() {
  systemctl is-active pcscd &>/dev/null || return 1
  command -v gpg &>/dev/null || return 1
  gpgconf --kill scdaemon 2>/dev/null || true
  gpg --card-status &>/dev/null
}

j4y_fido_ok() {
  [[ "$(j4y_count_token2_usb)" -gt 0 ]] || return 1
  if command -v fido2-token &>/dev/null; then
    fido2-token -L 2>/dev/null | grep -qi token2 && return 0
  fi
  for ctl in "${HOME}/.local/bin/keyroostctl" "${HOME}/token2-setup/keyroostctl"; do
    [[ -x "$ctl" ]] && "$ctl" list 2>/dev/null | grep -qi hidraw && return 0
  done
  ls /dev/hidraw* &>/dev/null
}

j4y_check_keys() {
  j4y_classify_keys
  local pcsc=1 fido=1
  j4y_pcsc_ok && pcsc=0 || pcsc=1
  j4y_fido_ok && fido=0 || fido=1

  J4Y_CHECK_PCSC=$pcsc
  J4Y_CHECK_FIDO=$fido
  J4Y_CHECK_BOTH_KEYS=0
  [[ "$J4Y_KEY_COUNT" -ge 2 ]] && J4Y_CHECK_BOTH_KEYS=0 || J4Y_CHECK_BOTH_KEYS=1
  [[ "$J4Y_KEY_BIO" -ge 1 && "$J4Y_KEY_MINI" -ge 1 ]] && J4Y_CHECK_PAIR=0 || J4Y_CHECK_PAIR=1
}

j4y_print_health() {
  local root="$1"
  j4y_check_keys

  j4y_say "J4Y-ROOT health"
  if j4y_usb_mounted "$root"; then
    j4y_ok "USB mounted ($(findmnt -n -o SOURCE --target "$root" 2>/dev/null))"
  else
    j4y_warn "USB path not on expected mount (still usable from $root)"
  fi

  printf '\n  Token2 USB devices: %s\n' "$J4Y_KEY_COUNT"
  j4y_token2_usb_lines | sed 's/^/    /'
  if [[ "$J4Y_KEY_BIO" -ge 1 ]]; then j4y_ok "Bio-class key detected ($J4Y_KEY_BIO)"
  else j4y_fail "Bio-class key not detected"; fi
  if [[ "$J4Y_KEY_MINI" -ge 1 ]]; then j4y_ok "Mini-class key detected ($J4Y_KEY_MINI)"
  else j4y_fail "Mini-class key not detected"; fi

  if [[ "$J4Y_CHECK_PCSC" -eq 0 ]]; then j4y_ok "OpenPGP / PC/SC (gpg --card-status)"
  else j4y_warn "OpenPGP / PC/SC not ready (pcscd, ccid, key plugged?)"; fi

  if [[ "$J4Y_CHECK_FIDO" -eq 0 ]]; then j4y_ok "FIDO / hidraw path"
  else j4y_warn "FIDO path not verified (libfido2 / keyroostctl / hidraw)"; fi
  printf '\n'
}
