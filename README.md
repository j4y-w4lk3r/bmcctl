# bmcctl — AMI MegaRAC CLI for ASRock Rack BMCs

CLI for managing the **AMI MegaRAC** BMCs that ship on **ASRock Rack** server motherboards (e.g. `W680D4U-2L2T/G5`). Designed for lights-out management of a small homelab/server stack from a single laptop, with secrets backed by **1Password**.

The tool:

- Discovers BMCs on the LAN by TLS-cert fingerprint (no creds required).
- Performs first-time provisioning: generates a strong random password, sets it on the BMC via Redfish, stores it in 1Password.
- Handles day-to-day operations: power on/off/cycle/graceful, sensor readings, FRU inventory, "open KVM" shortcut, periodic password rotation.

Passwords are **never** written to local disk. The only persistent secret store is your 1Password vault; `bmcctl` reads from it on demand at every authenticated call.

## Why this exists

The AMI MegaRAC firmware ships in a state where `admin/admin` works but every authenticated endpoint is locked behind a forced password change. Doing this by hand for several boxes — picking a strong password, getting it into your password manager, then unlocking the BMC each time you want to power-cycle — is tedious and error-prone. This tool automates the whole flow.

## Prerequisites

```bash
brew install ipmitool                       # optional, used by `fru` and `mc`
brew install --cask 1password-cli           # required
op signin                                    # or enable Touch ID unlock
```

Go 1.22+ to build.

## Build

```bash
go build -o bmcctl ./cmd/bmcctl
# install to PATH
go install ./cmd/bmcctl
```

## Quick start

```bash
# 1. Find BMCs on the LAN (no creds needed)
bmcctl discover --cidr 192.168.1.0/24
# HOST          CERT SUBJECT
# 192.168.1.54  CN=ami.com,OU=MEGARAC,O=AMI,...
# 192.168.1.55  CN=ami.com,OU=MEGARAC,O=AMI,...

# 2. Provision each BMC (writes a 1Password Login item)
bmcctl init 192.168.1.54 --label router --vault Private --length 40
bmcctl init 192.168.1.55 --label nas    --vault Private --length 40

# 3. Check what got registered
bmcctl ls
# LABEL   HOST           BOARD              HOST MODEL          1P UUID
# router  192.168.1.54   ASRockRack ...     W680D4U-2L2T/G5     abcdef...
# nas     192.168.1.55   ASRockRack ...     W680D4U-2L2T/G5     fedcba...
```

## Daily commands

Use the `--label` you assigned (or the IP directly):

```bash
bmcctl info router                     # system + chassis + BMC summary
bmcctl power router status             # PowerState (On / Off)
bmcctl power nas graceful              # ACPI shutdown
bmcctl power router on                 # cold start
bmcctl power router cycle              # hard cycle
bmcctl sensors nas                     # temps + fan RPMs
bmcctl fru router                      # ipmitool fru print 0
bmcctl mc nas                          # ipmitool mc info
bmcctl kvm router                      # opens https://192.168.1.54/#/kvm
```

## Virtual media + boot override (Stream B)

Mount an installer ISO over Redfish and boot from it without touching the BIOS:

```bash
# Mount an installer ISO into the first CD/DVD VirtualMedia slot.
# The URL must be reachable from the BMC (HTTPS w/ public CA, or
# plain HTTP). BMCs typically can't follow redirects.
bmcctl mount-iso nas --url https://archlinux.example/iso/archlinux-x86_64.iso

# Eject everything currently mounted in the CD slot(s).
bmcctl eject-iso nas

# Set a one-shot boot override (default lifetime is "Once" — reverts
# after the next boot, exactly what you want for "boot installer once").
bmcctl boot nas cd
bmcctl boot nas pxe --continuous   # sticky: useful for fleet PXE imaging
bmcctl boot nas none               # clear any active override

# Orchestrate the full unattended-install dance:
#   eject -> mount ISO -> boot=cd-once -> power-cycle -> wait until host is up
bmcctl install-arch nas \
  --iso https://my-iso.example/archlinux-bmcctl.iso \
  --wait 30
# add --no-wait to fire-and-forget if your installer is fully unattended.
```

Under the hood every command speaks plain Redfish (`PATCH /Systems/Self {Boot}`, `POST /Managers/Self/VirtualMedia/<slot>/Actions/VirtualMedia.InsertMedia` and `…EjectMedia`). The PATCH carries the same `If-Match` ETag dance MegaRAC enforces for the password change, so it works against the real ASRock Rack firmware unmodified.

