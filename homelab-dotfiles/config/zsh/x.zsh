# x.zsh — unified fzf launcher for custom shell tools.
#
#   x                 fzf-pick a tool → Enter runs it (groups open a sub-menu)
#   x help            show launcher keybindings
#
# Inside fzf:
#   Enter     run the tool (or open a group sub-menu)
#   Ctrl-H    print full help to pager
#   Ctrl-Y    copy run command to clipboard
#   Esc       cancel
#
# Catalog columns (TAB-separated, hidden after col 3):
#   category  cmd  title  run_command  help_key
#   run_command @group  → opens sub-menu for that group

_x_zsh="${0:A}"
_x_require_fzf() {
  command -v fzf >/dev/null 2>&1 || {
    print -u2 "x: fzf not in PATH (install: brew install fzf)"
    return 1
  }
}

_x_strip_ansi() {
  sed $'s/\x1b\\[[0-9;]*m//g'
}

_x_tools_data() {
  cat <<'EOF'
󰋊 cloud	bb	Backblaze B2 via rclone	bb menu	bb
󰏗 system	brs	Homebrew sync (update · upgrade · clean)	brs	brs
󰆍 dev	dev	Dev tools (agent · pxc)	@dev	dev
󰊤 github	gh	Git & GitHub tools	@github	github
󰘦 tmux	tmux	Tmux sessions & reload	@tmux	tmux
󰛳 network	hs	Tailscale / Headscale SSH picker	hs	hs
󰛳 network	hlreg	Homelab host registry (VPS)	hlreg	hlreg
󰙰 files	files	Files & archives	@files	files
󰌾 security	yk	YubiKey manager (ykman + fzf)	yk	yk
󰋼 docs	docs	Help & logs	@docs	docs
󰑐 shell	shell	Reload zshrc	@shell	shell
EOF
}

_x_github_tools_data() {
  cat <<'EOF'
󰊤 github	gid	Switch git / gh account	gid	gid
󰊤 github	ggm	My repos — browse · clone · view	ggm	ggm
󰊤 github	ggf	Transfer repo to another account	ggf	ggf
󰊤 github	gscan	Compare repos local vs remote machine	gscan	gscan
󰊤 github	gbr	Rename branches (local + GitHub remote)	gbr	gbr
󰊤 github	ggs	Starred repos — browse · clone · unstar	ggs -b	ggs
󰊤 github	gga	Search public GitHub repos	gga -h	gga
EOF
}

_x_tmux_tools_data() {
  cat <<'EOF'
󰘦 tmux	jay	New tmux session from profile	jay	jay
󰘦 tmux	jaya	Attach to a running tmux session	jaya	jaya
󰘦 tmux	srall	Reload zshrc in all tmux shell panes	srall	srall
EOF
}

_x_files_tools_data() {
  cat <<'EOF'
󰙰 files	ff	File picker → Cursor or nvim	ff	ff
󰙰 files	y	Yazi terminal file manager	y	y
󰙰 files	ic	Image format converter (sips + fzf)	ic	ic
󰙰 files	extract	Universal archive extractor	extract	extract
EOF
}

_x_dev_tools_data() {
  cat <<'EOF'
󰆍 dev	agent	Cursor Agent (auto-trust workspace)	agent	agent
󰆍 dev	pxcc	PXC client (Go)	pxcc	pxcc
󰆍 dev	pxcr	PXC runner (Go)	pxcr	pxcr
EOF
}

_x_docs_tools_data() {
  cat <<'EOF'
󰋼 docs	zhelp	Zshrc cheatsheet (aliases · functions)	zhelp	zhelp
󰋼 docs	cmdhist	Browse saved command logs	cmdhist	cmdhist
EOF
}

_x_shell_tools_data() {
  cat <<'EOF'
󰑐 shell	sr	Reload ~/.zshrc	sr	sr
󰑐 shell	crs	Reload zshrc · clear · reset	crs	crs
EOF
}

_x_group_data() {
  case "$1" in
    github) _x_github_tools_data ;;
    tmux)   _x_tmux_tools_data ;;
    files)  _x_files_tools_data ;;
    dev)    _x_dev_tools_data ;;
    docs)   _x_docs_tools_data ;;
    shell)  _x_shell_tools_data ;;
    *)
      print -u2 "x: unknown group: $1"
      return 1
      ;;
  esac
}

