# gbr.zsh — rename git branches locally + on GitHub (fzf picker)
#
#   gbr                     current repo: pick branch(es) → new name(s)
#   gbr -R                  pick repo(s) under ~/px first
#   gbr main 0              rename main → 0 (current repo)
#   gbr main 0 dev 1        batch rename multiple branches
#   gbr -R main 0 dev 1     batch rename across selected repos
#   gbr -f map.txt          read old/new pairs from a file (one pair per line)
#   gbr --local …           skip pushing to origin
#   gbr --all               include all GitHub repos (not just your accounts)
#
# Env: GSCAN_PATHS  GSCAN_OWNERS (or GBR_OWNERS)  GSCAN_MAXDEPTH
#
# Requires: git, gh, fzf

_gbr_paths() {
  print -r -- ${=GSCAN_PATHS:-$HOME/px $HOME}
}

_gbr_owners() {
  local -a owners
  if [[ -n "$GBR_OWNERS" ]]; then
    owners=(${=GBR_OWNERS})
  elif [[ -n "$GSCAN_OWNERS" ]]; then
    owners=(${=GSCAN_OWNERS})
  else
    owners=(lso0 j4y-w4lk3r)
  fi
  print -r -- "${owners[@]}"
}

_gbr_owner_allowed() {
  local o="$1" allowed
  (( ${GBR_SHOW_ALL:-0} )) && return 0
  [[ -n "$o" && "$o" != "—" ]] || return 1
  for allowed in $(_gbr_owners); do
    [[ "$o" == "$allowed" ]] && return 0
  done
  return 1
}

_gbr_github_owner() {
  local dir="$1" url rest owner
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 1
  case "$url" in
    git@github.com:*/*|*github.com/*/*)
      url="${url%.git}"
      case "$url" in
        git@github.com:*) rest="${url#git@github.com:}" ;;
        *) rest="${url#*github.com/}"; rest="${rest#*:}" ;;
      esac
      owner="${rest%%/*}"
      [[ -n "$owner" ]] && print -r -- "$owner"
      ;;
  esac
}

_gbr_gh_as_owner() {
  local want="$1" cur
  cur=$(gh api user --jq .login 2>/dev/null) || return 1
  [[ "$cur" == "$want" ]] && return 0
  gh auth switch --hostname github.com --user "$want" >/dev/null 2>&1
}

