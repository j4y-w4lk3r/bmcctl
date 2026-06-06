#!/usr/bin/env bash
# bmcctl unattended Arch installer.
#
# Runs as root on the live ISO via the bmcctl-installer.service
# systemd unit (which is wired into multi-user.target.wants by the
# build). All output goes to stdout AND /var/log/bmcctl-install.log
# so:
#   - Serial Over LAN (SOL) on the BMC sees every line.
#   - The log file survives in tmpfs for post-mortem if the install
#     fails before reboot.
#
# Configuration source: /root/install-config.env. This file is a
# bash-sourceable .env baked in at ISO build time by render-config.sh
# from a per-host TOML (so the human edits TOML, the ISO ships env).
# The expected variables are documented in install-config.example.toml.
#
# Failure mode: on any error the script logs the failure, prints the
# log path on the console, then drops to a root login shell on the
# active TTY. The operator can then SSH in (key was baked in) or use
# the BMC's KVM/SOL to debug. We do NOT poweroff on failure; the
# remote operator needs the live env to remain reachable.
#
# Success mode: clean shutdown via `systemctl poweroff`. The BMC
# transitions to PowerState=Off, which the bmcctl orchestrator can
# poll for to learn the install actually completed (vs the host just
# being on with the live ISO still running).

set -euo pipefail

LOG=/var/log/bmcctl-install.log
mkdir -p /var/log
# /dev/console is the kernel's "all consoles" device; whatever we
# pass on the kernel cmdline as `console=...` ends up here. With
# `console=ttyS0,115200 console=tty0` (set by the ISO bootloader
# config) every write to /dev/console hits both the graphical
# framebuffer (visible via the BMC's H5Viewer) AND the serial port
# (visible via SOL), so an operator on either channel sees the
# install proceed.
exec > >(tee -a "$LOG" /dev/console) 2>&1

# Trap any uncaught error and drop to a shell instead of just dying
# silently — easier to debug from SOL than to read journal entries.
on_error() {
    local rc=$?
    echo
    echo "=========================================================="
    echo "  bmcctl-install: FAILED with exit code $rc"
    echo "  log: $LOG"
    # Persist the log onto the target disk (if it's already mounted) so
    # the failure can be post-mortemed after a reboot — no SOL/KVM
    # needed. Best-effort: never let cleanup itself raise a new error.
    if mountpoint -q /mnt 2>/dev/null; then
        mkdir -p /mnt/var/log 2>/dev/null || true
        cp "$LOG" /mnt/var/log/bmcctl-install.log 2>/dev/null || true
        echo "  log also copied to (disk):/var/log/bmcctl-install.log"
    fi
    echo "  drop to a root shell so you can debug from SOL/KVM."
    echo "=========================================================="
    # Don't exec another shell here — systemd is supervising us;
    # let the unit's `Restart=no` policy keep us out, then the
    # serial-getty already running will show a normal login prompt.
    return "$rc"
}
trap on_error ERR

CONFIG=/root/install-config.env
if [[ ! -f $CONFIG ]]; then
    echo "FATAL: $CONFIG missing — was the ISO built without render-config.sh?"
    exit 2
fi
# shellcheck disable=SC1090
source "$CONFIG"

# ---- required variables ----
: "${HOSTNAME:?HOSTNAME must be set in install-config.env}"
: "${TARGET_DISK:?TARGET_DISK must be set (e.g. /dev/nvme0n1)}"
: "${USERNAME:?USERNAME must be set}"
: "${TIMEZONE:?TIMEZONE must be set (e.g. Europe/Warsaw)}"
: "${LOCALE:=en_US.UTF-8}"
: "${KEYMAP:=us}"
: "${WIPE_DISK:?refuse to run without explicit WIPE_DISK=yes}"

if [[ $WIPE_DISK != "yes" ]]; then
    echo "FATAL: WIPE_DISK is not 'yes' — refusing to partition $TARGET_DISK"
    exit 3
fi
if [[ ! -b $TARGET_DISK ]]; then
    echo "FATAL: TARGET_DISK $TARGET_DISK is not a block device on this host"
    echo "  available block devices:"
    lsblk -dno NAME,SIZE,MODEL
    exit 3
fi

# ---- banner so SOL operator can see what's about to happen ----
cat <<BANNER

==============================================================
  bmcctl unattended Arch installer
  hostname:    $HOSTNAME
  target disk: $TARGET_DISK   ($(lsblk -dno SIZE "$TARGET_DISK" 2>/dev/null || echo "?"))
  user:        $USERNAME
  tz / locale: $TIMEZONE / $LOCALE
  log:         $LOG
  press Ctrl-C within 10 seconds to ABORT (drops to shell)