_x_tool_help() {
  local key="${1:-}"
  case "$key" in
    bb)
      if typeset -f bb >/dev/null 2>&1; then
        bb help 2>/dev/null
      else
        cat <<'EOF'
bb — Backblaze B2 helpers via rclone

  bb menu              Interactive menu (recommended)
  bb push <src>        Upload (additive)
  bb pull <name>       Download
  bb ls [path]         List contents
  bb sync <src>        Mirror (destructive — confirms first)
  bb use <bucket>      Switch bucket
  bb help              Full usage
EOF
      fi
      ;;
    brs)
      cat <<'EOF'
brs — Brew Sync

  Full Homebrew maintenance pipeline with gum UI:
    1. brew update
    2. brew upgrade --formula
    3. brew upgrade --cask --greedy
    4. brew autoremove
    5. Fix old-keg permissions (sudo)
    6. brew cleanup

  Requires sudo. Logs: /tmp/brs/brs-*.log
EOF
      ;;
    agent)
      cat <<'EOF'
agent / a — Cursor Agent with workspace auto-trust

  agent [args…]        Launch Cursor agent (trusts cwd first)
  a                    Alias for agent

  Trust is stored in ~/.cursor/projects/<slug>/.workspace-trusted
  Every cd also trusts the new directory (chpwd hook).
EOF
      ;;
    github)
      cat <<'EOF'
Git & GitHub — press Enter to open sub-menu

  gid    Switch git author + gh account (fzf)
  ggm    My repos — browse · clone · view · transfer (Ctrl-T)
  ggf    Transfer a repo to another saved account (auto-accept + detach)
  gscan  Compare repos Mac vs Arch (SYNC / DRIFT)
  gbr    Rename branches locally + on GitHub (fzf, batch pairs)
  ggs    Starred repos — browse · clone · unstar
  gga    Search public repos — browse · star
EOF
      ;;
    gid)
      if typeset -f gid >/dev/null 2>&1; then gid -h; else
        cat <<'EOF'
gid — git/gh account manager

  gid                  fzf-pick + switch (default)
  gid w                show current git + gh identity
  gid l                list saved accounts
  gid add              add account row
  gid login [user]     gh auth login + append to TSV
  gid edit             open ~/.config/git-accounts.tsv
EOF
      fi
      ;;
    ggm)
      if typeset -f ggm >/dev/null 2>&1; then ggm -h; else
        print "ggm — GitHub My repos (interactive fzf browser)"
      fi
      ;;
    ggf)
      if typeset -f ggf >/dev/null 2>&1; then ggf -h; else
        print "ggf — GitHub repo transfer to another account"
      fi
      ;;
    gscan)
      if typeset -f gscan >/dev/null 2>&1; then gscan -h 2>/dev/null || print "gscan — compare repos Mac vs Arch"; else
        print "gscan — compare repos Mac vs Arch (SYNC / DRIFT)"
      fi
      ;;
    gbr)
      if typeset -f gbr >/dev/null 2>&1; then gbr -h; else
        print "gbr — rename git branches (local + GitHub remote)"
      fi
      ;;
    ggs)
      if typeset -f ggs >/dev/null 2>&1; then ggs -h; else
        print "ggs — GitHub Stars manager"
      fi
      ;;
    gga)
      if typeset -f gga >/dev/null 2>&1; then gga -h; else
        print "gga — GitHub repo search"
      fi
      ;;
    tmux)
      cat <<'EOF'
Tmux — press Enter to open sub-menu

  jay     New session from profile (fzf profile → session)
  jaya    Attach to running session
  srall   Reload zshrc in all tmux shell panes
EOF
      ;;
    files)
      cat <<'EOF'
Files — press Enter to open sub-menu

  ff       File picker → Cursor / nvim
  y        Yazi file manager
  ic       Image format converter
  extract  Universal archive extractor
EOF
      ;;
    dev)
      cat <<'EOF'
Dev — press Enter to open sub-menu

  agent    Cursor Agent (auto-trust workspace)
  pxcc     PXC client
  pxcr     PXC runner
EOF
      ;;
    docs)
      cat <<'EOF'
Docs — press Enter to open sub-menu

  zhelp    Zshrc cheatsheet (aliases · functions · keys)
  cmdhist  Browse saved command logs
EOF
      ;;
    shell)
      cat <<'EOF'
