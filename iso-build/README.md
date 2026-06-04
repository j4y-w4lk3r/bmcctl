# bmcctl iso-build — unattended Arch installer ISOs

This directory builds **per-host Arch installer ISOs** that auto-install Arch when booted from the BMC's virtual media. It pairs with [`bmcctl install-arch`](../README.md#virtual-media--boot-override-stream-b) — that command mounts the ISO and triggers a power-cycle; this directory is what makes the ISO actually finish the install on its own.

```
bmcctl iso-build  →  per-host ISO  →  upload to B2  →  bmcctl install-arch <host> --iso URL
```

## Why a custom ISO?

Arch's official ISO drops you at a shell prompt. The installer (`archinstall`, or doing it by hand) needs a human at the keyboard.

For unattended bring-up — which is the whole point of pairing `bmcctl install-arch` with virtual-media boot — we instead bake an `install.sh` and a host-specific config into the ISO itself. The live environment auto-runs the installer, the installer poweroffs cleanly when done, and the BMC reports `PowerState=Off`. That transition is the operator's "install completed" signal.

This is the Arch equivalent of:

| Distro family | Format       | File name      |
|---|---|---|
| Red Hat / Fedora / RHEL | kickstart syntax | `ks.cfg` |
| Debian / Ubuntu | debconf preseed | `preseed.cfg` |
| Cloud images | YAML | `cloud-init user-data` |
| **Arch Linux** | shell script in airootfs | `airootfs/root/install.sh` |

## Directory layout

```
iso-build/
├── README.md                          (this file)
├── Makefile                           # user-facing entry point
├── build.sh                           # docker wrapper around mkarchiso
├── render-config.sh                   # TOML -> install-config.env translator
├── hosts/
│   └── example.toml                   # template; copy and edit per host
└── profile/                           # archiso profile OVERLAY (delta over upstream releng)
    ├── profiledef.sh
    ├── packages.x86_64                # extra packages we want in the live env
    └── airootfs/
        ├── etc/
        │   ├── motd
        │   └── systemd/system/
        │       ├── bmcctl-installer.service
        │       └── multi-user.target.wants/
        │           └── bmcctl-installer.service -> ../bmcctl-installer.service
        └── root/
            └── install.sh             # the unattended install
```

We **layer** our profile on top of Arch's upstream `releng` profile (`/usr/share/archiso/configs/releng/` inside the build container) instead of forking it. That way upstream improvements (new boot modes, new package list defaults, etc.) flow in for free; we only own the deltas.

## Prerequisites

