#!/usr/bin/env bash
# run.sh — single entry for J4Y-ROOT thumb drive
set -euo pipefail

# USB root = parent of bootstrap/
J4Y_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export J4Y_ROOT

# shellcheck source=lib/j4y-lib.sh
source "$J4Y_ROOT/bootstrap/lib/j4y-lib.sh"

LOG="$(j4y_log_init "$J4Y_ROOT")"
j4y_log "$J4Y_ROOT" "session start pid=$$ host=$(hostname -s 2>/dev/null || echo unknown)" "$LOG"
j4y_session_append "$J4Y_ROOT" "start" "$LOG"

usage() {
  cat <<EOF
j4y run — plug USB, cd to J4Y-ROOT, ./run

  ./run              health check + ceremony status (default)
  ./run check        USB mount + keys + PC/SC + FIDO
  ./run ceremony     ceremony status (JSON checklist)
  ./run ceremony done <id>
  ./run ceremony auto   mark keys_present if Bio+Mini detected
  ./run init         install packages + persona env (offline-safe)
  ./run init --online  init + hint set.d0j0.dev
  ./run log          show latest log path

Version: \$(cat "$J4Y_ROOT/.j4y/version.json" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('created','?'))" 2>/dev/null || echo ?)
EOF
}

cmd_check() {
  j4y_log "$J4Y_ROOT" "check: usb=$(j4y_usb_mounted "$J4Y_ROOT" && echo yes || echo no) keys=$(j4y_count_token2_usb)" "$LOG"
  j4y_print_health "$J4Y_ROOT"
  bash "$J4Y_ROOT/bootstrap/ceremony.sh" auto
}

cmd_init() {
  local extra=()
  [[ "${1:-}" == --online ]] && extra=()
  [[ "${1:-}" == --offline ]] && extra=(--offline)
  j4y_log "$J4Y_ROOT" "init ${1:-}" "$LOG"
  bash "$J4Y_ROOT/bootstrap/init-j4y.sh" "${extra[@]}"
}

latest_log() {
  ls -1t "$J4Y_ROOT/.j4y/logs/"*.log 2>/dev/null | head -1
}

main() {
  local cmd="${1:-}"

  if [[ ! -d "$J4Y_ROOT/.j4y" ]]; then
    j4y_fail "Missing .j4y/ — is this a J4Y-ROOT stick?"
    exit 1
  fi

  printf '\n'
  j4y_say "j4y profile — J4Y-ROOT"
  printf '  created %s\n' "$(python3 -c "import json; print(json.load(open('$J4Y_ROOT/.j4y/version.json')).get('created','?'))" 2>/dev/null || echo ?)"
  printf '  path    %s\n' "$J4Y_ROOT"
  printf '  log     %s\n\n' "$LOG"

  case "$cmd" in
    ""|run)     cmd_check ;;
    check)      cmd_check ;;
    ceremony)   shift; bash "$J4Y_ROOT/bootstrap/ceremony.sh" "${@:-status}" ;;
    init)       shift; cmd_init "${1:-}" ;;
    log)        latest_log || j4y_warn "no logs yet" ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac

  j4y_log "$J4Y_ROOT" "session end ok" "$LOG"
  j4y_ok "log → $LOG"
  j4y_session_append "$J4Y_ROOT" "end" "$LOG"
}

main "$@"
