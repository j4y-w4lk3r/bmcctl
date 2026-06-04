#!/usr/bin/env bash
# shellcheck disable=SC2034
#
# bmcctl Arch installer — archiso profile definition.
#
# This file overrides the upstream `releng` profiledef.sh after
# build.sh has copied releng into the work directory. We only change
# iso_name, iso_label, and iso_application; everything else (build
# modes, boot modes, file_permissions for installer assets) stays
# at the releng defaults so we benefit from upstream improvements
# without having to track every change.
#
# The HOST_LABEL placeholder gets substituted by build.sh per host.

iso_name="bmcctl-installer"
iso_label="BMCCTL_$(date +%Y%m)"
iso_publisher="bmcctl <https://github.com/j4y-w4lk3r/bmcctl>"
iso_application="bmcctl unattended Arch installer (HOST_LABEL_PLACEHOLDER)"
iso_version="$(date +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
# Modern archiso (>=75) collapsed several bootmode flavors. Today's
# canonical list for an x86_64 dual BIOS+UEFI ISO is exactly these
# two; mkarchiso warns if you ask for the older split names.
bootmodes=('bios.syslinux' 'uefi.grub')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
# Why zstd instead of upstream's xz: parallel mksquashfs with the xz
# compressor crashes ("FATAL ERROR: xz uncompress failed with error
# code 9") when the build runs under qemu-user emulation (Apple
# Silicon -> linux/amd64 container). zstd has no such issue, builds
# 4-5x faster, and produces an ISO only ~10% larger. archiso/releng
# itself defaults to zstd in profile templates as of 2024.
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '20' '-b' '1M')
bootstrap_tarball_compression=(zstd -c -T0 --auto-threads=logical --long -19)
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
  ["/root/.gnupg"]="0:0:700"
  ["/root/install.sh"]="0:0:755"
  ["/usr/local/bin/choose-mirror"]="0:0:755"
  ["/usr/local/bin/Installation_guide"]="0:0:755"
  ["/usr/local/bin/livecd-sound"]="0:0:755"
)
