# trust-layers.zsh — bootstrap trust model (tmux-safe, ASCII-first)
#
#   trustlay | tlay          layer stack (default)
#   trustlay flow            bootstrap phases
#   trustlay map             storage rules
#   trustlay personas        j4y / k4i / ny4 + Vaultwarden model
#
# Note: avoid bare `trust` — conflicts with p11-kit (/usr/bin/trust)

typeset -g _TL_INIT=0 _TL_COLORS=1

_tl_setup() {
  (( _TL_INIT )) && return 0
  _TL_INIT=1

  if [[ -n ${TMUX:-} ]] && [[ "${TERM:-}" != tmux* ]] && infocmp tmux-256color &>/dev/null; then
    export TERM=tmux-256color
  fi

  if [[ -n ${NO_COLOR:-} ]] || ! [[ -t 1 ]] || ! tput colors &>/dev/null || (( $(tput colors 2>/dev/null || echo 0) < 8 )); then
    _TL_COLORS=0
  fi
}

_tl_c() {
  if (( _TL_COLORS )); then
    printf '\033[%sm%s\033[0m' "$1" "$2"
  else
    printf '%s' "$2"
  fi
}

_tl_rule() {
  local title="$1" n i
  n=$(( ${COLUMNS:-$(tput cols 2>/dev/null || echo 72)} - 4 ))
  (( n < 40 )) && n=40
  (( n > 72 )) && n=72
  _tl_c '1;35' "  $title"
  printf '\n  '
  _tl_c '2' ''
  for (( i = 0; i < n; i++ )); do printf '-'; done
  printf '\n'
}

_tl_section() {
  local color="$1" title="$2"
  shift 2
  local item
  _tl_c "$color" "  > $title"
  printf '\n'
  for item in "$@"; do
    printf '      - %s\n' "$item"
  done
}

_tl_step() {
  _tl_c '2' '      |'
  printf '\n'
  _tl_c '2;37' "      v  $1"
  printf '\n'
}

trustlay() {
  emulate -L zsh
  setopt localoptions noerrexit
  _tl_setup

  local mode="${1:-stack}"

  case "$mode" in
    help|-h|--help|h)
      cat <<'EOF'
trustlay / tlay — bootstrap trust model (tmux-safe)

  trustlay              layer stack
  trustlay flow         bootstrap phases
  trustlay map          what goes on the internet vs local
  trustlay personas     j4y / k4i / ny4 profiles + VW layers
  tlay                  short alias

