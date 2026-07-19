#!/usr/bin/env bash
# op-ensure-auth — keep 1Password CLI authenticated without repeated prompts.
#
# Uses the 1Password desktop app integration when available (enable in app:
# Settings → Developer → Integrate with 1Password CLI). Falls back to a
# cached session token in ~/.config/op/cli-session.env (~30 day lifetime).
#
# Usage:
#   eval "$(./scripts/op-ensure-auth.sh)"     # shell: export session vars
#   ./scripts/op-ensure-auth.sh check        # exit 0 if op can read secrets
#   ./scripts/op-ensure-auth.sh signin       # interactive / biometric sign-in
#
# For Cursor / headless automation (optional, more privileged):
#   export OP_SERVICE_ACCOUNT_TOKEN=ops_...   # 1Password service account
#
set -euo pipefail

OP_ACCOUNT="${OP_ACCOUNT:-j4y00}"
OP_SESSION_FILE="${OP_SESSION_FILE:-$HOME/.config/op/cli-session.env}"
export OP_BIOMETRIC_UNLOCK_ENABLED="${OP_BIOMETRIC_UNLOCK_ENABLED:-true}"

_load_session() {
	[[ -f $OP_SESSION_FILE ]] || return 1
	# shellcheck disable=SC1090
	source "$OP_SESSION_FILE"
}

_save_session() {
	local token account_var
	mkdir -p "$(dirname "$OP_SESSION_FILE")"
	chmod 700 "$(dirname "$OP_SESSION_FILE")"
	token=$(OP_BIOMETRIC_UNLOCK_ENABLED=true op signin --account "$OP_ACCOUNT" --raw 2>/dev/null) || return 1
	[[ -n $token ]] || return 1
	account_var="OP_SESSION_${OP_ACCOUNT}"
	install -m600 /dev/null "$OP_SESSION_FILE"
	printf 'export OP_ACCOUNT=%q\nexport %s=%q\n' "$OP_ACCOUNT" "$account_var" "$token" >"$OP_SESSION_FILE"
}

cmd_check() {
	command -v op >/dev/null 2>&1 || return 1
	_load_session 2>/dev/null || true
	op whoami &>/dev/null && return 0
	# Desktop integration often works for reads even when whoami fails.
	op vault list &>/dev/null
}

cmd_signin() {
	command -v op >/dev/null 2>&1 || {
		echo "op-ensure-auth: op CLI not installed" >&2
		return 1
	}
	_load_session 2>/dev/null || true
	if op whoami &>/dev/null; then
		echo "op-ensure-auth: already signed in ($(op whoami 2>/dev/null))"
		return 0
	fi
	# Prefer desktop app unlock (no master password when app is open + integrated).
	if OP_BIOMETRIC_UNLOCK_ENABLED=true op signin --account "$OP_ACCOUNT" 2>/dev/null; then
		_save_session 2>/dev/null || true
		echo "op-ensure-auth: signed in via 1Password app"
		return 0
	fi
	echo "op-ensure-auth: sign-in failed — unlock 1Password app and enable CLI integration" >&2
	echo "  Settings → Developer → Integrate with 1Password CLI" >&2
	return 1
}

cmd_export() {
	_load_session 2>/dev/null || true
	if ! op whoami &>/dev/null; then
		OP_BIOMETRIC_UNLOCK_ENABLED=true op signin --account "$OP_ACCOUNT" &>/dev/null || true
		_save_session 2>/dev/null || true
		_load_session 2>/dev/null || true
	fi
	if [[ -f $OP_SESSION_FILE ]]; then
		cat "$OP_SESSION_FILE"
	fi
	printf 'export OP_BIOMETRIC_UNLOCK_ENABLED=%q\n' "${OP_BIOMETRIC_UNLOCK_ENABLED}"
	printf 'export OP_ACCOUNT=%q\n' "${OP_ACCOUNT}"
}

main() {
	local cmd=${1:-export}
	shift || true
	case "$cmd" in
		check)   cmd_check "$@" ;;
		signin)  cmd_signin "$@" ;;
		export)  cmd_export "$@" ;;
		-h|--help)
			sed -n '2,18p' "$0"
			;;
		*) cmd_export "$@" ;;
	esac
}

main "$@"