==============================================================
BANNER
sleep 10

# ---- network ----
# archiso releng has systemd-networkd + DHCP enabled by default
# but we double-check before pacstrap; without DNS the install dies
# in cryptic ways further down.
echo "::: waiting up to 60s for network..."
for _ in $(seq 1 60); do
    if curl -fsS --max-time 3 https://archlinux.org/ -o /dev/null; then
        echo "::: network is up"
        break
    fi
    sleep 1
done
if ! curl -fsS --max-time 3 https://archlinux.org/ -o /dev/null; then
    echo "FATAL: no network after 60s — check VLAN / DHCP / cable"
    exit 4
fi

# ---- partition ----
# Layout: GPT, 1G EFI (FAT32) + remaining ext4 root.
# We deliberately pick a layout the firmware always likes:
#   - one ESP, mounted at /boot
#   - one root, ext4 (no LVM, no LUKS in the v0.1 of this ISO)
# LUKS / btrfs / zfs are easy to add later via a config flag.
echo "::: zapping $TARGET_DISK"
sgdisk --zap-all "$TARGET_DISK"

echo "::: partitioning $TARGET_DISK"
sgdisk --clear \
    --new=1:0:+1G   --typecode=1:ef00 --change-name=1:EFI \
    --new=2:0:0     --typecode=2:8300 --change-name=2:archroot \
    "$TARGET_DISK"
partprobe "$TARGET_DISK"
sleep 2

# Resolve partition device names. NVMe uses pNN suffix, SATA does not.
case "$TARGET_DISK" in
    /dev/nvme*|/dev/mmcblk*) PART_PREFIX="${TARGET_DISK}p" ;;
    *)                       PART_PREFIX="$TARGET_DISK" ;;
esac
ESP="${PART_PREFIX}1"
ROOT="${PART_PREFIX}2"

echo "::: ESP=$ESP  ROOT=$ROOT"
mkfs.fat -F32 -n EFI "$ESP"
mkfs.ext4 -F -L archroot "$ROOT"

mount "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$ESP" /mnt/boot

# ---- pacstrap ----
# Keep the package list small and explicit. Anything host-specific
# (e.g. zsh, neovim, ...) goes into POST_INSTALL_PACKAGES so the
# config file can extend without editing the ISO.
BASE_PKGS=(
    base linux linux-firmware
    networkmanager openssh sudo
    vim git curl htop rsync # rsync: required by homelab-dotfiles apply-local.sh
    intel-ucode # AMD users override via POST_INSTALL_PACKAGES
)
EXTRA_PKGS=()
if [[ ${POST_INSTALL_PACKAGES:-} != "" ]]; then
    # shellcheck disable=SC2206
    EXTRA_PKGS=( ${POST_INSTALL_PACKAGES} )
fi
echo "::: pacstrap: ${BASE_PKGS[*]} ${EXTRA_PKGS[*]}"
pacstrap -K /mnt "${BASE_PKGS[@]}" "${EXTRA_PKGS[@]}"

# ---- fstab ----
genfstab -U /mnt >> /mnt/etc/fstab

# ---- chroot configuration ----
# Everything below runs inside the new system. We use a heredoc with
# explicit env so we don't accidentally inherit something from the
# live env (HOSTNAME etc. are defined again on the inside).
arch-chroot /mnt /usr/bin/env \
    HOSTNAME="$HOSTNAME" \
    USERNAME="$USERNAME" \
    TIMEZONE="$TIMEZONE" \
    LOCALE="$LOCALE" \
    KEYMAP="$KEYMAP" \
    USER_PUBKEY="${USER_PUBKEY:-}" \
    USER_PASSWORD_HASH="${USER_PASSWORD_HASH:-}" \
    DOTFILES_BOOTSTRAP="${DOTFILES_BOOTSTRAP:-false}" \
    DOTFILES_REPO="${DOTFILES_REPO:-https://github.com/j4y-w4lk3r/bmcctl.git}" \
    bash -e <<'CHROOT'

# Time + locale
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc
sed -i "s/^#\(${LOCALE}\)/\1/" /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

