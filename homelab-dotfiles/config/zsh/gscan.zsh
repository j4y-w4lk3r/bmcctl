# gscan.zsh — scan and compare git repos across machines (local vs SSH).
#
#   gscan              compare local repos vs remote host (fzf)
#   gscan dupes [host] same as gscan but only repos on both machines
#   gscan local        list repos on this machine
#   gscan remote       list repos on remote host (pick or GSCAN_REMOTE)
#   gscan diff         same as gscan (explicit)
#
# Env:
#   GSCAN_PATHS    space-separated roots to search (default: ~/px ~)
#   GSCAN_OWNERS   GitHub owners to include (default: lso0 j4y-w4lk3r)
#   GSCAN_REMOTE   user@host for remote scans (default: pick via Tailscale)
#   GSCAN_MAXDEPTH find depth under each root (default: 6)
#
# Sourced from .zshrc:
#   [ -f ~/.config/zsh/gscan.zsh ] && source ~/.config/zsh/gscan.zsh

_gscan_require() {
  command -v fzf >/dev/null 2>&1 || {
    print -u2 "gscan: fzf not in PATH (install: brew install fzf)"
    return 1
  }
}

_gscan_paths() {
  local -a paths
  paths=(${=GSCAN_PATHS:-$HOME/px $HOME})
  print -r -- "${paths[@]}"
}

_gscan_owners() {
  local -a owners
  owners=(${=GSCAN_OWNERS:-lso0 j4y-w4lk3r})
  print -r -- "${owners[@]}"
}

_gscan_owner_allowed() {
  local o="$1" allowed
  for allowed in $(_gscan_owners); do
    [[ "$o" == "$allowed" ]] && return 0
  done
  return 1
}

_gscan_parse_remote() {
  local url="$1" rest owner repo
  url="${url%.git}"
  case "$url" in
    git@github.com:*/*)
      rest="${url#git@github.com:}"
      owner="${rest%%/*}"
      repo="${rest#*/}"
      ;;
    *github.com/*/*)
      rest="${url#*github.com/}"
      rest="${rest#*:}"
      owner="${rest%%/*}"
      repo="${rest#*/}"
      ;;
    *) return 1 ;;
  esac
  [[ -n "$owner" && -n "$repo" ]] || return 1
  print -r -- "$owner" "$repo"
}

_gscan_git_sync() {
  local path="$1"
  local branch dirty n ahead behind head upstream ab
  branch=$(git -C "$path" branch --show-current 2>/dev/null)
  branch="${branch:-?}"
  n=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  dirty=$([[ "$n" -gt 0 ]] && print dirty || print clean)
  head=$(git -C "$path" rev-parse --short HEAD 2>/dev/null)
  head="${head:-?}"
  upstream=$(git -C "$path" rev-parse --abbrev-ref '@{u}' 2>/dev/null) || upstream="-"
  ahead=0 behind=0
  if [[ "$upstream" != "-" ]]; then
    ab=$(git -C "$path" rev-list --left-right --count '@{u}'...HEAD 2>/dev/null)
    read -r behind ahead <<< "$ab"
    ahead="${ahead:-0}" behind="${behind:-0}"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s' \
    "$branch" "$dirty" "$ahead" "$behind" "$head" "$upstream"
}

_gscan_repo_line() {
  local machine="$1" path="$2"
  local url owner repo sync
  url=$(git -C "$path" remote get-url origin 2>/dev/null) || return 1
  read -r owner repo <<< "$(_gscan_parse_remote "$url")" || return 1
  [[ -n "$owner" && -n "$repo" ]] || return 1
  _gscan_owner_allowed "$owner" || return 1
  sync=$(_gscan_git_sync "$path")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$machine" "$owner" "$repo" "$path" ${=sync} "$url"
}

_gscan_scan_local() {
  local machine="$1" root gd path
  machine="${machine:-$(hostname -s 2>/dev/null || hostname)}"
  for root in $(_gscan_paths); do
    [[ -d "$root" ]] || continue
    while IFS= read -r gd; do
      path="${gd%/.git}"
      _gscan_repo_line "$machine" "$path" || true
    done < <(find "$root" -maxdepth "${GSCAN_MAXDEPTH:-6}" -name .git -type d 2>/dev/null)
  done | /usr/bin/sort -t $'\t' -k2,3 -u
}

