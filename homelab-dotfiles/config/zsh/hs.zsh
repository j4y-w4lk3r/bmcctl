# hs.zsh — Headscale tailnet SSH picker (via Tailscale client + fzf).
#
# Architecture (read this once):
#   Headscale  = your control server (hs.d0j0.dev) — runs on the VPS only
#   Tailscale  = client on each device — creates WireGuard tunnels + peer list
#   hs         = picks a peer from `tailscale status` and runs ssh
#
# You migrated OFF Tailscale's cloud, not off the Tailscale client.
# Every device still runs `tailscale up --login-server=https://hs.d0j0.dev`.
#
#   hs                     fzf peers → ssh as j4y (default)
#   hs root                fzf → ssh as root
#   hs -u [user]           fzf-pick SSH user (or preset), then peers
#   hs status              show tailnet + control server
#   hs key [24h]           create Headscale preauth key (via VPS)
#   hs -o ForwardAgent=yes extra ssh(1) args after flags
#
# Default SSH user: TS_SSH_USER, else j4y.
# User list for -u / Ctrl-U: HS_SSH_USERS (default: j4y root wgm0).
# Headscale admin SSH host: HS_CONTROL_SSH (default: j4y-control-01-root).
#
# Sourced from .zshrc:
#   [ -f ~/.config/zsh/hs.zsh ] && source ~/.config/zsh/hs.zsh

_hs_require() {
  command -v fzf >/dev/null 2>&1 || {
    print -u2 "hs: fzf not in PATH (install: brew install fzf)"
    return 1
  }
  command -v tailscale >/dev/null 2>&1 || {
    print -u2 "hs: tailscale CLI not found (still required — it's the mesh client)"
    return 1
  }
}

_hs_control_url() {
  if command -v jq >/dev/null 2>&1; then
    tailscale debug prefs 2>/dev/null | jq -r '.ControlURL // empty'
  else
    tailscale debug prefs 2>/dev/null | sed -n 's/.*"ControlURL": "\([^"]*\)".*/\1/p'
  fi
}

_hs_control_label() {
  local url="$(_hs_control_url)"
  if [[ -z "$url" || "$url" == "https://controlplane.tailscale.com" ]]; then
    print -r -- "Tailscale cloud"
  else
    print -r -- "Headscale ($url)"
  fi
}

_hs_status() {
  _hs_require || return 1
  local url ip ctrl peers
  url=$(_hs_control_url)
  ip=$(tailscale ip -4 2>/dev/null)
  ctrl=$(_hs_control_label)
  if command -v jq >/dev/null 2>&1; then
    peers=$(tailscale status --json 2>/dev/null | jq '(.Peer // {}) | length')
  else
    peers=$(tailscale status 2>/dev/null | awk '$1 ~ /^100\./ {c++} END {print c+0}')
    (( peers > 0 )) && (( peers-- ))
  fi
  print -r -- "Control:  ${ctrl}"
  [[ -n "$url" ]] && print -r -- "URL:      ${url}"
  print -r -- "This host: ${ip:-?} ($(tailscale status --self 2>/dev/null | awk '{print $2}'))"
  print -r -- "Peers:    ${peers}"
  if (( peers == 0 )); then
    print -r -- ""
    print -r -- "No other devices yet. Join one with:"
    print -r -- "  hs key          # create invite key"
    print -r -- "  # on new device:"
    print -r -- "  sudo tailscale up --login-server=${url:-https://hs.d0j0.dev} --authkey=hskey-auth-..."
  fi
}

_hs_preauth_key() {
  local exp="${1:-24h}" host out key
  host="${HS_CONTROL_SSH:-j4y-control-01-root}"
  command -v ssh >/dev/null 2>&1 || {
    print -u2 "hs: ssh not found"
    return 1
  }
  print -u2 "hs: creating preauth key on ${host} (expires ${exp})..."
  out=$(ssh -o BatchMode=yes "$host" "headscale preauthkeys create --user 1 --expiration ${exp} -o json" 2>&1) || {
    print -u2 "hs: failed: ${out}"
    return 1
  }
  if command -v jq >/dev/null 2>&1; then
    key=$(print -r -- "$out" | jq -r '.key // empty')
  else
    key=$(print -r -- "$out" | sed -n 's/.*"key": "\([^"]*\)".*/\1/p')
  fi
  [[ -n "$key" ]] || {
    print -u2 "hs: could not parse key from server"
    print -r -- "$out"
    return 1
  }
  print -r -- "$key"
  print -u2 ""
  print -u2 "On the new device:"
  print -u2 "  sudo tailscale up --login-server=$(_hs_control_url) --authkey=${key} --accept-routes --accept-dns"
}

