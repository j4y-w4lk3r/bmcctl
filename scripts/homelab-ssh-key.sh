#!/usr/bin/env bash
# homelab-ssh-key — install the homelab ed25519 key from 1Password.
#
# The same key is baked into bmcctl installer ISOs (nas0.toml etc.) as
# ~/.ssh/id_ed25519.pub. Any machine with `op` signed in can materialize
# the private half for SSH to freshly installed hosts.
#
# Usage:
#   homelab-ssh-key ensure          # write ~/.ssh/id_ed25519 if missing
#   homelab-ssh-key ensure --force  # overwrite local key from 1Password
#   homelab-ssh-key fingerprint     # show SHA256 of key in 1Password
#   homelab-ssh-key path            # print target private-key path
#
# Override:
#   HOMELAB_SSH_OP_REF   default op://g3irkmq3taou5ko6gwxwlkcjd4/homelab id_ed25519/private key
#   HOMELAB_SSH_KEY_PATH default $HOME/.ssh/id_ed25519

set -euo pipefail

HOMELAB_SSH_OP_REF=${HOMELAB_SSH_OP_REF:-'op://g3irkmq3taou5ko6gwxwlkcjd4/homelab id_ed25519/password'}
HOMELAB_SSH_KEY_PATH=${HOMELAB_SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}
HOMELAB_SSH_PUB_PATH="${HOMELAB_SSH_KEY_PATH}.pub"

_expected_fp() {
	# Fingerprint of the homelab key (matches Mac + ISO authorized_keys).
	echo 'SHA256:8i0y3JXkKMIpXCcjyTCJdhhsGhxNxYh7lruBD5utaY8'
}

_fingerprint() {
	local keyfile=$1
	ssh-keygen -lf "$keyfile" 2>/dev/null | awk '{print $2}'
}

_read_from_op() {
	command -v op >/dev/null 2>&1 || {
		echo "homelab-ssh-key: op CLI not found (install 1password-cli)" >&2
		return 1
	}
	op read "$HOMELAB_SSH_OP_REF"
}

cmd_path() {
	printf '%s\n' "$HOMELAB_SSH_KEY_PATH"
}

cmd_fingerprint() {
	local tmp fp
	tmp=$(mktemp)
	_read_from_op >"$tmp"
	fp=$(_fingerprint "$tmp")
	shred -u "$tmp" 2>/dev/null || rm -f "$tmp"
	printf '%s\n' "$fp"
}

cmd_ensure() {
	local force=0 fp exp
	for arg in "$@"; do
		[[ $arg == --force ]] && force=1
	done

	exp=$(_expected_fp)

	if [[ -f $HOMELAB_SSH_KEY_PATH && $force -eq 0 ]]; then
		fp=$(_fingerprint "$HOMELAB_SSH_KEY_PATH")
		if [[ $fp == "$exp" ]]; then
			echo "homelab-ssh-key: ok ($HOMELAB_SSH_KEY_PATH)"
			return 0
		fi
		echo "homelab-ssh-key: $HOMELAB_SSH_KEY_PATH exists but fingerprint is $fp (expected $exp)" >&2
		echo "homelab-ssh-key: re-run with --force to replace from 1Password" >&2
		return 1
	fi

	mkdir -p "$(dirname "$HOMELAB_SSH_KEY_PATH")"
	chmod 700 "$(dirname "$HOMELAB_SSH_KEY_PATH")" 2>/dev/null || true

	local tmp fp
	tmp=$(mktemp)
	_read_from_op >"$tmp"
	fp=$(_fingerprint "$tmp")
	[[ $fp == "$exp" ]] || {
		shred -u "$tmp" 2>/dev/null || rm -f "$tmp"
		echo "homelab-ssh-key: 1Password key fingerprint $fp != expected $exp — aborting" >&2
		return 1
	}

	install -m600 "$tmp" "$HOMELAB_SSH_KEY_PATH"
	shred -u "$tmp" 2>/dev/null || rm -f "$tmp"
	ssh-keygen -y -f "$HOMELAB_SSH_KEY_PATH" >"$HOMELAB_SSH_PUB_PATH"
	chmod 644 "$HOMELAB_SSH_PUB_PATH"
	echo "homelab-ssh-key: installed $HOMELAB_SSH_KEY_PATH ($fp)"
}

usage() {
	cat <<'USAGE'
usage: homelab-ssh-key <ensure [--force]|fingerprint|path>
USAGE
}

main() {
	local cmd=${1:-ensure}
	shift || true
	case "$cmd" in
		ensure)  cmd_ensure "$@" ;;
		fingerprint) cmd_fingerprint ;;
		path)    cmd_path ;;
		-h|--help) usage ;;
		*) usage >&2; exit 64 ;;
	esac
}

main "$@"