_gscan_remote_script() {
  cat <<'EOS'
export PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
machine=$(/usr/bin/hostname -s 2>/dev/null || /bin/hostname 2>/dev/null || uname -n)
maxdepth="${GSCAN_MAXDEPTH:-6}"
paths="${GSCAN_PATHS:-$HOME/px $HOME}"
owners=" ${GSCAN_OWNERS:-lso0 j4y-w4lk3r} "

owner_ok() {
  case "$owners" in *" $1 "*) return 0 ;; esac
  return 1
}

parse_remote() {
  url="$1"
  url="${url%.git}"
  case "$url" in
    git@github.com:*/*)
      rest="${url#git@github.com:}"
      owner="${rest%%/*}"
      repo="${rest#*/}"
      ;;
    *github.com/*/*)
      rest="${url#*github.com/}"
      rest="${rest#*:}"
      owner="${rest%%/*}"
      repo="${rest#*/}"
      ;;
    *) return 1 ;;
  esac
  [ -n "$owner" ] && [ -n "$repo" ] || return 1
}

for root in $paths; do
  [ -d "$root" ] || continue
  find "$root" -maxdepth "$maxdepth" -name .git -type d 2>/dev/null
done | /usr/bin/sort -u | while IFS= read -r gd; do
  path="${gd%/.git}"
  url=$(git -C "$path" remote get-url origin 2>/dev/null) || continue
  parse_remote "$url" || continue
  owner_ok "$owner" || continue
  branch=$(git -C "$path" branch --show-current 2>/dev/null)
  branch="${branch:-?}"
  n=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" -gt 0 ]; then dirty=dirty; else dirty=clean; fi
  head=$(git -C "$path" rev-parse --short HEAD 2>/dev/null)
  head="${head:-?}"
  upstream=$(git -C "$path" rev-parse --abbrev-ref "@{u}" 2>/dev/null) || upstream="-"
  ahead=0 behind=0
  if [ "$upstream" != "-" ]; then
    set -- $(git -C "$path" rev-list --left-right --count "@{u}"...HEAD 2>/dev/null)
    behind="${1:-0}" ahead="${2:-0}"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$machine" "$owner" "$repo" "$path" \
    "$branch" "$dirty" "$ahead" "$behind" "$head" "$upstream" "$url"
done | /usr/bin/sort -t "$(printf '\t')" -k2,3 -u
EOS
}

_gscan_scan_remote() {
  local target="$1"
  [[ -n "$target" ]] || return 1
  local owners="${(j: :)${=GSCAN_OWNERS:-lso0 j4y-w4lk3r}}"
  local maxdepth="${GSCAN_MAXDEPTH:-6}"
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$target" \
    "GSCAN_OWNERS='${owners}' GSCAN_MAXDEPTH='${maxdepth}' bash -s" \
    < <(_gscan_remote_script)
}

