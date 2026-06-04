#!/usr/bin/env bash
# Build a per-host bmcctl Arch installer ISO.
#
# Why Docker: mkarchiso(1) is part of the `archiso` package, which
# only runs on Arch Linux. The wrapper spins up an Arch container,
# layers our `profile/` overlay on top of the upstream `releng`
# profile shipped at /usr/share/archiso/configs/releng, and runs
# mkarchiso. The output ISO lands in `out/` on the host.
#
# This is the same pattern Arch's own CI uses (see
# https://gitlab.archlinux.org/archlinux/archiso) so we follow the
# upstream's tested path rather than reinventing it.
#
# Usage:
#   build.sh <label>
#
# Reads:  hosts/<label>.toml          (per-host config)
#         profile/                     (overlay over upstream releng)
# Writes: out/bmcctl-installer-<label>-YYYY.MM.DD-x86_64.iso
#
# Environment overrides:
#   ISO_BUILDER_IMAGE  Arch container image (default archlinux:latest)
#   ARCHISO_PKGS       additional packages to install in the builder
#                      (default: "archiso git")
#   KEEP_WORKDIR=1     don't delete the work dir after build (debug)

set -euo pipefail

LABEL=${1:?usage: build.sh <label>   (e.g. build.sh nas)}

ISO_BUILD_DIR=$(cd "$(dirname "$0")" && pwd)
HOST_TOML="$ISO_BUILD_DIR/hosts/$LABEL.toml"
OUT_DIR="$ISO_BUILD_DIR/out"
WORK_DIR="$ISO_BUILD_DIR/work-$LABEL"

if [[ ! -f $HOST_TOML ]]; then
    echo "build: no such host config: $HOST_TOML" >&2
    exit 2
fi

mkdir -p "$OUT_DIR" "$WORK_DIR"

# 1. Render per-host install-config.env from the TOML and stage it
#    into a per-host overlay directory. We do this OUTSIDE the
#    container so the user gets pre-build validation errors quickly
#    (rather than 30s in after pacman has updated mirrors).
STAGE="$WORK_DIR/profile-overlay"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -r "$ISO_BUILD_DIR/profile/." "$STAGE/"
mkdir -p "$STAGE/airootfs/root"
"$ISO_BUILD_DIR/render-config.sh" "$LABEL" \
    "$STAGE/airootfs/root/install-config.env" \
    "$STAGE/airootfs/root/.ssh/authorized_keys"

# 2. Substitute the host label into profiledef.sh and packages.x86_64
#    so iso_application carries it (visible in `dmesg` on the live
#    env, and on the BMC's mounted-media display).
sed -i.bak "s|HOST_LABEL_PLACEHOLDER|$LABEL|g" "$STAGE/profiledef.sh"
rm -f "$STAGE/profiledef.sh.bak"

# 3. Run the build inside Arch.
IMAGE=${ISO_BUILDER_IMAGE:-archlinux:latest}
PKGS=${ARCHISO_PKGS:-archiso git}

if ! docker info >/dev/null 2>&1; then
    echo "build: docker daemon not reachable. If using colima, run:" >&2
    echo "         colima start" >&2
    exit 3
fi

# Bind-mount layout inside the container:
#   /work     -- per-host work dir (overlay + mkarchiso scratch)
#   /out      -- ISO output
# The releng profile is INSIDE the container at
# /usr/share/archiso/configs/releng — we copy it to /work/profile,
# then layer our overlay on top.
docker run --rm \
    --privileged \
    -v "$WORK_DIR:/work" \
    -v "$OUT_DIR:/out" \
    -e LABEL="$LABEL" \
    -e PKGS="$PKGS" \
    -e KEEP_WORKDIR="${KEEP_WORKDIR:-0}" \
    "$IMAGE" \
    bash -euo pipefail -c '
        # Refresh keyring + install build tooling.
        pacman -Sy --noconfirm archlinux-keyring >/dev/null
        # shellcheck disable=SC2086
        pacman -S --noconfirm --needed $PKGS >/dev/null

        cp -r /usr/share/archiso/configs/releng /work/profile-base
        # Overlay our customizations on top of the upstream profile.
        cp -r /work/profile-overlay/. /work/profile-base/

        # Append our extra packages without dropping the upstream
        # ones (the overlay copies our packages.x86_64 verbatim,
        # so we have to merge here).
        if [[ -f /usr/share/archiso/configs/releng/packages.x86_64 ]]; then
            sort -u \
                /usr/share/archiso/configs/releng/packages.x86_64 \
                /work/profile-overlay/packages.x86_64 \
                | grep -v "^#" | grep -v "^$" \
                > /work/profile-base/packages.x86_64
        fi

        mkdir -p /work/mkarchiso
        mkarchiso -v \
            -w /work/mkarchiso \
            -o /out \
            /work/profile-base

        if [[ ${KEEP_WORKDIR:-0} == 0 ]]; then
            rm -rf /work/mkarchiso /work/profile-base
        fi
    '

# 4. Rename the output ISO to include the host label.
# We `ls -t` here because filenames are well-controlled (no spaces,
# no shell-special chars — they always match bmcctl-installer-*x86_64.iso)
# and `find -printf` is GNU-only, breaking macOS hosts.
DATE=$(date +%Y.%m.%d)
# shellcheck disable=SC2012
GENERIC_ISO=$(ls -t "$OUT_DIR"/bmcctl-installer-*x86_64.iso 2>/dev/null | head -n1 || true)
if [[ -z $GENERIC_ISO ]]; then
    echo "build: mkarchiso completed but no ISO appeared in $OUT_DIR" >&2
    exit 4
fi
HOST_ISO="$OUT_DIR/bmcctl-installer-$LABEL-$DATE-x86_64.iso"
if [[ $GENERIC_ISO != "$HOST_ISO" ]]; then
    mv -f "$GENERIC_ISO" "$HOST_ISO"
fi
sha256sum "$HOST_ISO" | tee "$HOST_ISO.sha256"

echo
echo "build: wrote $HOST_ISO"
echo "       size $(du -h "$HOST_ISO" | cut -f1)"
echo "       next:  bmcctl install-arch $LABEL --iso https://<your-host>/$(basename "$HOST_ISO")"
