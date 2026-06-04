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
#   ARCHISO_PKGS       additional packages installed in the builder
#                      (default: archiso grub git mtools dosfstools)
#   PLATFORM           docker --platform value
#                      (default: linux/amd64; needed on Apple Silicon)

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
# `cp -a` preserves symlinks. Critical because macOS BSD `cp -r`
# DEREFERENCES symlinks (unlike GNU coreutils on Linux), and our
# overlay deliberately uses a symlink to enable a systemd unit:
#   profile/airootfs/etc/systemd/system/multi-user.target.wants/bmcctl-installer.service
#       -> ../bmcctl-installer.service
# If that gets flattened to a regular file, systemd ignores it and
# the live ISO sits at a login prompt instead of running install.sh.
cp -a "$ISO_BUILD_DIR/profile/." "$STAGE/"
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
# archiso pulls in mkarchiso + the squashfs / iso-creation chain.
# grub is needed by the uefi.grub bootmode (mkarchiso shells out to
# grub-install + grub-mkimage). git is here so that, if anything in
# the profile ever needs to clone a small dotfile repo at build time,
# we don't have to round-trip an apt install. mtools/dosfstools cover
# the FAT32 ESP we copy into.
PKGS=${ARCHISO_PKGS:-archiso grub git mtools dosfstools}
# We always build an x86_64 ISO. On Apple Silicon hosts the docker
# daemon defaults to linux/arm64/v8 and `docker pull archlinux:latest`
# fails because Docker Hub only publishes amd64 for archlinux. Force
# linux/amd64 so colima emulates via its embedded QEMU — slower the
# first time (TCG instead of native), but produces a real bootable
# x86_64 ISO. Override with PLATFORM=linux/amd64 (or =linux/arm64
# if you have an Arch-on-ARM image and a known archiso aarch64 path).
PLATFORM=${PLATFORM:-linux/amd64}

if ! docker info >/dev/null 2>&1; then
    echo "build: docker daemon not reachable. If using colima, run:" >&2
    echo "         colima start" >&2
    exit 3
fi

# Persistent pacman package cache. We use a NAMED docker volume
# (rather than a host bind mount) for the same reason as the chroot:
# pacman wants normal Linux filesystem semantics. The first build
# downloads ~600 packages over the network (~10-15 min on amd64
# emulation); every subsequent build re-uses the cache and finishes
# in 3-5 min. Volume is preserved across builds; remove it with:
#   docker volume rm bmcctl-iso-pacman-cache
PACMAN_CACHE_VOLUME=${PACMAN_CACHE_VOLUME:-bmcctl-iso-pacman-cache}
docker volume create "$PACMAN_CACHE_VOLUME" >/dev/null

# Bind-mount layout inside the container:
#   /overlay  -- our pre-rendered profile overlay (read-only input)
#   /out      -- ISO output (only the final .iso ever lands here)
#   /var/cache/pacman/pkg  -- named volume, preserved across builds
#
# The mkarchiso work dir lives on the CONTAINER's writable layer at
# /work, NOT on a host bind mount. Reason: mkarchiso runs pacstrap,
# which calls flock(2) on /var/lib/pacman/db.lck inside the chroot.
# colima exposes the macOS host filesystem over a virtio-9p / sshfs
# style mount that doesn't honor flock the way the chroot pacman
# expects, so the build fails with "unable to lock database". Keeping
# the chroot on the container's overlayfs sidesteps the whole class
# of host-FS semantic mismatches.
docker run --rm \
    --platform "$PLATFORM" \
    --privileged \
    -v "$STAGE:/overlay:ro" \
    -v "$OUT_DIR:/out" \
    -v "$PACMAN_CACHE_VOLUME:/var/cache/pacman/pkg" \
    -e LABEL="$LABEL" \
    -e PKGS="$PKGS" \
    "$IMAGE" \
    bash -euo pipefail -c '
        # pacman 7+ sandboxes downloads via seccomp+landlock, which
        # breaks under qemu-user emulation in a Docker container
        # (the "error restricting syscalls via seccomp: 22!" failure).
        # Disabling it for the duration of the build is the standard
        # workaround: see archlinux/archlinux-docker#225.
        sed -i "s/^#\?DownloadUser.*/#DownloadUser = alpm/" /etc/pacman.conf
        echo "DisableSandbox" >> /etc/pacman.conf

        # Refresh keyring + install build tooling.
        pacman -Sy --noconfirm archlinux-keyring >/dev/null
        # shellcheck disable=SC2086
        pacman -S --noconfirm --needed $PKGS >/dev/null

        # Container-local work dir (NOT a host bind mount).
        mkdir -p /work
        cp -r /usr/share/archiso/configs/releng /work/profile-base
        # Layer our customizations on top of the upstream profile.
        cp -r /overlay/. /work/profile-base/

        # Add `console=tty0 console=ttyS0,115200` to the kernel cmdline
        # in every bootloader config releng ships (syslinux for BIOS,
        # grub for UEFI). Order matters: the LAST `console=` becomes
        # /dev/console, so listing ttyS0 LAST means /dev/console
        # resolves to the serial port. That is what we want for BMC
        # SOL and `qemu -nographic`, and it also means systemd
        # `StandardOutput=journal+console` routes service output
        # over serial. Boot messages still print to BOTH consoles
        # (the kernel writes printk to every console= listed), so
        # an admin sitting at the BMC graphical viewer also sees
        # the boot scroll.
        # Anchor on `archisobasedir=%INSTALL_DIR%` (unique placeholder).
        find /work/profile-base/syslinux \
             /work/profile-base/grub \
             /work/profile-base/efiboot \
             -type f \
             -exec grep -l "archisobasedir=%INSTALL_DIR%" {} + 2>/dev/null \
        | while read -r f; do
            sed -i \
                "s|archisobasedir=%INSTALL_DIR%|console=tty0 console=ttyS0,115200 archisobasedir=%INSTALL_DIR%|g" \
                "$f"
            echo "[bmcctl] patched serial console into $f"
        done

        # Merge our extra packages with the upstream releng list.
        # We normalize aggressively (strip comments + collapse all
        # whitespace to one package per line) because the releng
        # file has aligned columns with trailing whitespace, and a
        # naive `sort -u` keeps "pkg" and "pkg  " as distinct lines,
        # which pacman then treats as two separate (and one missing)
        # targets.
        if [[ -f /usr/share/archiso/configs/releng/packages.x86_64 ]]; then
            {   cat /usr/share/archiso/configs/releng/packages.x86_64;
                cat /overlay/packages.x86_64;
            } | sed -E "s/[[:space:]]*#.*$//" \
              | tr "[:space:]" "\n" \
              | grep -v "^$" \
              | sort -u \
              > /work/profile-base/packages.x86_64
        fi

        mkdir -p /work/mkarchiso
        mkarchiso -v \
            -w /work/mkarchiso \
            -o /out \
            /work/profile-base
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