For a fully unattended Arch install, build a custom `archiso` ISO with an `airootfs/root/install.sh` that auto-runs on boot — equivalent to a kickstart/preseed/cloud-init for Red Hat / Debian / cloud worlds. `bmcctl install-arch` is just the deployment driver; it doesn't care which ISO you point it at.

## Rotating credentials

```bash
bmcctl rotate router                   # new pw on BMC + 1Password
bmcctl rotate router --length 48
```

The rotate flow generates a new password, sets it on the BMC, re-authenticates to verify, then `op item edit`s the existing 1Password item. If verification fails, the generated password is dumped to stderr so you can recover.

## Safety rails

- **TLS** — BMC certs are always self-signed; we skip verification but require the cert subject to contain `MEGARAC` before any destructive call, so we won't `PATCH` a random HTTPS service that happens to bind to the same IP.
- **First-run gate** — `init` refuses to PATCH if `admin/admin` no longer works on the target. This prevents accidental overwrites of an already-configured BMC. Use `--force` if you're sure.
- **Verification** — every password change is verified by re-authenticating. If verification fails, the generated password is printed to stderr.
- **1Password failure fallback** — if `op item create` errors after the password is already set on the BMC, the password is printed to stderr. Save it manually and re-create the 1Password item with `bmcctl rotate` later.

## Test lab

The project ships with a complete in-process test harness that exercises every interesting code path **without touching a real BMC or your real 1Password vault**.

```bash
go test ./...                  # 23 tests, ~1s
go test -v ./...
go test -cover ./...
go test -run InitFlow ./...    # just the integration scenarios
```

What runs:

| Layer | What's tested | How |
|---|---|---|
| `internal/bmc/password.go` | Length, character classes present, no ambiguous chars, no shell-bad chars, no collisions across 5 000 runs | Pure unit tests |
| `internal/bmc/config.go`   | Save/load round-trip, label-or-host lookup (case-insensitive), upsert preserves `InitializedAt`, remove | Pure unit tests against `t.TempDir()` |
| `internal/bmc/discover.go` | CIDR expansion, /24 boundaries (`.1`–`.254`), refusal of `/8` / `0.0.0.0/0` / IPv6 | Pure unit tests |
| `internal/bmc/client.go`   | Redfish error parsing (all three shapes MegaRAC returns), `IsPasswordChangeRequired`, `FormatPower` enum normalisation | Pure unit tests |
| `internal/bmc/api.go`      | `GetSystem` / `GetChassis` / `GetManager` / `SetPassword` / `Power` / `GetSensors` over a real TLS connection | Integration tests against `testmegarac` |
| **Full init flow**         | Service-root probe → `PasswordChangeRequired` gate → PATCH new pw → old creds rejected → new creds work → save in Memory backend → password round-trips | `TestInitFlow_HappyPath` |
| **Rotate flow**            | Two consecutive PATCHes, verify old pw rejected, new pw works, secrets backend reflects new pw | `TestInitFlow_RotatePassword` |
| **Already-initialized**    | `admin/admin` is rejected with a *plain 401*, not `PasswordChangeRequired` — this is what `bmcctl init`'s refuse-without-force check keys on | `TestInitFlow_FactoryReset` |
| **Power actions**          | Every `ResetType` (`On`/`ForceOff`/`GracefulShutdown`/`PowerCycle`/`ForceRestart`) | `TestPowerActions` |
| `internal/secrets/memory.go` | `Backend` contract: create / read / update / find / vault-scoping / not-found errors | Pure unit tests |

### How the mock works (`internal/bmc/testmegarac/`)

`testmegarac.New(opt)` spins up a real `net/http` HTTPS server on a random localhost port. The TLS cert is generated at start-up with a subject string containing `MEGARAC`, so the production client's `VerifyMegaRAC` safety check passes without any test-only hooks. The server exposes the same Redfish paths the real AMI MegaRAC firmware does:

- `GET /redfish/v1/` (open, no auth)
- `GET /redfish/v1/Systems/Self` (gated)
- `GET /redfish/v1/Chassis/Self` (gated)
- `GET /redfish/v1/Managers/Self` (gated)
- `GET /redfish/v1/Chassis/Self/Thermal` (gated)
- `PATCH /redfish/v1/AccountService/Accounts/4` (clears the gate)
- `POST /redfish/v1/Systems/Self/Actions/ComputerSystem.Reset` (gated)