_hs_join_pikvm() {
  local host="${HS_PIKVM_HOST:-192.168.1.42}"
  local hostname="${HS_PIKVM_TAILNET_NAME:-j4ypikvm0}"
  local authkey pass

  command -v op >/dev/null 2>&1 || { print -u2 "hs: op CLI required"; return 1 }
  command -v sshpass >/dev/null 2>&1 || { print -u2 "hs: pacman -S sshpass"; return 1 }

  pass=$(op read 'op://g3irkmq3taou5ko6gwxwlkcjd4/j4ypi0-root/password') || return 1
  print -u2 "hs: creating 1h invite key..."
  authkey=$(_hs_preauth_key 1h) || return 1
  print -u2 "hs: joining ${host} as ${hostname} on Headscale..."

  SSHPASS=$pass sshpass -e ssh \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=15 \
    "root@${host}" \
    "systemctl enable --now tailscaled 2>/dev/null; tailscale logout 2>/dev/null; tailscale up --reset --force-reauth --login-server=https://hs.d0j0.dev --authkey=${authkey} --accept-routes --accept-dns --ssh --hostname=${hostname} && echo joined: \$(tailscale ip -4)"
}

_hs_pick_user() {
  local current="${1:-j4y}" picked
  local -a users
  users=(${=HS_SSH_USERS:-j4y root wgm0})

  picked=$(
    for u in "${users[@]}"; do
      if [[ "$u" == "$current" ]]; then
        printf '%s\t(default)\n' "$u"
      else
        printf '%s\t\n' "$u"
      fi
    done | fzf \
      --delimiter=$'\t' --with-nth=1,2 \
      --prompt="ssh user> " \
      --header="Pick SSH user • type any name + Enter • Esc=cancel" \
      --height=40% --reverse --border \
      --query="$current" \
      --bind 'enter:accept-or-print-query'
  ) || return 1

  picked="${picked%%$'\t'*}"
  [[ -n "$picked" ]] || return 1
  print -r -- "$picked"
}

