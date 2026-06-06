#!/usr/bin/env bash
# Render bmcctl/iso-build/hosts/<label>.toml into the
# install-config.env that the on-ISO install.sh sources.
#
# We could ship a TOML parser inside the live ISO, but that just
# adds weight + a dependency for the runtime path. Instead the
# build pipeline does the TOML->env conversion outside the ISO,
# bakes the resulting env file into airootfs/root/, and install.sh
# just sources it.
#
# Usage:
#   render-config.sh <label> <output-env-path>
#
# Reads:  bmcctl/iso-build/hosts/<label>.toml
# Writes: <output-env-path> (typically airootfs/root/install-config.env)
# Side-effect: copies the resolved SSH public-key file into the
# airootfs root so install.sh can drop it into the new user's
# authorized_keys without any out-of-band fetching.

set -euo pipefail

LABEL=${1:?usage: render-config.sh <label> <output-env-path> [<authorized-keys-out>]}
OUT=${2:?missing output env path}
KEYS_OUT=${3:-}

ISO_BUILD_DIR=$(cd "$(dirname "$0")" && pwd)
TOML="$ISO_BUILD_DIR/hosts/$LABEL.toml"
if [[ ! -f $TOML ]]; then
    echo "render-config: no such host config: $TOML" >&2
    echo "  hosts available:" >&2
    # shellcheck disable=SC2012  # filenames are <label>.toml, no special chars
    ls "$ISO_BUILD_DIR/hosts/" 2>&1 | sed 's/^/    /' >&2
    exit 2
fi

# We use a deliberately minimal TOML reader: tomlq (yq's TOML
# variant) if available, falling back to a tiny Python one-liner.
# Both are widely available; we never need to vendor a parser.
read_toml() {
    local key=$1
    if command -v tomlq >/dev/null 2>&1; then
        tomlq -r "$key" "$TOML" 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "$TOML" "$key" <<'PY'
import sys, tomllib, functools
with open(sys.argv[1], "rb") as f:
    doc = tomllib.load(f)
key = sys.argv[2].lstrip(".")
node = doc
for part in key.split("."):
    if isinstance(node, dict) and part in node:
        node = node[part]
    else:
        node = ""
        break
if isinstance(node, list):
    print(" ".join(str(x) for x in node))
elif node is None:
    print("")
else:
    print(node)
PY
    else
        echo "render-config: need tomlq or python3 to read $TOML" >&2
        exit 3
    fi
}

HOSTNAME=$(read_toml '.host.hostname')
TARGET_DISK=$(read_toml '.host.target_disk')
WIPE_DISK=$(read_toml '.host.wipe_disk')
TIMEZONE=$(read_toml '.host.timezone')
LOCALE=$(read_toml '.host.locale')
KEYMAP=$(read_toml '.host.keymap')
USERNAME=$(read_toml '.user.name')
PUBKEY_FILE=$(read_toml '.user.ssh_pubkey_file')
PASSWORD_HASH=$(read_toml '.user.password_hash')
EXTRA_PACKAGES=$(read_toml '.packages.extra')
DOTFILES_BOOTSTRAP=$(read_toml '.dotfiles.bootstrap')
DOTFILES_REPO=$(read_toml '.dotfiles.repo')
DOTFILES_BOOTSTRAP=${DOTFILES_BOOTSTRAP:-false}
DOTFILES_REPO=${DOTFILES_REPO:-https://github.com/j4y-w4lk3r/bmcctl.git}
# TOML booleans render parser-dependently: tomlq emits "true"/"false",
# but the python3/tomllib fallback prints Python's "True"/"False". The
# on-ISO install.sh compares against lowercase "true", so normalize to a
# canonical token here — otherwise first-boot is silently skipped.
case "$(printf '%s' "$DOTFILES_BOOTSTRAP" | tr '[:upper:]' '[:lower:]')" in
    true|yes|1) DOTFILES_BOOTSTRAP=true ;;
    *)          DOTFILES_BOOTSTRAP=false ;;
