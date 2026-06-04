#!/usr/bin/env bash
# Native build — runs `mkarchiso` directly on an Arch host, no Docker.
#
# Selected automatically by the Makefile when:
#   1. We are running on Linux, AND
#   2. `mkarchiso` is on PATH (i.e. the `archiso` package is installed).
#
# On macOS or Linux without archiso, the Makefile falls back to
# build.sh (the Docker wrapper). The two scripts produce
# byte-equivalent ISOs; this one is just *much* faster on a native
# amd64 host because it skips emulation and runs pacstrap+mksquashfs
# straight on the host CPU.
#
# Usage:    build-native.sh <label>
#
# Reads:    hosts/<label>.toml, profile/
# Writes:   out/bmcctl-installer-<label>-YYYY.MM.DD-x86_64.iso
# Requires: passwordless sudo (mkarchiso needs root for pacstrap +
#           mksquashfs + chroot; that's the same root requirement
#           the Docker version satisfies via --privileged).

set -euo pipefail

LABEL=${1:?usage: build-native.sh <label>   (e.g. build-native.sh nas)}

ISO_BUILD_DIR=$(cd "$(dirname "$0")" && pwd)
HOST_TOML="$ISO_BUILD_DIR/hosts/$LABEL.toml"
OUT_DIR="$ISO_BUILD_DIR/out"
WORK_DIR="$ISO_BUILD_DIR/work-$LABEL"

if [[ ! -f $HOST_TOML ]]; then
    echo "build-native: no such host config: $HOST_TOML" >&2
    exit 2
fi

if ! command -v mkarchiso >/dev/null 2>&1; then
    echo "build-native: mkarchiso not on PATH. Install with:" >&2
    echo "                sudo pacman -S archiso" >&2
    exit 3
fi

if [[ $(uname -s) != Linux ]]; then
    echo "build-native: only runs on Linux (got $(uname -s))." >&2
    echo "              On other hosts, use build.sh (Docker wrapper)." >&2
    exit 4
fi

mkdir -p "$OUT_DIR" "$WORK_DIR"

# 1. Stage the overlay (TOML -> install-config.env, copy profile/).
# `cp -a` preserves symlinks; the systemd unit's enable symlink at
# multi-user.target.wants/bmcctl-installer.service must NOT be
# flattened or systemd will treat it as a stray unit file and never
# auto-run install.sh. This is the same trap the macOS build hit.
STAGE="$WORK_DIR/profile-overlay"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -a "$ISO_BUILD_DIR/profile/." "$STAGE/"
mkdir -p "$STAGE/airootfs/root"
"$ISO_BUILD_DIR/render-config.sh" "$LABEL" \
    "$STAGE/airootfs/root/install-config.env" \
    "$STAGE/airootfs/root/.ssh/authorized_keys"

sed -i.bak "s|HOST_LABEL_PLACEHOLDER|$LABEL|g" "$STAGE/profiledef.sh"
rm -f "$STAGE/profiledef.sh.bak"

# 2. Compose profile-base = upstream releng + our overlay.
PROFILE_BASE="$WORK_DIR/profile-base"
sudo rm -rf "$PROFILE_BASE"
cp -a /usr/share/archiso/configs/releng "$PROFILE_BASE"
cp -a "$STAGE/." "$PROFILE_BASE/"

# 3. Patch serial console into kernel cmdline (BIOS syslinux + UEFI
# grub configs both). LAST `console=` wins for /dev/console -> serial,
# which is what BMC SOL captures and what `qemu -nographic` reads.
find "$PROFILE_BASE/syslinux" \
     "$PROFILE_BASE/grub" \
     "$PROFILE_BASE/efiboot" \
     -type f \
     -exec grep -l "archisobasedir=%INSTALL_DIR%" {} + 2>/dev/null \
| while read -r f; do
    sed -i \
        "s|archisobasedir=%INSTALL_DIR%|console=tty0 console=ttyS0,115200 archisobasedir=%INSTALL_DIR%|g" \
        "$f"
done

# 4. Merge packages: upstream releng + our extras, normalized.
# (Releng has trailing whitespace on aligned columns; naive sort -u
# keeps "pkg" and "pkg  " as distinct lines, which then triggers
# "target not found" inside pacstrap. Collapse all whitespace first.)
{ cat /usr/share/archiso/configs/releng/packages.x86_64;
  cat "$STAGE/packages.x86_64";
} | sed -E "s/[[:space:]]*#.*$//" \
  | tr "[:space:]" "\n" \
  | grep -v "^$" \
  | sort -u \
  > "$PROFILE_BASE/packages.x86_64"

# 5. Run mkarchiso. mkarchiso needs root for pacstrap + mksquashfs
# + chroot; we use sudo (assumed passwordless on the test machine).
echo "::: starting mkarchiso (native, $(nproc) cores)"
sudo mkarchiso -v \
    -w "$WORK_DIR/mkarchiso" \
    -o "$OUT_DIR" \
    "$PROFILE_BASE"

# 6. Take ownership back from root. mkarchiso writes the ISO as
# root because it ran as root; chown so the user can publish/test
# without needing sudo for everything afterwards.
sudo chown -R "$USER:$USER" "$OUT_DIR" "$WORK_DIR"

# 7. Rename the output ISO to include the host label.
DATE=$(date +%Y.%m.%d)
# shellcheck disable=SC2012
GENERIC_ISO=$(ls -t "$OUT_DIR"/bmcctl-installer-*x86_64.iso 2>/dev/null | head -n1 || true)
if [[ -z $GENERIC_ISO ]]; then
    echo "build-native: mkarchiso completed but no ISO appeared in $OUT_DIR" >&2
    exit 5
fi
HOST_ISO="$OUT_DIR/bmcctl-installer-$LABEL-$DATE-x86_64.iso"
if [[ $GENERIC_ISO != "$HOST_ISO" ]]; then
    mv -f "$GENERIC_ISO" "$HOST_ISO"
fi
sha256sum "$HOST_ISO" | tee "$HOST_ISO.sha256"

echo
echo "build-native: wrote $HOST_ISO"
echo "       size $(du -h "$HOST_ISO" | cut -f1)"
echo "       next:  bmcctl install-arch $LABEL --iso https://<your-host>/$(basename "$HOST_ISO")"
