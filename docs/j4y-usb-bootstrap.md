# j4y profile — start from the thumb drive

> Offline-first bootstrap for Layer 0 → Layer 1.  
> The USB is **not** the root of trust (your keys + passphrases are).  
> It is the **portable starting point** that survives “no network / fresh PC”.

---

## What you need (minimum to begin)

| Item | When | Role |
|------|------|------|
| **Fast USB-A/C stick** (64 GB+, USB 3.2) | **Day 0** | Public bootstrap + later `.age` backups |
| **PC (Arch)** | Day 0 | Run init script, key ceremony |
| **Token2 Bio** | Day 1 ceremony | Daily: FIDO + age + OpenPGP |
| **Mini-C** | Day 1 ceremony | Backup FIDO + OpenPGP clone + age #2 |
| Network | Day 2+ | Vaultwarden, VPS sync, `set.d0j0.dev` |

You can **prepare the USB today** with zero secrets. Keys arrive → **ceremony day**.

---

## USB layout (two zones)

```
J4Y-ROOT/                          ← label the stick J4Y-ROOT
├── START-HERE.txt                 ← human checklist
├── bootstrap/
│   ├── init-j4y.sh                ← main entry (from bmcctl)
│   ├── packages.txt               ← pacman list for ceremony machine
│   └── set.sh                     ← copy of homelab-dotfiles/set.sh
├── docs/
│   └── trust-architecture.md      ← layer map (public)
├── public/                        ← OK if stick is lost
│   ├── persona/j4y.env.example
│   ├── gpg/pubring/               ← public keys only (after ceremony)
│   └── age/*.txt                  ← age recipients ONLY (not identities)
├── vault/                         ← ciphertext ONLY
│   └── (empty until first backup)
└── ceremony/
    └── checklist.md               ← print or read on phone
```

**Never on USB in plaintext:** OpenPGP private keys, age identity files, VW master password, 1Password session, rclone.conf, SSH private keys.

---

## Phase 0 — Thumb drive only (no keys required)

**Goal:** stick becomes your offline “installer” for the j4y profile.

1. Plug in fast USB.
2. From bmcctl repo (format once):
   ```bash
   ./scripts/j4y-usb-init.sh /dev/sdX    # type YES
   ```
3. Day-to-day updates (no reformat):
   ```bash
   ./scripts/j4y-usb-sync.sh /run/media/$USER/J4Y-ROOT
   ```
4. Use the stick:
   ```bash
   cd /run/media/$USER/J4Y-ROOT
   ./run
   ```

Layout lives in repo template: `usb-j4y/`. Hidden state: `.j4y/version.json` (date `dd/mm/yyyy`), `.j4y/ceremony.json`, `.j4y/logs/`.

---

## Phase 1 — Key ceremony (Bio + Mini-C, one sitting)

**Goal:** Layer 0 exists; backups exist **before** you rely on Bio daily.

Do on a **trusted PC** with both keys plugged in. ~60–90 minutes.

### Order matters

```
1. token2-linux-setup.sh          # pcscd, udev, age plugin
2. FIDO PINs on Bio + Mini        # strong, different per key
3. OpenPGP: generate → Bio → clone to Mini
4. age identity on Bio            # bio-age setup
5. age identity on Mini           # second recipient for backups
6. Register Mini as FIDO backup   # on GitHub, VW (when live), etc.
7. Export public keys → USB public/
8. First encrypted backup → USB vault/*.age
9. Paper shard (optional)         # not full passwords on one sheet
```

### OpenPGP (high-value)

```bash
# generate off-card or on-card per your token2 docs
token2 openpgp          # confirm applet mode FIDO+PGP on Bio
gpg --card-status
# load subkeys to Mini (clone) — see ceremony/checklist.md
```

### age (medium archives)

```bash
token2 bio-setup        # Bio identity
# create Mini age identity (second device)
# encrypt test file to BOTH recipients:
#   age -R public/bio.age.pub -R public/mini.age.pub -o vault/test.age README.md
```

---

## Phase 2 — Software stack on PC (j4y daily machine)

**Goal:** working workstation profile, still local-first.

```bash
# from USB or network:
bash /path/to/J4Y-ROOT/bootstrap/init-j4y.sh
# or: curl -fsSL https://set.d0j0.dev | bash   (after network trust)
```

Installs: git, age, gpg, pcscd, Bitwarden CLI path, dotfiles, 1Password bootstrap.

**Trust rule from here:**

1. New secrets → **Vaultwarden** (when `vw.d0j0.dev` is live)
2. 1Password → mirror + bootstrap only
3. Export weekly → `vault/j4y-backup-YYYY-MM-DD.tar.age` on USB

---

## Phase 3 — Replicate ciphertext (5 places)

Same `.age` file, many locations:

| # | Place | When |
|---|-------|------|
| 1 | USB-A (this stick, `vault/`) | Weekly plug-in |
| 2 | USB-B cold safe | Monthly snapshot |
| 3 | NAS | Weekly cron/rsync |
| 4 | Backblaze | Weekly rclone |
| 5 | VPS `/var/backups/j4y/` | Weekly scp |

Encrypt **once** on your PC. Upload copies. Never upload plaintext.

---

## Fresh machine from USB only

```
1. Boot Arch (your ISO or stock)
2. Plug J4Y-ROOT + Bio (+ Mini for backup registration)
3. bash /mnt/usb/bootstrap/init-j4y.sh --offline
4. op signin (if j4y + network) OR skip on airgap
5. Log into Vaultwarden (master password + Bio)
6. Pull latest vault/*.age from NAS/B2 if USB is stale
```

---

## What goes where (quick map)

| Data | Bio | Mini | PC disk | USB public | USB vault | VPS/NAS/B2 |
|------|-----|------|---------|------------|-----------|------------|
| OpenPGP private | ✓ | clone | stub only | ✗ | ✗ | ✗ |
| age FIDO cred | ✓ | ✓ (2nd) | identity file | ✗ | ✗ | ✗ |
| FIDO passkeys | ✓ | backup reg | ✗ | ✗ | ✗ | ✗ |
| VW vault | ✗ | ✗ | app cache | ✗ | export .age | ✗ |
| Dotfiles/scripts | ✗ | ✗ | ✓ | ✓ copy | ✗ | git OK |
| GPG public keys | ✗ | ✗ | ✓ | ✓ | ✗ | optional |

---

## First action right now

**If you have a USB stick:** run `j4y-usb-init.sh` (Phase 0).  
**If keys are in hand:** read `ceremony/checklist.md` on the stick and do Phase 1 before storing real secrets anywhere.

Terminal map: `trustlay personas`  
Full architecture: `docs/trust-architecture.md`
