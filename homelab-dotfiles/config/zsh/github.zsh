# github.zsh — fzf-powered helpers around the `gh` CLI.
#
#   ggm   GitHub My repos   — browse own repos with preview + multi-action picker
#   ggc   GitHub Clone      — alias for `ggm` (kept for muscle memory)
#   ggs   GitHub Stars      — browse / clone / star / unstar starred repos
#   gga   GitHub repo search — search public repos, copy or bulk-star
#
# All four rely on:
#   - gh   (authenticated: `gh auth status`)
#   - fzf
#   - awk, cut, pbcopy (macOS)
#
# History notes:
#   2026-05-20  `gcl` -> `ggc` (whole family shares the `gg*` prefix)
#   2026-05-26  `ggc` -> `ggm` with multi-action key bindings;
#               `ggc` kept as an alias.
#
# Sourced from .zshrc:
#   [ -f ~/.config/zsh/github.zsh ] && source ~/.config/zsh/github.zsh

# ---- ggm — interactive browser for your own repos ------------------------
#
# One fzf picker over `gh repo list <you>`, with a live preview of the
# selected repo's metadata + README. The action is chosen by the key the
# user presses:
#   Enter   clone (or whatever -flag was passed)
#   Ctrl-V  view (gh repo view in terminal)
#   Ctrl-O  open in browser (gh repo view --web)
#   Ctrl-Y  copy clone URL to clipboard
# Key bindings always override the -flag, so e.g. `ggm -v` + Ctrl-O still
# opens the browser.

ggm() {
  case "$1" in
    -h|--help)
      cat <<'EOF'
ggm - GitHub My repos (interactive browser)

  ggm                 Open fzf picker. Inside the picker:
                        Enter   clone (default)
                        Ctrl-V  view (gh repo view)
                        Ctrl-O  open in browser
                        Ctrl-Y  copy clone URL to clipboard
                        Esc     cancel
  ggm -c              Clone selection (same as Enter)
  ggm -v              View selection (gh repo view)
  ggm -o              Open selection in browser
  ggm -y              Copy clone URL to clipboard
  ggm -p              Print selection only (owner/repo)
  ggm -h              This help

`ggc` is preserved as an alias for `ggm`.
EOF
      return 0
      ;;
  esac

  local default_action="${1:-}"   # -c -v -o -y -p or empty
  local user; user="$(gh api user --jq .login)" || return 1

  local data
  data=$(
    gh repo list "$user" --limit 200 \
      --json name,description,updatedAt,isPrivate,isFork \
      --jq '.[] | [
        .name,
        (.updatedAt|.[0:10]),
        (if .isPrivate then "🔒" else "🌐" end),
        (if .isFork then "fork" else "    " end),
        (.description // "")
      ] | @tsv'
  )
  [ -z "$data" ] && { echo "no repos found for $user" >&2; return 1; }

  local result key repo
  result=$(printf '%s\n' "$data" | fzf \
    --delimiter=$'\t' --with-nth=1,2,3,4,5 \
    --header=$'Enter=clone  •  Ctrl-V=view  •  Ctrl-O=browser  •  Ctrl-Y=copy URL  •  Esc=cancel' \
    --preview "gh repo view $user/{1}" \
    --preview-window=right:60%:wrap \
    --height=80% --reverse --border \
    --expect=ctrl-v,ctrl-o,ctrl-y) || return 1

  # With --expect, fzf prints:
  #   line 1: the key (one of ctrl-v/ctrl-o/ctrl-y, or empty for Enter)
  #   line 2: the selected row
  key=$(printf '%s\n' "$result" | sed -n '1p')
  repo=$(printf '%s\n' "$result" | sed -n '2p' | cut -f1)
  [ -n "$repo" ] || return 1

  # Key binding overrides any -flag passed on the CLI.
  local action="$default_action"
  case "$key" in
    ctrl-v) action="-v" ;;
    ctrl-o) action="-o" ;;
    ctrl-y) action="-y" ;;
  esac

  case "$action" in
    -p) echo "$user/$repo" ;;
    -v) gh repo view "$user/$repo" ;;
    -o) gh repo view --web "$user/$repo" ;;
    -y)
      local url
      url=$(gh repo view "$user/$repo" --json sshUrl --jq .sshUrl)
      printf '%s' "$url" | pbcopy && echo "copied: $url"
      ;;
    -c|*) gh repo clone "$user/$repo" ;;
  esac
}

# Backward-compat alias: keep typing `ggc` if you prefer.
ggc() { ggm "$@"; }

# ---- ggs — manage your starred repos -------------------------------------