_gbr_valid_name() {
  local name="$1"
  [[ -n "$name" ]] || return 1
  [[ "$name" != /* ]] || return 1
  [[ "$name" != *" "* ]] || return 1
  [[ "$name" != *".."* ]] || return 1
  [[ "$name" != . ]] || return 1
  return 0
}

_gbr_init_icons() {
  [[ -n "${_gbr_ic_github:-}" ]] && return 0
  if typeset -f _px_char >/dev/null 2>&1; then
    _gbr_ic_github=$(_px_char f113)
    _gbr_ic_branch=$(_px_char f418)
    _gbr_ic_folder=$(_px_char f07b)
    _gbr_ic_dirty=$(_px_char f044)
    _gbr_ic_clean=$(_px_char f058)
  else
    _gbr_ic_github=$'\uf113'
    _gbr_ic_branch=$'\uf418'
    _gbr_ic_folder=$'\uf07b'
    _gbr_ic_dirty=$'\uf044'
    _gbr_ic_clean=$'\uf058'
  fi
}

_gbr_fmt_owner() {
  local owner="${1:-—}"
  _gbr_init_icons
  if [[ -z "$owner" || "$owner" == "—" ]]; then
    printf '\033[2m%-14s\033[0m' '—'
    return 0
  fi
  case "$owner" in
    lso0)       printf '\033[38;5;214m%s\033[0m \033[38;5;214m%-12s\033[0m' "$_gbr_ic_github" "$owner" ;;
    j4y-w4lk3r) printf '\033[38;5;205m%s\033[0m \033[38;5;205m%-12s\033[0m' "$_gbr_ic_github" "$owner" ;;
    *)          printf '\033[38;5;141m%s\033[0m \033[38;5;141m%-12s\033[0m' "$_gbr_ic_github" "$owner" ;;
  esac
}

_gbr_fmt_branch() {
  local branch="${1:-?}"
  _gbr_init_icons
  printf '\033[38;5;213m%s\033[0m \033[38;5;213m%-10s\033[0m' "$_gbr_ic_branch" "$branch"
}

_gbr_fmt_name() {
  local name="$1"
  _gbr_init_icons
  printf '\033[1;34m%s\033[0m \033[1;37m%-22s\033[0m' "$_gbr_ic_folder" "$name"
}

_gbr_fmt_status() {
  local dir="$1" porcelain counts sum ahead behind
  if typeset -f _px_git_status_compact >/dev/null 2>&1; then
    _px_git_status_compact "$dir"
    return 0
  fi
  _gbr_init_icons
  porcelain=$(git -C "$dir" status --porcelain 2>/dev/null)
  if [[ -n "$porcelain" ]]; then
    printf '\033[31m%s\033[0m' "$_gbr_ic_dirty"
    return 0
  fi
  counts=$(git -C "$dir" rev-list --left-right --count @{upstream}...HEAD 2>/dev/null) || {
    printf '\033[32m%s\033[0m' "$_gbr_ic_clean"
    return 0
  }
  sum=$(echo "$counts" | awk '{print $1+$2}')
  if [[ "$sum" == 0 ]]; then
    printf '\033[32m%s\033[0m' "$_gbr_ic_clean"
    return 0
  fi
  behind=${counts%%[[:space:]]*}
  ahead=${counts##*[[:space:]]}
  (( behind )) && printf ' \033[33m↓%s\033[0m' "$behind"
  (( ahead ))  && printf ' \033[33m↑%s\033[0m' "$ahead"
}

_gbr_fmt_repo_line() {
  local dir="$1" owner="$2" branch="$3" name="$4"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$dir" \
    "$(_gbr_fmt_name "$name")" \
    "$(_gbr_fmt_owner "$owner")" \
    "$(_gbr_fmt_branch "$branch")" \
    "$(_gbr_fmt_status "$dir")"
}

_gbr_fmt_branch_line() {
  local branch="$1" cur="$2" kind="$3"
  local mark=$' \033[0m'
  [[ "$branch" == "$cur" ]] && mark=$'\033[1;32m*\033[0m'
  case "$kind" in
    local)  printf '%s\t%s  %s  \033[2mlocal\033[0m\n' "$branch" "$mark" "$(_gbr_fmt_branch "$branch")" ;;
    remote) printf '%s\t%s  %s  \033[2mremote\033[0m\n' "$branch" "$mark" "$(_gbr_fmt_branch "$branch")" ;;
    *)      printf '%s\t%s  %s\n' "$branch" "$mark" "$(_gbr_fmt_branch "$branch")" ;;
  esac
}

_gbr_scan_repos() {
  local root maxdepth="${GSCAN_MAXDEPTH:-6}"
  for root in $(_gbr_paths); do
    [[ -d "$root" ]] || continue
    find "$root" -maxdepth "$maxdepth" -name .git -type d 2>/dev/null |
      while IFS= read -r gitdir; do
        print -r -- "${gitdir:h}"
      done
  done | awk '!seen[$0]++'
}

_gbr_repo_has_branch() {
  local dir="$1" branch="$2"
  git -C "$dir" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null ||
    git -C "$dir" ls-remote --exit-code origin "refs/heads/$branch" >/dev/null 2>&1
}

_gbr_repo_row() {
  local dir="$1" owner branch name
  local -a filters=("${@:2}")
  owner=$(_gbr_github_owner "$dir") || return 1
  _gbr_owner_allowed "$owner" || return 1
  branch=$(git -C "$dir" branch --show-current 2>/dev/null)
  name="${dir:t}"
  if (( ${#filters[@]} )); then
    local b found=0
    for b in "${filters[@]}"; do
      _gbr_repo_has_branch "$dir" "$b" && found=1 && break
    done
    (( found )) || return 1
  fi
  printf '%s\t%s\t%s\t%s\n' "$name" "$dir" "${owner:-—}" "${branch:-?}"
}

_gbr_fzf_multi() {
  command fzf --multi --ansi \
    --bind 'enter:accept' \
    --bind 'ctrl-a:select-all' \
    "$@"
}

_gbr_read_tty() {
  local var="$1" prompt="${2:-}"
  if [[ -n "$prompt" ]]; then
    print -n "$prompt" >&2
  fi
  if [[ -r /dev/tty ]]; then
    read -r "$var" </dev/tty
  else
    read -r "$var"
  fi
}

_gbr_pick_repos() {
  local rows pick name dir owner branch header
  local -a filters=("$@") owners
  owners=($(_gbr_owners))
  if (( GBR_SHOW_ALL )); then
    header='all GitHub repos · Tab=multi · Enter=select · Esc=cancel'
  else
    header="owners: ${(j: · :)owners} · Tab=multi · Enter=select · Esc=cancel · gbr --all for everything"
  fi
  rows=$(_gbr_scan_repos | while IFS= read -r dir; do
    _gbr_repo_row "$dir" "${filters[@]}"
  done | sort -t $'\t' -k1,1)
  [[ -n "$rows" ]] || {
    print -u2 "gbr: no git repos found"
    return 1
  }

  pick=$(
    while IFS=$'\t' read -r name dir owner branch; do
      _gbr_fmt_repo_line "$dir" "$owner" "$branch" "$name"
    done <<< "$rows" |
      _gbr_fzf_multi \
        --delimiter=$'\t' --with-nth=2,3,4,5 \
        --prompt='repos> ' \
        --header="$header · Enter → pick branches" \
        --height=85% --reverse --border \
        --preview='git -C {1} branch -vv --color=always 2>/dev/null | head -20' \
        --preview-window=right:45% |
      cut -f1
  ) || return 1

  [[ -n "$pick" ]] || return 1
  print -r -- "$pick"
}

_gbr_pick_branches() {
  local dir="$1" branch cur
  cur=$(git -C "$dir" branch --show-current 2>/dev/null)
  branch=$(
    {
      git -C "$dir" branch --format='%(refname:short)' 2>/dev/null | while IFS= read -r b; do
        [[ -n "$b" ]] && _gbr_fmt_branch_line "$b" "$cur" local
      done
      git -C "$dir" for-each-ref refs/remotes/origin --format='%(refname:short)' 2>/dev/null |
        sed 's|^origin/||' | command grep -vxE 'HEAD|origin' 2>/dev/null | while IFS= read -r b; do
          [[ -n "$b" ]] && _gbr_fmt_branch_line "$b" "$cur" remote
        done
    } | awk -F'\t' '!seen[$1]++' | _gbr_fzf_multi \
      --delimiter=$'\t' --with-nth=2,3,4 \
      --prompt='branches> ' \
      --header="Pick branch(es) in ${dir:t} · Enter=select · Tab=multi · Esc=cancel" \
      --height=40% --reverse --border \
      | cut -f1
  ) || return 1
  [[ -n "$branch" ]] || return 1
  while IFS= read -r line; do
    line="${line#origin/}"
    [[ -n "$line" ]] && print -r -- "$line"
  done <<< "$branch"
}

_gbr_pick_branch() {
  _gbr_pick_branches "$1" | head -1
}

_gbr_load_pairs_file() {
  local file="$1" line o n
  [[ -f "$file" ]] || { print -u2 "gbr: file not found: $file"; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    o="${line%%[[:space:]]*}"
    n="${line#${o}}"
    n="${n#"${n%%[![:space:]]*}"}"
    [[ -n "$o" && -n "$n" ]] || {
      print -u2 "gbr: invalid line in $file: $line"
      return 1
    }
    print -r -- "$o" "$n"
  done < "$file"
}

_gbr_validate_pairs() {
  local -a pairs=("$@")
  local -A seen_new
  local i old new
  (( ${#pairs[@]} % 2 == 0 )) || {
    print -u2 "gbr: internal error: odd number of branch names"
    return 1
  }
  for (( i=1; i<=${#pairs[@]}; i+=2 )); do
    old="$pairs[i]"
    new="$pairs[i+1]"
    _gbr_valid_name "$old" || { print -u2 "gbr: invalid branch: $old"; return 1; }
    _gbr_valid_name "$new" || { print -u2 "gbr: invalid branch: $new"; return 1; }
    [[ "$old" != "$new" ]] || { print -u2 "gbr: ${old} → ${new} is a no-op"; return 1; }
    [[ -z "${seen_new[$new]:-}" ]] || {
      print -u2 "gbr: duplicate target name: $new"
      return 1
    }
    seen_new[$new]=1
  done
}

_gbr_collect_pairs_interactive() {
  local dir="$1"
  local -a branches pairs=() branch
  branches=(${(f)"$(_gbr_pick_branches "$dir")"}) || return 1
  (( ${#branches[@]} )) || return 0
  for branch in "${branches[@]}"; do
    _gbr_prompt_new_name "$branch" || return 1
    pairs+=("$branch" "$REPLY")
  done
  GBR_PAIRS=("${pairs[@]}")
}

_gbr_branches_across_repos() {
  local dir
  local -a dirs=("$@")

  for dir in "${dirs[@]}"; do
    {
      git -C "$dir" branch --format='%(refname:short)' 2>/dev/null
      git -C "$dir" for-each-ref refs/remotes/origin --format='%(refname:short)' 2>/dev/null |
        sed 's|^origin/||' | command grep -vxE 'HEAD|origin' 2>/dev/null || true
    } | awk '!seen[$0]++ { print $0 }'
    print -r -- '---END---'
  done | awk '
    $0 == "---END---" {
      for (b in repo) counts[b]++
      delete repo
      next
    }
    { repo[$0]=1 }
    END {
      for (b in repo) counts[b]++
      for (b in counts) printf "%d\t%s\n", counts[b], b
    }
  ' | sort -t $'\t' -k1,1nr -k2,2
}

_gbr_fmt_branch_multi_line() {
  local branch="$1" count="$2" total="$3"
  local count_disp
  if (( count == total )); then
    count_disp=$'\033[38;5;84m'"${count}/${total} repos"$'\033[0m'
  elif (( count * 2 >= total )); then
    count_disp=$'\033[38;5;220m'"${count}/${total} repos"$'\033[0m'
  else
    count_disp=$'\033[38;5;203m'"${count}/${total} repos"$'\033[0m'
  fi
  printf '%s\t  %s  %s  %s\n' "$branch" " " "$(_gbr_fmt_branch "$branch")" "$count_disp"
}

_gbr_pick_branches_multi_repo() {
  local -a dirs=("$@") pick rows=()
  local n=${#dirs[@]} count branch

  print -P "%F{cyan}Loading branches from ${n} repo(s)…%f" >&2

  while IFS=$'\t' read -r count branch; do
    [[ -n "$branch" ]] || continue
    rows+=("$(_gbr_fmt_branch_multi_line "$branch" "$count" "$n")")
  done < <(_gbr_branches_across_repos "${dirs[@]}")

  (( ${#rows[@]} )) || {
    print -u2 "gbr: no branches found in selected repos"
    return 1
  }

  pick=$(print -r -- "${rows[@]}" |
    _gbr_fzf_multi \
      --delimiter=$'\t' --with-nth=2,3,4 \
      --prompt='branches> ' \
      --header="Rename in ${n} repo(s) · Enter=select · Tab=multi · Esc=cancel" \
      --height=40% --reverse --border |
    cut -f1) || return 1

  [[ -n "$pick" ]] || {
    print -u2 "gbr: no branch selected"
    return 1
  }
  while IFS= read -r line; do
    [[ -n "$line" ]] && print -r -- "$line"
  done <<< "$pick"
}

_gbr_collect_pairs_multi_repo() {
  local -a dirs=("$@") branches pairs=() branch
  branches=(${(f)"$(_gbr_pick_branches_multi_repo "${dirs[@]}")"}) || return 1
  (( ${#branches[@]} )) || {
    print -u2 "gbr: no branch selected"
    return 1
  }
  print -P "\n%F{cyan}Branch(es) to rename:%f ${(j:, :)branches}" >&2
  for branch in "${branches[@]}"; do
    _gbr_prompt_new_name "$branch" || return 1
    pairs+=("$branch" "$REPLY")
  done
  GBR_PAIRS=("${pairs[@]}")
}

_gbr_print_selected_repos() {
  local -a dirs=("$@") names=() d
  for d in "${dirs[@]}"; do
    names+=("${d:t}")
  done
  print
  print -P "%F{cyan}Selected ${#dirs[@]} repo(s):%f ${(j:, :)names}"
}

_gbr_prompt_new_name() {
  local old="$1" new
  print >&2
  print -P "Rename %B${old}%b → ?" >&2
  _gbr_read_tty new "New branch name: "
  _gbr_valid_name "$new" || {
    print -u2 "gbr: invalid branch name: $new"
    return 1
  }
  REPLY="$new"
}

_gbr_rename_remote() {
  local dir="$1" old="$2" new="$3"
  local owner repo default cur gh_user

  git -C "$dir" remote get-url origin >/dev/null 2>&1 || return 0

  owner=$(_gbr_github_owner "$dir") || {
    print -u2 "gbr: ${dir:t}: no GitHub origin — skipped remote"
    return 0
  }
  repo="${dir:t}"
  gh_user=$(gh api user --jq .login 2>/dev/null) || {
    print -u2 "gbr: gh not logged in — skipped remote for ${owner}/${repo}"
    return 1
  }
  _gbr_gh_as_owner "$owner" || print -P "%F{yellow}⚠%f gh is ${gh_user}, remote is ${owner} — push may fail"

  default=$(gh api "repos/${owner}/${repo}" --jq .default_branch 2>/dev/null)

  if git -C "$dir" show-ref --verify --quiet "refs/heads/$new" 2>/dev/null; then
    git -C "$dir" push origin "$new" || return 1
  else
    print -u2 "gbr: ${dir:t}: local branch $new missing after rename"
    return 1
  fi

  if [[ "$default" == "$old" ]]; then
    gh api -X PATCH "repos/${owner}/${repo}" -f default_branch="$new" >/dev/null ||
      { print -u2 "gbr: ${dir:t}: could not set default branch to ${new} on GitHub"; return 1; }
    local try=0
    while (( try < 10 )); do
      default=$(gh api "repos/${owner}/${repo}" --jq .default_branch 2>/dev/null)
      [[ "$default" == "$new" ]] && break
      (( try++ ))
      sleep 1
    done
    [[ "$default" == "$new" ]] || {
      print -u2 "gbr: ${dir:t}: default branch is still ${default:-?}, expected ${new}"
      return 1
    }
  fi

  if git -C "$dir" ls-remote --exit-code origin "refs/heads/$old" >/dev/null 2>&1; then
    git -C "$dir" push origin --delete "$old" || return 1
  fi

  cur=$(git -C "$dir" branch --show-current 2>/dev/null)
  if [[ "$cur" == "$new" ]]; then
    git -C "$dir" branch -u "origin/$new" "$new" 2>/dev/null || true
  fi
}

_gbr_rename_one() {
  local dir="$1" old="$2" new="$3" do_remote="$4"
  local had_local=0

  [[ -d "$dir/.git" ]] || return 1
  [[ "$old" != "$new" ]] || return 0

  if git -C "$dir" show-ref --verify --quiet "refs/heads/$old" 2>/dev/null; then
    had_local=1
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$new" 2>/dev/null; then
      print -u2 "gbr: ${dir:t}: branch $new already exists locally"
      return 1
    fi
    git -C "$dir" branch -m "$old" "$new" || return 1
    print -P "%F{green}✓%f ${dir:t}: local ${old} → ${new}"
  else
    print -P "%F{yellow}⚠%f ${dir:t}: no local branch ${old} — remote-only rename"
    git -C "$dir" fetch origin "$old:$new" 2>/dev/null || {
      print -u2 "gbr: ${dir:t}: branch ${old} not found locally or on origin"
      return 1
    }
    git -C "$dir" branch -d "$old" 2>/dev/null || true
  fi

  if (( do_remote )); then
    _gbr_rename_remote "$dir" "$old" "$new" &&
      print -P "%F{green}✓%f ${dir:t}: remote origin ${old} → ${new}" ||
      print -P "%F{red}✗%f ${dir:t}: remote update failed"
  fi
}

_gbr_show_plan() {
  local count="$1" do_remote="$2"
  shift 2
  local -a pairs=("$@")
  local i
  print
  print "Planned renames:"
  for (( i=1; i<=${#pairs[@]}; i+=2 )); do
    print -P "  %B${pairs[i]}%b → %B${pairs[i+1]}%b"
  done
  print "in ${count} repo(s)"
  (( do_remote )) && print "  + push to GitHub (delete old remote branches, update default if needed)"
}

_gbr_pairs_old_names() {
  local -a pairs=("$@") olds=()
  local i
  for (( i=1; i<=${#pairs[@]}; i+=2 )); do
    olds+=("$pairs[i]")
  done
  print -r -- "${olds[@]}"
}

gbr() {
  local pick_repos=0 local_only=0 mapfile="" pending_old=""
  local -a pairs repos olds
  local d i

  GBR_SHOW_ALL=0
  GBR_PAIRS=()

  while (( $# )); do
    case "$1" in
      -R|--repos) pick_repos=1; shift ;;
      --local) local_only=1; shift ;;
      --all) GBR_SHOW_ALL=1; shift ;;
      -f|--file)
        [[ -n "${2:-}" ]] || { print -u2 "gbr: -f requires a file path"; return 1; }
        mapfile="$2"
        shift 2
        ;;
      -h|--help)
        cat <<'EOF'
gbr — rename git branches (local + GitHub remote)

  gbr                     pick repo(s) → branch(es) → new name(s)
  gbr -R                  same, starting from repo picker under ~/px
  gbr <old> <new>         rename in current repo
  gbr <old> <new> …       batch rename multiple branches
  gbr -R <old> <new> …    batch rename in repos that have any listed branch
  gbr -f map.txt          read old/new pairs from file (one pair per line)
  gbr --local …           local rename only (no push)
  gbr --all               include all GitHub repos in picker (not just yours)

Repo picker shows only your GitHub accounts by default (GSCAN_OWNERS / GBR_OWNERS).

Examples:
  gbr main 0 dev 1
  gbr -R main 0 dev 1 staging 2
  gbr -f ~/branch-map.txt

Inside fzf: Enter=select highlighted · Tab=multi-select · Esc=cancel

Flow: pick repo(s) → pick branch(es) → type new name(s) → rename

Remote rename: push new branch, delete old on origin, patch default branch if needed.
EOF
        return 0
        ;;
      -*) print -u2 "gbr: unknown option: $1"; return 1 ;;
      *)
        if [[ -z "$pending_old" ]]; then
          pending_old="$1"
        else
          pairs+=("$pending_old" "$1")
          pending_old=""
        fi
        shift
        ;;
    esac
  done

  [[ -z "$pending_old" ]] || {
    print -u2 "gbr: incomplete pair — need both old and new branch names"
    return 1
  }

  if [[ -n "$mapfile" ]]; then
    while read -r o n; do
      [[ -n "$o" && -n "$n" ]] && pairs+=("$o" "$n")
    done < <(_gbr_load_pairs_file "$mapfile") || return 1
  fi

  local do_remote=$(( ! local_only ))

  olds=(${(f)"$(_gbr_pairs_old_names "${pairs[@]}")"})

  if (( pick_repos )) || [[ -z "$(git rev-parse --show-toplevel 2>/dev/null)" ]]; then
    repos=(${(f)"$(_gbr_pick_repos "${olds[@]}")"})
  else
    repos=("$(git rev-parse --show-toplevel)")
  fi

  (( ${#repos[@]} )) || return 0

  if (( ! ${#pairs[@]} )); then
    (( ${#repos[@]} > 1 )) && _gbr_print_selected_repos "${repos[@]}"
    if (( ${#repos[@]} == 1 )); then
      _gbr_collect_pairs_interactive "$repos[1]" || return 0
    else
      _gbr_collect_pairs_multi_repo "${repos[@]}" || return 0
    fi
    pairs=("${GBR_PAIRS[@]}")
  fi

  (( ${#pairs[@]} )) || return 0
  _gbr_validate_pairs "${pairs[@]}" || return 1

  _gbr_show_plan "${#repos[@]}" "$do_remote" "${pairs[@]}"

  for d in "${repos[@]}"; do
    for (( i=1; i<=${#pairs[@]}; i+=2 )); do
      _gbr_rename_one "$d" "$pairs[i]" "$pairs[i+1]" "$do_remote" || true
    done
  done
}