esac

# Sensible defaults for omitted optional fields.
LOCALE=${LOCALE:-en_US.UTF-8}
KEYMAP=${KEYMAP:-us}

# Sanity-check the required fields BEFORE we touch any files —
# otherwise the user finds out during a 5-minute ISO build.
require() {
    if [[ -z $2 || $2 == "null" ]]; then
        echo "render-config: missing required field: $1" >&2
        exit 4
    fi
}
require "[host].hostname"     "$HOSTNAME"
require "[host].target_disk"  "$TARGET_DISK"
require "[host].wipe_disk"    "$WIPE_DISK"
require "[host].timezone"     "$TIMEZONE"
require "[user].name"         "$USERNAME"
require "[user].ssh_pubkey_file" "$PUBKEY_FILE"
if [[ $WIPE_DISK != "yes" ]]; then
    echo "render-config: [host].wipe_disk must be exactly 'yes' to confirm wipe" >&2
    exit 5
fi

# Resolve ssh key path: ~ expansion, then absolute, then relative.
# Note: SC2088 fires on `~` in a case glob — but in a case label it's
# a *literal* match, not a shell expansion. The disable is intentional.
expand_path() {
    local p=$1
    # shellcheck disable=SC2088
    case "$p" in
        "~"|"~/"*) echo "${HOME}${p#\~}" ;;
        /*)        echo "$p" ;;
        *)         echo "$ISO_BUILD_DIR/$p" ;;
    esac
}
PUBKEY_PATH=$(expand_path "$PUBKEY_FILE")
if [[ ! -f $PUBKEY_PATH ]]; then
    echo "render-config: ssh pubkey not found: $PUBKEY_PATH" >&2
    exit 6
fi
USER_PUBKEY=$(<"$PUBKEY_PATH")

# Optionally drop the keyfile alongside the env file so the live
# ISO can ship it as an actual file too (not strictly needed —
# install.sh writes from $USER_PUBKEY — but useful for debugging).
# mkdir the parent first; .ssh/ is an empty dir in the profile
# overlay and git doesn't track empty dirs, so on a fresh clone
# the path may not exist yet.
if [[ $KEYS_OUT != "" ]]; then
    mkdir -p "$(dirname "$KEYS_OUT")"
    install -m 0600 "$PUBKEY_PATH" "$KEYS_OUT"
fi

# Emit env file. Each variable is single-quoted so embedded
# whitespace, '$', etc. survive sourcing. The pubkey itself
# contains no single quotes (PEM/OpenSSH never uses them) so the
# escape is unambiguous — but we still defensively reject any
# single-quote that snuck in via a malformed key file.
if [[ $USER_PUBKEY == *"'"* ]]; then
    echo "render-config: ssh pubkey unexpectedly contains a single quote — refusing" >&2
    exit 7
fi

mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<ENV
# Generated by render-config.sh from $TOML
# DO NOT EDIT - rebuild the ISO with: make iso HOST=$LABEL
HOSTNAME='$HOSTNAME'
TARGET_DISK='$TARGET_DISK'
WIPE_DISK='$WIPE_DISK'
TIMEZONE='$TIMEZONE'
LOCALE='$LOCALE'
KEYMAP='$KEYMAP'
USERNAME='$USERNAME'
USER_PUBKEY='$USER_PUBKEY'
USER_PASSWORD_HASH='$PASSWORD_HASH'
POST_INSTALL_PACKAGES='$EXTRA_PACKAGES'
DOTFILES_BOOTSTRAP='$DOTFILES_BOOTSTRAP'
DOTFILES_REPO='$DOTFILES_REPO'
ENV
chmod 0644 "$OUT"

echo "render-config: wrote $OUT (host=$LABEL, disk=$TARGET_DISK, user=$USERNAME)"