ggs() {
  case "$1" in
    -b)
      local repo
      repo=$(
        gh api /user/starred --paginate \
          --jq '.[] | "\(.full_name)\t\(.stargazers_count)\t\(.description // "")"' |
        awk -F'\t' -v OFS='\t' '{printf "%s\t%-38s  ⭐ %-6s  %s\n", $1, $1, $2, $3}' |
        fzf --delimiter=$'\t' --with-nth=2,3,4 --preview 'gh repo view {1}' |
        cut -f1
      )
      [ -n "$repo" ] && echo "$repo"
      ;;
    -c)
      local repo
      repo=$(
        gh api /user/starred --paginate \
          --jq '.[] | "\(.full_name)\t\(.stargazers_count)\t\(.description // "")"' |
        awk -F'\t' -v OFS='\t' '{printf "%s\t%-38s  ⭐ %-6s  %s\n", $1, $1, $2, $3}' |
        fzf --delimiter=$'\t' --with-nth=2,3,4 --preview 'gh repo view {1}' |
        cut -f1
      )
      [ -n "$repo" ] && gh repo clone "$repo"
      ;;
    -a)
      shift
      [ -z "$1" ] && { echo "usage: gs -a <owner/repo> [...]"; return 1; }
      local r
      for r in "$@"; do
        gh api -X PUT "/user/starred/$r" && echo "starred $r"
      done
      ;;
    -rm)
      local -a picks
      picks=(${(f)"$(
        gh api /user/starred --paginate --jq '.[].full_name' |
        fzf --multi --prompt='unstar> '
      )"})
      [ ${#picks} -eq 0 ] && return
      local r
      for r in $picks; do
        gh api -X DELETE "/user/starred/$r" && echo "unstarred $r"
      done
      ;;
    -h|--help)
      echo "ggs - GitHub Stars manager"
      echo ""
      echo "  ggs -b              Browse starred repos (fzf + preview)"
      echo "  ggs -c              Browse starred repos, clone selection"
      echo "  ggs -a <owner/repo> Star one or more repos"
      echo "  ggs -rm             Unstar repos (fzf multi-select with Tab)"
      echo "  ggs -h              Show this help"
      ;;
    *)
      ggs -h
      return 1
      ;;
  esac
}

# ---- gga — search GitHub repos -------------------------------------------

gga() {
  case "$1" in
    -b)
      shift
      [ -z "$1" ] && { echo "usage: gga -b <query>"; return 1; }

      local repo starred
      starred=$(gh api /user/starred --paginate --jq '.[].full_name')

      repo=$(
        {
          printf '%s\n' "$starred"
          printf '%s\n' '__GGA_STARRED_END__'
          gh search repos "$*" --limit 50 \
            --json fullName,description,stargazersCount \
            --jq '.[] | "\(.fullName)\t\(.stargazersCount)\t\(.description // "")"'
        } | awk -F'\t' -v OFS='\t' '
          $0 == "__GGA_STARRED_END__" { in_search = 1; next }
          !in_search { if ($0 != "") s[$0] = 1; next }
          {
            mark = (s[$1] ? "✓ " : "  ")
            printf "%s\t%s%-38s  ⭐ %-6s  %s\n", $1, mark, $1, $2, $3
          }
        ' |
        fzf --delimiter=$'\t' --with-nth=2,3,4 --preview 'gh repo view {1}' |
        cut -f1
      )

      [ -n "$repo" ] && echo -n "$repo" | pbcopy && echo "copied: $repo"
      ;;
    -s)
      shift
      [ -z "$1" ] && { echo "usage: gga -s <query>"; return 1; }

      local starred
      starred=$(gh api /user/starred --paginate --jq '.[].full_name')

      local -a picks
      picks=(${(f)"$(
        {
          printf '%s\n' "$starred"
          printf '%s\n' '__GGA_STARRED_END__'
          gh search repos "$*" --limit 50 \
            --json fullName,description,stargazersCount \
            --jq '.[] | "\(.fullName)\t\(.stargazersCount)\t\(.description // "")"'
        } | awk -F'\t' -v OFS='\t' '
          $0 == "__GGA_STARRED_END__" { in_search = 1; next }
          !in_search { if ($0 != "") s[$0] = 1; next }
          {
            mark = (s[$1] ? "✓ " : "  ")
            printf "%s\t%s%-38s  ⭐ %-6s  %s\n", $1, mark, $1, $2, $3
          }
        ' |
        fzf --multi --delimiter=$'\t' --with-nth=2,3,4 --preview 'gh repo view {1}' |
        cut -f1
      )"})

      [ ${#picks} -eq 0 ] && return

      local r
      for r in $picks; do
        gh api -X PUT "/user/starred/$r" && echo "starred $r"
      done
      ;;
    -h|--help)
      echo "gga - GitHub repo search"
      echo ""
      echo "  gga -b <query>  Browse search results (fzf + preview)"
      echo "  gga -s <query>  Search and star repos (fzf multi-select with Tab)"
      echo "  gga -h          Show this help"
      ;;
    *)
      gga -h
      return 1
      ;;
  esac
}

# ---- completion: tab-complete ggm/ggc with your own repo names ----------

_ggm_complete() {
  local -a repos
  local user
  user="$(gh api user --jq .login 2>/dev/null)"
  [ -z "$user" ] && return 0
  repos=(${(f)"$(gh repo list "$user" --limit 100 --json name -q '.[].name' 2>/dev/null)"})
  compadd -- $repos
}
compdef _ggm_complete ggm
compdef _ggm_complete ggc