# Bootloader: systemd-boot. Simpler than GRUB on UEFI Arch.
bootctl install
mkdir -p /boot/loader/entries
cat > /boot/loader/loader.conf <<LOADER
default arch
timeout 3
console-mode max
editor   no
LOADER
ROOT_UUID=$(blkid -s PARTUUID -o value "$(findmnt -no SOURCE /)")
cat > /boot/loader/entries/arch.conf <<ENTRY
title   Arch Linux ($HOSTNAME)
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options root=PARTUUID=${ROOT_UUID} rw console=tty0 console=ttyS0,115200n8
ENTRY
# Fallback entry without ucode for AMD / VMs.
cat > /boot/loader/entries/arch-fallback.conf <<ENTRY
title   Arch Linux Fallback ($HOSTNAME)
linux   /vmlinuz-linux
initrd  /initramfs-linux-fallback.img
options root=PARTUUID=${ROOT_UUID} rw console=tty0 console=ttyS0,115200n8
ENTRY

# Network: NetworkManager handles DHCP. Enable a sensible default
# Ethernet config so the box comes up after first boot without
# operator intervention.
systemctl enable NetworkManager.service

# SSH: enable, harden minimally. Password auth defaults off (key-only).
systemctl enable sshd.service
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config

# Serial console for SOL after first boot.
systemctl enable serial-getty@ttyS0.service

# Users.
useradd -m -G wheel -s /bin/bash "$USERNAME"
if [[ ${USER_PASSWORD_HASH} != "" ]]; then
    # mkpasswd -m sha-512 — generated by render-config.sh.
    usermod --password "$USER_PASSWORD_HASH" "$USERNAME"
else
    # No password set: SSH key only. Lock the password explicitly.
    passwd -l "$USERNAME"
fi
mkdir -p "/home/$USERNAME/.ssh"
chmod 700 "/home/$USERNAME/.ssh"
if [[ ${USER_PUBKEY} != "" ]]; then
    echo "$USER_PUBKEY" > "/home/$USERNAME/.ssh/authorized_keys"
fi
chmod 600 "/home/$USERNAME/.ssh/authorized_keys" 2>/dev/null || true
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"

# Wheel -> sudo (with password if one was set; NOPASSWD if key-only).
if [[ ${USER_PASSWORD_HASH} != "" ]]; then
    echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
else
    echo '%wheel ALL=(ALL:ALL) NOPASSWD:ALL' > /etc/sudoers.d/10-wheel
fi
chmod 440 /etc/sudoers.d/10-wheel

# Lock the root account. SSH already prohibits-password; this just
# makes it explicit that there is no local-console root login either.
passwd -l root

CHROOT

# ---- first-boot dotfiles (copy from live ISO → installed system) ----
# NON-FATAL by design: the OS is already fully installed and bootable by
# this point. A failure enabling the first-boot service must never abort
# the install (which would leave the box powered On and unbootable) — at
# worst the box boots without auto-dotfiles and we apply them manually.
# That's why the whole block is an && chain caught by `|| echo WARN`.
if [[ "${DOTFILES_BOOTSTRAP:-false}" =~ ^([Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|1)$ ]]; then
    echo "::: enabling first-boot dotfiles bootstrap"
    if [[ ! -f /usr/local/lib/bmcctl/dotfiles-bootstrap.sh || ! -f /etc/systemd/system/bmcctl-dotfiles.service ]]; then
        echo "WARN: first-boot assets missing from live ISO (dotfiles-bootstrap.sh / bmcctl-dotfiles.service) — skipping; apply dotfiles manually after boot"
    else
        {
            mkdir -p /mnt/usr/local/lib/bmcctl /mnt/etc/systemd/system &&
            install -m755 /usr/local/lib/bmcctl/dotfiles-bootstrap.sh /mnt/usr/local/lib/bmcctl/ &&
            install -m644 /etc/systemd/system/bmcctl-dotfiles.service /mnt/etc/systemd/system/ &&
            arch-chroot /mnt systemctl enable bmcctl-dotfiles.service
        } || echo "WARN: first-boot dotfiles enablement failed (non-fatal) — apply dotfiles manually after boot"
    fi
fi

# ---- copy install log into the new system for forensics ----
mkdir -p /mnt/var/log
cp "$LOG" /mnt/var/log/bmcctl-install.log

# ---- done ----
sync
echo
echo "=========================================================="
echo "  bmcctl-install: SUCCESS"
echo "  hostname:    $HOSTNAME"
echo "  user:        $USERNAME"
echo "  ssh:         $(grep -c . "/mnt/home/$USERNAME/.ssh/authorized_keys" 2>/dev/null || echo 0) authorized key(s)"
echo "  poweroff in 5s. BMC will see PowerState=Off when this is"
echo "  complete; that's your signal that the install actually"
echo "  finished (vs the host stuck in the live env)."
echo "=========================================================="
sleep 5
systemctl poweroff