_gscan_pick_remote() {
  local picked line
  if [[ -n "${GSCAN_REMOTE:-}" ]]; then
    print -r -- "$GSCAN_REMOTE"
    return 0
  fi

  if command -v tailscale >/dev/null 2>&1; then
    line=$(
      if command -v jq >/dev/null 2>&1; then
        command tailscale status --json 2>/dev/null | jq -r '
          .Self as $self
          | [((.Peer // {}) | to_entries[] | .value)][]
          | select((.TailscaleIPs // []) | length > 0)
          | select(.ID != $self.ID)
          | [
              (if .Online then 0 else 1 end),
              .TailscaleIPs[0],
              (.HostName // ((.DNSName // "") | sub("\\..*"; "")) | if . == "" then "?" else . end),
              (.OS // "?")
            ] | @tsv
        ' | LC_ALL=C sort -n -t $'\t' -k1,1 | cut -f2-
      else
        command tailscale status 2>/dev/null | awk '
          $1 ~ /^100\./ && NF >= 4 {
            ip = $1; host = $2; os = $4
            on = ($5 ~ /offline|not active/) ? 1 : 0
            printf "%d\t%s\t%s\t%s\n", on, ip, host, os
          }' | LC_ALL=C sort -n -t $'\t' -k1,1 | cut -f2-
      fi | fzf \
        --delimiter=$'\t' --with-nth=2,3,4 \
        --prompt="remote host> " \
        --header="Pick machine to scan (Enter = j4y@IP)" \
        --height=40% --reverse --border \
        --query="j4y@"
    ) || return 1
    picked="${line%%$'\t'*}"
    [[ -n "$picked" ]] || return 1
    if [[ "$picked" == *@* ]]; then
      print -r -- "$picked"
    else
      print -r -- "${TS_SSH_USER:-j4y}@${picked}"
    fi
    return 0
  fi

  print -u2 "gscan: set GSCAN_REMOTE=user@host or install tailscale for host picker"
  return 1
}

_gscan_local_machine() {
  print -r -- "$(/usr/bin/hostname -s 2>/dev/null || /bin/hostname 2>/dev/null || uname -n)"
}

_gscan_compare() {
  local remote="$1" dupes_only="${2:-0}"
  local local_m
  local_m=$(_gscan_local_machine)

  local local_file remote_file
  local_file=$(mktemp) remote_file=$(mktemp)
  trap 'rm -f "$local_file" "$remote_file"' EXIT INT TERM

  print -P "%F{cyan}▸%f scanning local (${local_m})..." >&2
  _gscan_scan_local "$local_m" >"$local_file" || true

  print -P "%F{cyan}▸%f scanning remote (${remote})..." >&2
  if ! _gscan_scan_remote "$remote" >"$remote_file"; then
    print -u2 "gscan: remote scan failed (${remote})"
    return 1
  fi

  awk -F'\t' -v dupes_only="$dupes_only" '
    BEGIN { local_f = ARGV[1]; remote_f = ARGV[2] }
    FILENAME == local_f {
      key = $2 "/" $3
      lpath[key] = $4; lbranch[key] = $5; ldirty[key] = $6
      lahead[key] = $7; lbehind[key] = $8; lhead[key] = $9
      lupstream[key] = $10; lurl[key] = $11
      keys[key] = 1
      next
    }
    FILENAME == remote_f {
      key = $2 "/" $3
      rpath[key] = $4; rbranch[key] = $5; rdirty[key] = $6
      rahead[key] = $7; rbehind[key] = $8; rhead[key] = $9
      rupstream[key] = $10; rurl[key] = $11
      keys[key] = 1
    }
    END {
      for (k in keys) {
        has_l = (k in lpath)
        has_r = (k in rpath)
        if (dupes_only && !(has_l && has_r)) continue

        issues = ""
        if (has_l && has_r) {
          full = ""
          if (ldirty[k] == "dirty") full = (full == "" ? "local:uncommitted" : full ", local:uncommitted")
          if (rdirty[k] == "dirty") full = (full == "" ? "remote:uncommitted" : full ", remote:uncommitted")
          if (lahead[k] + 0 > 0) full = (full == "" ? "local:unpushed(" lahead[k] ")" : full ", local:unpushed(" lahead[k] ")")
          if (rahead[k] + 0 > 0) full = (full == "" ? "remote:unpushed(" rahead[k] ")" : full ", remote:unpushed(" rahead[k] ")")
          if (lbehind[k] + 0 > 0) full = (full == "" ? "local:behind(" lbehind[k] ")" : full ", local:behind(" lbehind[k] ")")
          if (rbehind[k] + 0 > 0) full = (full == "" ? "remote:behind(" rbehind[k] ")" : full ", remote:behind(" rbehind[k] ")")
          if (lupstream[k] == "-") full = (full == "" ? "local:no-upstream" : full ", local:no-upstream")
          if (rupstream[k] == "-") full = (full == "" ? "remote:no-upstream" : full ", remote:no-upstream")
          if (lbranch[k] != rbranch[k]) full = (full == "" ? "branch-mismatch" : full ", branch-mismatch")
          if (lhead[k] != rhead[k]) full = (full == "" ? "commit-mismatch" : full ", commit-mismatch")
          issues = full
          status = (issues == "" ? "SYNC" : "DRIFT")
        } else if (has_l) {
          status = "LOCAL_ONLY"
          issues = "-"
        } else {
          status = "REMOTE_ONLY"
          issues = "-"
        }

        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
          status, k, issues,
          (has_l ? lpath[k] : "-"),
          (has_r ? rpath[k] : "-"),
          (has_l ? lbranch[k] : "-"),
          (has_r ? rbranch[k] : "-"),
          (has_l ? lhead[k] : "-"),
          (has_r ? rhead[k] : "-"),
          (has_l ? ldirty[k] : "-"),
          (has_r ? rdirty[k] : "-"),
          (has_l ? lahead[k] : "-"),
          (has_r ? rahead[k] : "-"),
          (has_l ? lbehind[k] : "-"),
          (has_r ? rbehind[k] : "-"),
          (has_l ? lupstream[k] : "-"),
          (has_r ? rupstream[k] : "-"),
          (has_l ? lurl[k] : "-"),
          (has_r ? rurl[k] : "-")
      }
    }
  ' "$local_file" "$remote_file" | /usr/bin/sort -t $'\t' -k2,2
}

_gscan_color_rows() {
  awk -F'\t' '
    {
      st = $1
      if (st == "SYNC")       printf "\033[38;5;84m"
      else if (st == "DRIFT") printf "\033[38;5;203m"
      else if (st == "LOCAL_ONLY")  printf "\033[38;5;87m"
      else if (st == "REMOTE_ONLY") printf "\033[38;5;117m"
      else printf "\033[0m"
      printf "%s", $0
      printf "\033[0m\n"
    }
  '
}

_gscan_list_fzf() {
  local title="$1" header="$2"
  shift 2
  "$@" | _gscan_color_rows | fzf \
    --ansi \
    --delimiter=$'\t' \
    --with-nth=2,3,5,6,7,8,9 \
    --prompt="${title}> " \
    --header="$header" \
    --height=80% --reverse --border \
    --preview 'printf "%s\n" \
      "repo:     $2/$3" \
      "path:     $4" \
      "branch:   $5" \
      "worktree: $6" \
      "upstream: $10" \
      "ahead:    $7  behind: $8" \
      "commit:   $9" \
      "url:      $11"' \
    --preview-window=right:45%
}

_gscan_diff_fzf() {
  local remote="$1" dupes_only="${2:-0}"
  _gscan_compare "$remote" "$dupes_only" | _gscan_color_rows | fzf \
    --ansi \
    --delimiter=$'\t' \
    --with-nth=1,2,3,8,9 \
    --prompt="gscan> " \
    --header=$'SYNC=both clean, pushed, same commit · DRIFT=needs attention\nEnter: paths · Ctrl-O: cd local · Ctrl-R: ssh remote' \
    --height=85% --reverse --border \
    --preview 'printf "%s\n" \
      "status:   $1" \
      "repo:     $2" \
      "issues:   $3" \
      "" \
      "LOCAL  $4" \
      "  branch:   $6  commit: $8  worktree: $10" \
      "  upstream: $16  ahead: $12  behind: $14" \
      "" \
      "REMOTE $5" \
      "  branch:   $7  commit: $9  worktree: $11" \
      "  upstream: $17  ahead: $13  behind: $15"' \
    --preview-window=right:55% \
    --bind "enter:execute-silent(echo local: {4}; echo remote: {5})+accept" \
    --bind "ctrl-o:execute-silent([[ {4} != - ]] && cd {4})" \
    --bind "ctrl-r:execute(ssh '"${remote}"' -t \"cd '{5}' && exec \$SHELL -l\")"
}

gscan() {
  _gscan_require || return 1

  local cmd="${1:-diff}"
  shift || true

  case "$cmd" in
    help|-h|--help)
      cat <<'EOF'
gscan — compare git repos across machines (lso0 / j4y-w4lk3r on GitHub origin)

  gscan              compare local vs remote (fzf)
  gscan dupes [host] only repos on BOTH machines (+ sync check)
  gscan diff [host]  same as gscan
  gscan local        list repos on this Mac
  gscan remote [host] list repos on remote host

Sync check (repos on both machines):
  SYNC  — clean, pushed (0 ahead/behind upstream), same commit on both
  DRIFT — uncommitted, unpushed, behind, branch/commit mismatch, etc.

Env: GSCAN_PATHS  GSCAN_OWNERS  GSCAN_REMOTE  GSCAN_MAXDEPTH
EOF
      ;;
    local)
      _gscan_list_fzf "local" "Repos on this machine (filtered by GSCAN_OWNERS)" \
        _gscan_scan_local "$(_gscan_local_machine)"
      ;;
    remote)
      local target="${1:-$(_gscan_pick_remote)}"
      [[ -n "$target" ]] || return 1
      _gscan_list_fzf "remote" "Repos on ${target}" \
        _gscan_scan_remote "$target"
      ;;
    diff|"")
      local target="${1:-$(_gscan_pick_remote)}"
      [[ -n "$target" ]] || return 1
      _gscan_diff_fzf "$target" 0
      ;;
    dupes)
      local target="${1:-$(_gscan_pick_remote)}"
      [[ -n "$target" ]] || return 1
      _gscan_diff_fzf "$target" 1
      ;;
    *)
      print -u2 "gscan: unknown command '$cmd' (try: gscan help)"
      return 1
      ;;
  esac
}