_hs_peers_raw() {
  if command -v jq >/dev/null 2>&1; then
    command tailscale status --json 2>/dev/null | jq -r '
      .Self as $self
      | [
          ((.Peer // {}) | to_entries[] | .value)
        ][]
        | select((.TailscaleIPs // []) | length > 0)
        | select(.ID != $self.ID)
        | [
            (if .Online then 0 else 1 end),
            .TailscaleIPs[0],
            (.HostName // ((.DNSName // "") | sub("\\..*"; "")) | if . == "" then "?" else . end),
            (.OS // "?"),
            (if .Online then "online" else "offline" end)
          ] | @tsv
    ' | LC_ALL=C sort -n -t $'\t' -k1,1 | cut -f2-
  else
    command tailscale status 2>/dev/null | awk '
      $1 ~ /^100\./ && NF >= 4 {
        ip = $1; host = $2; os = $4
        status = $5; for (i = 6; i <= NF; i++) status = status " " $i
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", status)
        on = (status ~ /offline|not active/) ? 1 : 0
        printf "%d\t%s\t%s\t%s\t%s\n", on, ip, host, os, status
      }' | LC_ALL=C sort -n -t $'\t' -k1,1 | cut -f2-
  fi
}

_hs_peers_pretty() {
  local ic_mac=$'\uf179' ic_linux=$'\uf303' ic_win=$'\uf247' ic_ios=$'\uf179' ic_other=$'\uf0a2'
  local ic_on=$'\uf00c' ic_off=$'\uf00d'

  awk -F'\t' -v ic_mac="$ic_mac" -v ic_linux="$ic_linux" -v ic_win="$ic_win" \
              -v ic_ios="$ic_ios" -v ic_other="$ic_other" \
              -v ic_on="$ic_on" -v ic_off="$ic_off" '
    BEGIN {
      reset = "\033[0m"
      dim = "\033[2m"
    }
    function os_icon(os,    o) {
      o = tolower(os)
      if (o ~ /mac/)  return "\033[38;5;245m" ic_mac "\033[0m"
      if (o ~ /linux/) return "\033[38;5;33m" ic_linux "\033[0m"
      if (o ~ /windows/) return "\033[38;5;111m" ic_win "\033[0m"
      if (o ~ /ios/) return "\033[38;5;141m" ic_ios "\033[0m"
      return "\033[38;5;243m" ic_other "\033[0m"
    }
    function os_label(os,    o) {
      o = tolower(os)
      if (o ~ /mac/) return "macOS"
      if (o ~ /linux/) return "Arch"
      if (o ~ /windows/) return "Windows"
      if (o ~ /ios/) return "iOS"
      return os
    }
    function state_icon(st) {
      if (st == "online") return "\033[38;5;108m" ic_on "\033[0m"
      return "\033[38;5;203m" ic_off "\033[0m"
    }
    function paint_host(on, host) {
      if (on == "online") return sprintf("\033[38;5;87m%s%s", host, reset)
      return sprintf("%s%s%s", dim, host, reset)
    }
    {
      ip = $1; host = $2; os = $3; st = $4
      line = sprintf("%-15s  %s  %-7s  %s  %s",
        ip, os_icon(os), os_label(os), state_icon(st), paint_host(st, host))
      printf "%s\t%s\n", ip, line
    }
  '
}

_hs_pick_host() {
  local ssh_user="$1"
  local peers key line ip ctrl

  ctrl=$(_hs_control_label)
  peers=$(_hs_peers_raw)
  [[ -n "$peers" ]] || {
    print -u2 "hs: no tailnet peers yet (${ctrl})"
    print -u2 "hs: run \`hs status\` or \`hs key\` to add devices"
    return 1
  }

  while true; do
    line=$(
      print -r -- "$peers" | _hs_peers_pretty | fzf \
        --ansi \
        --delimiter=$'\t' --with-nth=2 \
        --height=50% --reverse --border \
        --header=$"user: ${ssh_user}  •  ${ctrl}  •  Enter=ssh  •  Ctrl-U/Alt-U=change user  •  Esc=cancel" \
        --preview=$'printf "tailscale ssh %s@{1}\n\nIP:\t{1}\n" "'"${ssh_user}"'"' \
        --bind 'ctrl-u:accept,alt-u:accept' \
        --expect=ctrl-u,alt-u
    ) || return 0

    key="${line%%$'\n'*}"
    line="${line#*$'\n'}"
    if [[ "$key" == "ctrl-u" || "$key" == "alt-u" ]]; then
      ssh_user=$(_hs_pick_user "$ssh_user") || return 0
      continue
    fi

    [[ -n "$line" ]] || return 0
    ip="${line%%$'\t'*}"
    [[ -n "$ip" ]] || return 0
    print -r -- "${ssh_user}	${ip}"
    return 0
  done
}

hs() {
  case "${1:-}" in
    status|st)
      shift
      _hs_status "$@"
      return
      ;;
    key|keys|preauth)
      shift
      _hs_preauth_key "${1:-24h}"
      return
      ;;
    join-pikvm|join-j4ypi0)
      shift
      _hs_join_pikvm "$@"
      return
      ;;
  esac

  _hs_require || return 1

  local ssh_user="${TS_SSH_USER:-j4y}"
  local pick_user=false
  local -a ssh_args=()

  while (( $# > 0 )); do
    case "$1" in
      -u|--user)
        pick_user=true
        shift
        if [[ -n "${1:-}" && "$1" != -* ]]; then
          ssh_user="$1"
          shift
        fi
        ;;
      -h|--help)
        cat <<'EOF'
hs — Headscale tailnet SSH picker (uses Tailscale client for peer list)

  hs                     fzf peers → ssh (default user: j4y)
  hs <user>              fzf → ssh as <user>
  hs -u [user]           pick SSH user (or set user), then peers
  hs status              tailnet info + control server
  hs key [1h]            create Headscale preauth key for a new device
  hs join-pikvm          join PiKVM (192.168.1.42) to Headscale as j4ypikvm0
  hs -o <opt>            extra ssh(1) option (repeatable)
  hs -h                  this help

Headscale vs Tailscale:
  Headscale = your server (hs.d0j0.dev) — admin only, runs on VPS
  Tailscale = client on Mac/phone/Pi — WireGuard mesh; still required
  hs        = SSH picker over the mesh (reads tailscale status)

Inside the peer picker:
  Enter                  ssh user@100.x
  Ctrl-U / Alt-U         change SSH user (type any name in the picker)
  Esc                    cancel

ENV
  TS_SSH_USER            default SSH user (fallback: j4y)
  HS_SSH_USERS           space-separated users for -u picker
  HS_CONTROL_SSH         SSH host for headscale admin (default: j4y-control-01-root)
EOF
        return 0
        ;;
      -o|-o*)
        if [[ "$1" == -o ]]; then
          shift
          [[ -n "$1" ]] || { print -u2 "hs: -o requires an argument"; return 1; }
          ssh_args+=(-o "$1")
        else
          ssh_args+=(-o "${1#-o}")
        fi
        shift
        ;;
      --) shift; ssh_args+=("$@"); break ;;
      -*) print -u2 "hs: unknown option: $1"; return 1 ;;
      *)
        ssh_user="$1"
        shift
        break
        ;;
    esac
  done

  ssh_args+=("$@")

  if $pick_user; then
    ssh_user=$(_hs_pick_user "$ssh_user") || return 0
  fi

  local picked user ip
  picked=$(_hs_pick_host "$ssh_user") || return 0
  [[ -n "$picked" ]] || return 0

  user="${picked%%$'\t'*}"
  ip="${picked#*$'\t'}"
  command tailscale ssh "${ssh_args[@]}" "${user}@${ip}"
}