Avoid bare `trust` — that is p11-kit on Arch (/usr/bin/trust).
EOF
      return 0
      ;;

    flow|phases|bootstrap)
      _tl_rule 'BOOTSTRAP FLOW'
      printf '\n'
      _tl_section '1;36' 'Phase 1 - Boot & install' \
        'Boot custom Arch ISO (USB or B2 mirror)' \
        'Unattended pacstrap + first-boot packages' \
        'You: pick boot device once'
      _tl_step 'reboot'
      _tl_section '1;32' 'Phase 2 - First login' \
        'token2-linux-setup, bio-age harden' \
        'tailscale / headscale join' \
        'op signin  <- only secret you type'
      _tl_step '1Password session live'
      _tl_section '1;33' 'Phase 3 - Automated pull' \
        'homelab-ssh-key ensure, rclone from op' \
        'apply-local.sh (dotfiles + zsh)' \
        'mail / Revolut / apps from 1Password'
      _tl_step 'optional'
      _tl_section '1;34' 'Phase 4 - Cloud files' \
        'scp .age ciphertext from VPS' \
        'bad file.age (Token2 fingerprint)' \
        'identity file stays local'
      printf '\n'
      _tl_c '2' '  tip: '
      _tl_c '1' 'trustlay'
      _tl_c '2' ' for layers, '
      _tl_c '1' 'trustlay map'
      _tl_c '2' ' for storage rules'
      printf '\n\n'
      ;;

    map|storage|where)
      _tl_rule 'STORAGE MAP'
      printf '\n'
      _tl_c '1;32' '  OK on VPS / B2 / GitHub'
      printf '\n'
      printf '      - Custom Arch ISO (signed)\n'
      printf '      - Dotfiles + bootstrap scripts (no secrets)\n'
      printf '      - file.txt.age and other .age ciphertext\n'
      printf '\n'
      _tl_c '1;31' '  NEVER on VPS / public cloud'
      printf '\n'
      printf '      - fido-age-identity.txt\n'
      printf '      - op session / service tokens\n'
      printf '      - rclone.conf, SSH private keys\n'
      printf '      - Revolut / mail passwords in plaintext\n'
      printf '\n'
      _tl_c '1;33' '  PHYSICAL only (your pocket)'
      printf '\n'
      printf '      - Token2 Bio, YubiKeys\n'
      printf '      - 1Password Emergency Kit (backup)\n'
      printf '\n'
      ;;

    personas|profile|profiles|j4y|k4i|ny4)
      _tl_rule 'PERSONAS + SECRET LAYERS (L0-L3)'
      printf '\n'
      _tl_c '2;37' '  L0 root -> L1 Vaultwarden -> L1 archive (.age) -> L2 1Password -> L3 OpenBao'
      printf '\n\n'
      _tl_section '1;35' 'Layer 0 - Root (2-3 keys total, not 12)' \
        'Token2 Bio: daily j4y (+ extra FIDO creds per persona)' \
        'Mini backup key: 2FA backup for j4y + k4i' \
        'Optional ny4-only key: never touches j4y laptop' \
        'Per persona: separate VW master password (software)'
      _tl_step 'trust rule: new secrets -> Vaultwarden first'
      _tl_section '1;32' 'j4y - primary (ops root)' \
        'vw.d0j0.dev - mobile + desktop' \
        '1Password: bootstrap + mirror only' \
        'set.d0j0.dev, NAS, all 5 backup sites'
      _tl_section '1;33' 'k4i - lab / untrusted machine' \
        'VW account (same server OK); no 1Password on box' \
        'THM, CTFs, experiments - no j4y tailnet/NAS' \
        'QEMU VM or separate Linux user'
      _tl_section '1;34' 'ny4 - isolated / no mobile' \
        'Vaultwarden on separate VPS' \
        'USB bootstrap only; own tailnet or offline' \
        'USB-B cold + separate B2 bucket'
      printf '\n'
      _tl_c '2' '  full diagram: '
      _tl_c '1' '~/bmcctl/docs/trust-architecture.md'
      _tl_c '2' ' (Mermaid — preview in Cursor)'
      printf '\n\n'
      ;;

    stack|layers|""|*)
      _tl_rule 'TRUST LAYERS'
      printf '\n'
      _tl_c '2;37' '  trust increases upward'
      printf '\n\n'

      _tl_section '1;90' 'Layer 1 - INTERNET (untrusted)' \
        'Custom Arch ISO on B2 / USB' \
        'Git: bmcctl + homelab-dotfiles' \
        'Encrypted .age files on Hostinger VPS' \
        'Assume attacker can read all of this'
      _tl_step 'signed ISO, ciphertext only, no secrets in git'

      _tl_section '1;34' 'Layer 2 - FRESH MACHINE' \
        'Base Arch from your ISO' \
        'No credentials on disk yet' \
        'Tailscale / Headscale mesh'
      _tl_step 'first-boot.sh runs'

      _tl_section '1;33' 'Layer 3 - FIRST BOOT (one unlock)' \
        'op signin (1Password + your password)' \
        'Token2 fingerprint for bae / bad' \
        'YubiKey for SSH / passkeys / 2FA' \
        'Scripts pull everything else'
      _tl_step 'secrets land locally'

      _tl_section '1;32' 'Layer 4 - WORKSTATION (trusted)' \
        'SSH keys, rclone, mail, Revolut via op' \
        'bae / bad for sensitive files' \
        'op session in ~/.config/op/ (local only)'
      _tl_step 'root of trust'

      _tl_section '1;35' 'Layer 0 - YOU (physical)' \
        'Token2 Bio + YubiKeys in your pocket' \
        '1Password password in your head' \
        'Only enrolled fingerprints on the key'

      printf '\n'
      _tl_c '2' '  ---'
      printf '\n  '
      _tl_c '1;37' 'One-click reality: '
      _tl_c '2' 'boot ISO (auto) -> '
      _tl_c '1;33' 'op signin'
      _tl_c '2' ' (once) -> scripts finish the rest'
      printf '\n  '
      _tl_c '2' '---'
      printf '\n\n'
      _tl_c '2' '  more: '
      _tl_c '1' 'trustlay flow'
      _tl_c '2' ' | '
      _tl_c '1' 'trustlay map'
      printf '\n\n'
      ;;
  esac
}

tlay() { trustlay "$@" }

# Legacy name — p11-kit also ships /usr/bin/trust; function wins in zsh when sourced.
trust() { trustlay "$@" }