| Tool | Why | macOS install |
|---|---|---|
| `docker` (or compatible runtime) | Run `mkarchiso` inside an Arch container | `brew install docker colima` |
| A running Docker daemon | …obviously | `colima start` |
| `python3` **or** `tomlq` | Read `hosts/<label>.toml` | macOS ships python3; `brew install yq` for tomlq |
| `bbm` (this repo's bbm tool) | Optional, for `make publish` | `brew install j4y-w4lk3r/bbm/bbm` |
| `bmcctl` v0.2.0+ | The other end of the pipeline | `brew install --cask j4y-w4lk3r/bmcctl/bmcctl` |

You do **not** need an Arch Linux host. The whole build runs inside a stock `archlinux:latest` container so this works fine from macOS.

## End-to-end walkthrough

### 1. Define a host

```bash
cd bmcctl/iso-build
cp hosts/example.toml hosts/nas.toml
$EDITOR hosts/nas.toml
```

The TOML carries everything the installer needs: hostname, target disk, timezone, your username, your SSH public key path, and an optional sudo password hash. See comments in `hosts/example.toml` for every field.

### 2. Validate

```bash
make validate
# runs shellcheck + bash -n on every script in the tree.
```

### 3. Build the ISO

```bash
colima start                # if not already running
make iso HOST=nas
```

What happens:

1. `render-config.sh` converts `hosts/nas.toml` into a bash-sourceable env file plus copies your SSH pubkey into the staged airootfs.
2. `build.sh` spawns an `archlinux:latest` container, installs `archiso`, copies upstream `releng` to a work dir, overlays our customizations, runs `mkarchiso`.
3. Output: `out/bmcctl-installer-nas-2026.06.04-x86_64.iso` (and an `.sha256` next to it).

Expect 5-10 minutes the first time (most of it is `pacman -Sy` inside the container); subsequent builds reuse the layer cache.

### 4. Publish so the BMC can fetch it

The BMC's VirtualMedia.InsertMedia needs a URL it can reach. For homelab use, the cleanest pattern is the same B2 bucket your `bbm` workflows already use:

```bash
make publish HOST=nas
# uploads out/bmcctl-installer-nas-*.iso to b2://j4y-bu/iso/
# prints the public URL for `bmcctl install-arch`.
```

If the bucket isn't public, you can either generate a presigned URL (`bbm url ...`) or serve the ISO from a tiny in-LAN HTTP server next to the BMC.

### 5. Trigger the install

```bash
bmcctl install-arch nas \
    --iso https://j4y-bu.s3.eu-central-003.backblazeb2.com/iso/bmcctl-installer-nas-2026.06.04-x86_64.iso \
    --wait 30
```

`bmcctl install-arch` will:

1. Eject any stale media in CD1.
2. Mount your ISO via Redfish VirtualMedia.InsertMedia.
3. PATCH `/Systems/Self {Boot: Cd, Once}`.
4. Issue a `PowerCycle`.
5. Poll `/Systems/Self.PowerState` until the host comes up.

Open the BMC's KVM (`bmcctl kvm nas`) or attach a Serial Over LAN session to watch the install progress live — every line `install.sh` emits goes to both `tty0` and `ttyS0,115200`.

When the script finishes successfully it runs `systemctl poweroff`. The BMC will report `PowerState=Off`. That's your **"install really finished"** signal — distinct from "the host is just on with the live env still running".

To bring the new system up:

```bash
bmcctl power nas on
ssh <username>@nas.local         # authorized key from your TOML is already in place
```

## Safety rails

The installer is destructive. We've put several rails in place; **none** of them save you from a typo in `target_disk`, so triple-check.

| Rail | What it does |
|---|---|
| `wipe_disk = "yes"` required in TOML | `render-config.sh` refuses to render if missing or any other value |
| `install.sh` aborts if `WIPE_DISK != "yes"` | Belt-and-suspenders; even a hand-edited env can't bypass this |
| `install.sh` aborts if `TARGET_DISK` isn't a block device | Catches `nvme0n10` / `/dev/sdaa` typos that resolve to nothing |
| 10-second sleep with banner before sgdisk | Visible on SOL/KVM, gives a remote operator time to Ctrl-C |
| `set -euo pipefail` + ERR trap | Any failed command stops the script before subsequent destructive steps |
| Failure mode = drop to shell, NOT poweroff | The live env stays reachable so you can debug from SOL or by SSHing into the live ISO (your authorized key is in `/root/.ssh/authorized_keys`) |
| `Restart=no` on the systemd unit | One install attempt per boot; an infinite-loop bug can't trash a disk multiple times |
| Single-quote injection check on the SSH pubkey | Prevents a malformed pubkey from breaking out of the env file |

## Troubleshooting

**"build: docker daemon not reachable"** — `colima start` (or wherever your Docker daemon lives).

**"render-config: ssh pubkey not found"** — fix `[user].ssh_pubkey_file` in your host TOML; the path is expanded with `~` -> `$HOME` and otherwise resolved relative to `iso-build/`.

**"mkarchiso completed but no ISO appeared"** — almost always a permissions issue on `out/`. Check `ls -la out/`; the build runs in `--privileged` mode so it can do a lot, but it can't punch through a read-only mount.

**Install fails halfway through, host is stuck on the live ISO** — that's the **expected** failure mode. SSH in (`ssh root@<host-ip>` with your authorized key) or use SOL/KVM. Logs are at `/var/log/bmcctl-install.log`; `journalctl -u bmcctl-installer.service` shows the systemd view. Re-run the install with `systemctl restart bmcctl-installer.service`.

**Install succeeds but the box doesn't poweroff** — almost always means the ISO is still inserted and the host is doing a normal POST -> live ISO loop. After `bmcctl install-arch` completes, run `bmcctl eject-iso <host>` once you've confirmed `PowerState=Off`.

## Future work

- **Built-in `bmcctl iso-build LABEL`** subcommand that wraps `make iso HOST=LABEL` so the whole flow is reachable from one CLI. Trivial; deferred until the build is more battle-tested.
- **LUKS / btrfs / zfs** layouts. Today's `install.sh` does plain GPT + ext4; LUKS root with TPM-bound auto-unlock is the natural next step for the NAS.
- **In-cluster HTTP server**. Right now the BMC fetches over public B2; for a fully air-gapped homelab we'd add a tiny static HTTP server on a known LAN IP and have `make publish` push there instead.
- **Per-host package layering via TOML inheritance** so `hosts/nas.toml` can extend a `hosts/_base.toml` instead of duplicating common fields.
