# bmcctl homelab plan

Working plan for the two ASRock W680D4U boxes, two sites, IPMI/Redfish first.
PiKVM is fallback eyes only — not required for power, install, or day-to-day ops.

Last updated: 2026-08-29

---

## Principles

1. **BMC first** — power, sensors, virtual media, `install-arch` all go through Redfish (`bmcctl`).
2. **Site-local LAN hop** — a machine on the same LAN as the BMC runs commands (PiKVM at Warsaw; laptop or NAS at Wrocław).
3. **Secrets in 1Password only** — `hosts.json` holds labels + UUIDs, never passwords.
4. **PiKVM optional** — use only for blank disk, BIOS, or when Redfish cannot tell you enough.

---

## Inventory

| Label | Site | Role | BMC IP | Host IP | 1Password | Notes |
|-------|------|------|--------|---------|-----------|-------|
| `nas2` | Warsaw PLH1 | ASRock i5-13500 | `192.168.1.54` | TBD | `plh1-bmc` | Power **On**; **no OS on LAN** (Phase 3a) |
| `plh3-bmc` | Wrocław PLH3 | ASRock i7-14700 BMC | `192.168.1.13` | — | `plh3-bmc` | Power **On**; host at `.65` |
| `nas` | Wrocław PLH3 | NAS host (Arch) | — | `192.168.1.65` | — | `ssh nas` works |

Last updated: 2026-08-29 (Phase 1 + 3a done)

Remote hop: **pikvm1** (`100.64.0.8`, LAN `192.168.1.42`) for Warsaw.

---

## Done

- [x] `bmcctl` on NAS (Wrocław) — source at `~/px/x-j4y/bmcctl`
- [x] `bmcctl` cross-compiled + installed on **pikvm1** (`scripts/install-pikvm.sh`)
- [x] Remote wrapper from j4ywa0 (`scripts/bmcctl-via-pikvm.sh`) with local-`op` fallback
- [x] Warsaw BMC renamed **`ru0` → `nas2`** in `~/.config/bmcctl/hosts.json`
- [x] Verified Warsaw power state: **On** (via `./scripts/bmcctl-via-pikvm.sh power nas2 status`)
- [x] Wrocław NAS reachable: `ssh nas` / `100.64.0.5`

---

## Phase 1 — Registry & secrets cleanup

Goal: one clear label per box, no stale `.54`/`.55` confusion.

- [x] Save Wrocław BMC creds in 1Password as **`plh3-bmc`** (`https://192.168.1.13/`) — renamed from `bmc-55`
- [x] Add `plh3-bmc` entry to `hosts.json` on j4ywa0 + pikvm1
- [x] Rename 1Password item **`bmc-54` → `plh1-bmc`**
- [x] Remove legacy **`nas0` / `.55`** from `hosts.json` (`.55` not present on Warsaw LAN)
- [x] Add **`iso-build/hosts/nas2.toml`** (hostname `nas2`); deprecate `ru0.toml`
- [x] Document BMC IPs in **`plh1-orange-rui`** 1Password notes
- [x] Add `docs/hosts.example.json`

---

## Phase 2 — Remote ops (Warsaw from anywhere)

Goal: one-liner from j4ywa0, no manual SSH + curl.

- [ ] Extend `bmcctl-via-pikvm.sh` fallback: `info`, `sensors`, `discover` (not only power)
- [ ] Add `bmcctl site plh1 …` shell alias or zsh wrapper on j4ywa0 (calls via-pikvm)
- [ ] Optional: install `op` on pikvm1 (aarch64) so native `bmcctl` works without fallback
- [ ] Optional: persist `bmcctl` across PiKVM reboots (currently needs `rw` + reinstall if root goes ro)
- [ ] Add `hosts.json` example with PLH1/PLH3 labels in repo (`docs/hosts.example.json`)

---

## Phase 3 — Warsaw `nas2` bring-up

Goal: confirm whether Arch is installed; if not, unattended install via BMC only.

**3a — Discover current state (IPMI only)** — done 2026-08-29

