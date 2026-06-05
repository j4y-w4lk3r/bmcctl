# homelab-dotfiles

Dotfiles for **j4ymb0** (Mac), **j4yru0** (router), **j4yn0** (nas), **j4ywa0** (workstation).

## Source of truth: GitHub, not your Mac

```
Mac (edit configs)
    │  ./vendor-from-mac.sh
    ▼
homelab-dotfiles/config/   ← committed to github.com/j4y-w4lk3r/bmcctl
    │  ./sync.sh router nas
    ▼
router / nas (~/.config + ~/.zshrc)
```

After a Mac reset:

```bash
git clone https://github.com/j4y-w4lk3r/bmcctl.git
cd bmcctl/homelab-dotfiles
./restore-to-mac.sh
# re-add secrets manually or via 1Password:
#   ~/.config/rui/.env
#   ~/.config/rclone/rclone.conf
```

## Commands

| Command | Purpose |
|---------|---------|
| `./vendor-from-mac.sh` | Snapshot Mac → `config/` (run before commit) |
| `./restore-to-mac.sh` | After Mac reset: `config/` → `~/.config` |
| `./sync.sh router nas` | Deploy to servers (packages + configs) |
| `SKIP_DEPS=1 ./sync.sh router` | Configs only, no pacman |

## What never goes in git

- `config/rui/.env` — router passwords
- `config/rclone/rclone.conf` — B2 secret key
- `config/gh/hosts.yml` — gh auth tokens (in macOS keychain anyway)

Safe to commit: `bbm/config.toml` (uses `op://` references).

## Two zshrc variants

- `zshrc.mac` — full Mac version (vendored from `~/.zshrc`)
- `zshrc.linux` — Arch servers (no Homebrew, uses `platform.zsh`)