Shell — press Enter to open sub-menu

  sr       Reload ~/.zshrc
  crs      Reload zshrc · clear · reset
EOF
      ;;
    ic)
      cat <<'EOF'
ic — Image converter

  ic                   fzf: pick output format → multi-select images → convert
  Uses macOS sips. Scans cwd tree (fd or find).
EOF
      ;;
    jay)
      cat <<'EOF'
jay — tmux session launcher

  jay                  fzf profile → fzf session name → attach or create
  Profiles: ~/.config/jay/profiles/*.zsh
  Each profile defines jay_profile_setup <session>.
EOF
      ;;
    jaya)
      cat <<'EOF'
jaya — attach to tmux session

  jaya                 fzf over running sessions (auto if only one)
EOF
      ;;
    srall)
      cat <<'EOF'
srall — reload shells in tmux

  srall                Send `sr` to every zsh/bash/sh/fish pane in tmux
EOF
      ;;
    hs)
      cat <<'EOF'
hs — Tailscale / Headscale SSH picker

  hs                     fzf peers → ssh (default user: j4y)
  hs <user>              fzf → ssh as <user>
  hs -u                  pick SSH user first, then peers
  hs -o ForwardAgent=yes extra ssh(1) args

Inside peer picker:
  Enter                  ssh user@100.x
  Ctrl-U                 change SSH user
  Esc                    cancel

  export TS_SSH_USER=j4y
  export HS_SSH_USERS="j4y root wgm0"
EOF
      ;;
    hlreg)
      cat <<'EOF'
hlreg — homelab host registry on VPS

  hlreg push             report this host to ~/homelab/hosts.json on VPS
  hlreg ls               list registered hosts
  hlreg show [name]      show one host record

  export HLREG_HOST=j4y-control-01
EOF
      ;;
    ff)
      cat <<'EOF'
ff — file picker

  ff                   fzf files in cwd tree
  Enter                open in Cursor
  Ctrl-O               open in nvim
  Ctrl-Y               copy full path to clipboard
EOF
      ;;
    y)
      cat <<'EOF'
y — Yazi file manager

  y [args…]            Launch yazi; cd follows yazi's cwd on exit
EOF
      ;;
    pxcc)
      cat <<'EOF'
pxcc — PXC client

  pxcc                 Source pxc env, run pxc_c.go, return to $HOME
EOF
      ;;
    pxcr)
      cat <<'EOF'
pxcr — PXC runner

  pxcr                 Source pxc env, run pxc_r.go, return to $HOME
EOF
      ;;
    yk)
      if typeset -f yk >/dev/null 2>&1; then yk -h; else
        cat <<'EOF'
yk — YubiKey manager

  yk                   fzf key → fzf action
  yk add               tag a connected key
  yk gen-sk <label> <purpose>   ed25519-sk SSH key on YubiKey

  Config: ~/.config/yubikeys.tsv
  (Enable in ~/.zshrc: source ~/.config/zsh/yubikey.zsh)
EOF
      fi
      ;;
    zhelp)
      cat <<'EOF'
zhelp — Zshrc cheatsheet

  zhelp                All aliases, functions, keybindings from ~/.zshrc
  Rendered with bat in a pager.
EOF
      ;;
    cmdhist)
      cat <<'EOF'
cmdhist — command log browser

  cmdhist              fzf over ~/terminal_logs → less selected log
EOF
      ;;
    sr)
      cat <<'EOF'
sr — reload shell config

  sr                   source ~/.zshrc && clear
EOF
      ;;
    crs)
      cat <<'EOF'
crs — hard reload shell

  crs                  source ~/.zshrc && clear && reset
EOF
      ;;
    extract)
      cat <<'EOF'
extract — universal archive extractor

  extract <file>       tar · zip · 7z · rar · gz · bz2 · xz …
EOF
      ;;
    *)
      print -u2 "x: unknown help key: $key"
      return 1
      ;;
  esac
}

_x_help() {
  cat <<'EOF'
x — unified tool launcher (fzf)

USAGE
  x                     Open the tool picker
  x help | -h           This message
  x list                Show top-level catalog

INSIDE FZF
  Enter                 Run tool (groups open a sub-menu)
  Ctrl-H                Print full help (pager)
  Ctrl-Y                Copy run command to clipboard
  Esc                   Cancel

GROUPS
  gh / github           gid · ggm · ggf · gscan · gbr · ggs · gga
  tmux                  jay · jaya · srall
  files                 ff · y · ic · extract
  dev                   agent · pxcc · pxcr
  docs                  zhelp · cmdhist
  shell                 sr · crs

TIP
  Type to filter (e.g. "github", "tmux", "bb").
  Preview pane shows activation command + usage.
EOF
}

_x_format_row() {
  awk -F'\t' '{
    c1 = sprintf("%-22s", $1)
    c2 = sprintf("%-10s", $2)
    printf "\033[1;33m%s\033[0m\t\033[1;36m%s\033[0m\t%s\t%s\t%s\n", c1, c2, $3, $4, $5
  }'
}

_x_align_help() {
  local width=24 line trimmed
  while IFS= read -r line; do
    if [[ "$line" == '  '* ]]; then
      trimmed="${line#  }"
      if [[ "$trimmed" =~ '^(.+)  +(.+)$' ]]; then
        printf '  %-*s %s\n' "$width" "$match[1]" "$match[2]"
        continue
      fi
    fi
    print -r -- "$line"
  done
}

_x_parse_line() {
  local raw="$1"
  raw="${raw//$'\r'/}"
  raw="$(print -r -- "$raw" | _x_strip_ansi)"
  typeset -g _x_category _x_cmd _x_title _x_run _x_help_key
  IFS=$'\t' read -r _x_category _x_cmd _x_title _x_run _x_help_key <<< "$raw"
}

_x_preview_line() {
  _x_parse_line "$1"
  if [[ "$_x_run" == @* ]]; then
    print -P "%F{2}▶ Open:%f %B${_x_run#@}%b sub-menu"
  else
    print -P "%F{2}▶ Run:%f %B${_x_run}%b"
  fi
  print
  _x_tool_help "$_x_help_key" | _x_align_help
}

_x_run_pick() {
  local key="$1" run="$2" cmd="$3" title="$4" help_key="$5"

  case "$key" in
    ctrl-h)
      _x_tool_help "$help_key" | ${PAGER:-less -R}
      return 0
      ;;
    ctrl-y)
      local copy="$run"
      [[ "$copy" == @* ]] && copy="${copy#@} sub-menu"
      if command -v pbcopy >/dev/null 2>&1; then
        print -rn -- "$copy" | pbcopy
        print -P "%F{green}✓%f copied: %B$copy%b"
      else
        print -r -- "$copy"
      fi
      return 0
      ;;
  esac

  if [[ "$run" == @* ]]; then
    _x_fzf_pick "_x_${run#@}_tools_data" "${run#@} tools"
    return $?
  fi

  print -P "%F{cyan}▶%f %B$run%b  %F{240}($cmd — $title)%f"
  eval "$run"
}

_x_fzf_pick() {
  local data_fn="$1" header_label="${2:-tools}"
  local result key line
  local preview_script="${_x_zsh:h}/x-preview.zsh"

  result=$(
    $data_fn | _x_format_row | fzf \
      --ansi \
      --delimiter=$'\t' \
      --with-nth=1,2,3 \
      --tabstop=24 \
      --header=$"Enter=run  •  Ctrl-H=help  •  Ctrl-Y=copy  •  ${header_label}  •  Esc=cancel" \
      --preview="zsh ${(q)preview_script} {}" \
      --preview-window='right:55%:wrap:border-rounded' \
      --height=85% --reverse --border=rounded \
      --color='header:italic:underline,label:blue,preview-bg:235' \
      --expect=ctrl-h,ctrl-y
  ) || return 0

  key=$(print -r -- "$result" | sed -n '1p')
  line=$(print -r -- "$result" | sed -n '2p')
  [[ -n "$line" ]] || return 0

  _x_parse_line "$line"
  _x_run_pick "$key" "$_x_run" "$_x_cmd" "$_x_title" "$_x_help_key"
}

x() {
  local sub="${1:-}"

  case "$sub" in
    --preview-line)
      _x_preview_line "${2:-}"
      return $?
      ;;
    help|-h|--help|h)
      _x_help
      return 0
      ;;
    list|ls|l)
      _x_tools_data | awk -F'\t' '{ printf "  %-22s  %-10s  %s\n", $1, $2, $3 }'
      return 0
      ;;
  esac

  _x_require_fzf || return 1
  _x_fzf_pick _x_tools_data "all tools"
}