- [x] `./scripts/bmcctl-via-pikvm.sh power nas2 status` → **On**
- [x] LAN scan from pikvm1: only BMC **`.54`** has Redfish; `.55`/`.65` absent on Warsaw LAN
- [x] FRU: board serial **M80-JAS00900163**, W680D4U-2L2T/G5, 32 GiB RAM, BIOS 23.02
- [x] Host NICs (Redfish): all **0.0.0.0** — OS not on network
- [x] Mellanox **`d0:ea:11:61:63:42`** seen link-local only (no host IPv4)
- [x] Virtual media **CD1**: empty, not inserted
- [x] **Conclusion: Arch not installed** (or not booted/configured) — ready for Phase 3b `install-arch`

**3b — If no OS (expected now)**

- [ ] Update `iso-build/hosts/nas2.toml` from `ru0.toml` (hostname `nas2`, Warsaw timezone, disk layout)
- [ ] Build ISO: `make iso HOST=nas2` (on NAS or j4ywa0 with Docker)
- [ ] Publish ISO to URL reachable by BMC (B2 / LAN HTTP — BMC cannot follow redirects)
- [ ] `bmcctl install-arch nas2 --iso <url> --wait 30` via pikvm1 wrapper
- [ ] Post-install: DHCP reservation on PLH1 Funbox for host MAC → stable IP
- [ ] Verify: `ssh j4y@<host-ip>`, Tailscale join if configured in ISO

**3c — If OS already present**

- [ ] Find host IP (router / `rui` / ARP scan from pikvm1)
- [ ] `ssh j4y@<ip>` — check `/etc/bmcctl-install-id`, `px/x-j4y` layout
- [ ] Register in Headscale / homelab registry if not already

---

## Phase 4 — Wrocław `nas` (mostly done)

Goal: keep NAS as the Wrocław build host; BMC ops when laptop is away.

- [ ] Register **`plh3-bmc`** in local `hosts.json`
- [ ] `bmcctl power plh3-bmc status` when off-site (needs LAN hop or future pikvm2 script)
- [ ] Mirror `install-pikvm.sh` for **pikvm2** if remote Wrocław BMC control needed from Warsaw
- [ ] Keep `bmcctl` binary on NAS updated (`git pull && go build`)

---

## Phase 5 — Nice-to-have (later)

- [ ] **`bmcctl screen <label>`** — grab PiKVM snapshot via KVMD API (fallback eyes in CLI)
- [ ] **`bmcctl host status <label>`** — combine BMC PowerState + LAN ping/SSH probe
- [ ] Integration with **rui** for DHCP reservations (separate tool; not required for BMC)
- [ ] Mac Mini M4 at Warsaw as always-on management node (Tailscale + bmcctl + op)
- [ ] Goreleaser arm64 release artifacts (skip local cross-compile)

---

## Quick commands (cheat sheet)

```bash
# Warsaw — from j4ywa0 (anywhere with Tailscale + 1Password)
cd ~/px/x-j4y/bmcctl
./scripts/bmcctl-via-pikvm.sh power nas2 status
./scripts/bmcctl-via-pikvm.sh power nas2 on

# (Re)install bmcctl on pikvm1 after PiKVM update
./scripts/install-pikvm.sh

# Wrocław — on LAN
ssh nas
bmcctl ls                                    # after plh3-bmc registered
ssh nas 'cd ~/px/x-j4y/bmcctl && git pull'

# Registry
bmcctl ls
cat ~/.config/bmcctl/hosts.json
```

---

## Open questions

1. **Warsaw host IP** — reserve on PLH1 Funbox once install MAC is known (likely Mellanox or onboard 10G).
2. ~~**`nas0` / `.55`**~~ — removed from registry; was stale (not on Warsaw LAN).
3. **ISO build machine** — NAS (Wrocław) vs j4ywa0 for `make iso HOST=nas2` (needs Docker + archiso).

---

## Not in scope (for now)

- PiKVM-first install workflows
- Router API / `rui` on PiKVM
- Running Warsaw `bmcctl` from Wrocław NAS (different LAN — will not work)