"Gated" endpoints return the exact `Base.1.12.PasswordChangeRequired` error shape until a successful PATCH is observed. After that they answer normally with realistic-looking JSON (manufacturer `ASRockRack`, model `W680D4U-2L2T/G5`, CPU model configurable).

The mock also exposes test-only inspection methods (not part of `Backend`):
- `srv.Password()` — current admin password as the server sees it.
- `srv.Locked()` — gate state.
- `srv.PowerLog()` — every `ResetType` the server has been asked to perform, in order.

So a test can assert e.g. "after `bmcctl rotate`, the server's password matches what the Memory backend stores" without hand-rolling test harness state.

### How the secrets backend works (`internal/secrets/`)

The package defines a `Backend` interface with two implementations:

- `OnePassword{}` — the production backend, shells out to `op`.
- `*Memory` — the test backend, holds items in a map. Adds `PasswordOf`, `Snapshot`, `Len` for assertions.

The `bmcctl` binary uses `secrets.Default()` in `main.go` (returns `OnePassword{}`). Tests construct `secrets.NewMemory()` directly. They never collide.

### Adding more tests

If you ever want to reproduce a specific MegaRAC error shape you saw in the wild, you can either:

1. Extend `testmegarac.Server` with the new endpoint or error and add an integration test, or
2. For pure error-parsing logic, drop a fixture into `internal/bmc/client_test.go::TestParseRedfishError` — that's the simplest path.

## Recovering a lost password

If 1Password and the BMC's stored password disagree, or you lose your 1Password vault:

1. Short the **BMC clear jumper** (`BMC_RST` / `JIPMI`) on the motherboard for ~10 s. This factory-resets the BMC; `admin/admin` works again.
2. Re-run `bmcctl init <host> --label <name>`. The old 1Password item can be deleted manually.

(So the password is not "permanent" — it's just persistent across reboots until you reset the BMC.)

## File layout

```
bmcctl/
├── cmd/bmcctl/
│   └── main.go               # subcommand dispatch
├── internal/
│   ├── bmc/
│   │   ├── client.go         # Redfish HTTP client, TLS skip, RedfishError
│   │   ├── api.go            # GetSystem / GetChassis / SetPassword / Power / GetSensors
│   │   ├── discover.go       # concurrent LAN scan, MegaRAC cert match
│   │   ├── password.go       # crypto/rand password generator
│   │   ├── config.go         # ~/.config/bmcctl/hosts.json (non-secret)
│   │   ├── *_test.go         # unit + integration tests
│   │   └── testmegarac/
│   │       └── server.go     # in-process HTTPS mock of the AMI MegaRAC firmware
│   └── secrets/
│       ├── secrets.go        # Backend interface + Default()
│       ├── onepassword.go    # production Backend: shells out to `op`
│       ├── memory.go         # test Backend: in-memory map
│       └── memory_test.go
├── go.mod
└── README.md
```

## Local registry

Non-secret host info lives at `~/.config/bmcctl/hosts.json` (override with `BMCCTL_CONFIG=…`). Schema:

```json
{
  "hosts": [
    {
      "label": "router",
      "host": "192.168.1.54",
      "board_model": "ASRockRack W680D4U-2L2T/G5",
      "host_model": "...",
      "op_item_uuid": "abcd1234...",
      "op_vault": "Private",
      "username": "admin",
      "account_id": "4",
      "initialized_at": "2026-05-19T18:00:00Z",
      "updated_at": "2026-05-19T18:00:00Z"
    }
  ]
}
```

Passwords are never written here. They live exclusively in 1Password and are fetched per command via `op item get`.

## Tested against

- ASRock Rack **W680D4U-2L2T/G5** (Intel W680 chipset, AST2500/2600 BMC, MegaRAC SP-X firmware).

The Redfish endpoints used (`/redfish/v1/`, `/Systems/Self`, `/Chassis/Self`, `/Managers/Self`, `/AccountService/Accounts/4`, `/Systems/Self/Actions/ComputerSystem.Reset`) are standard DMTF Redfish and should also work on any other AMI MegaRAC-based BMC (Supermicro, Tyan, etc.) with at most minor account-ID tweaks via `--account`.
