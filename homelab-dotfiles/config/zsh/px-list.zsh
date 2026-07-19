# px-list.zsh — lag: git-aware directory listing (any cwd)

: "${PX_ROOT:=$HOME/px}"

_px_eza_sort=(--group-directories-first --sort=extension)

_px_char() {
  python3 -c "import sys; sys.stdout.buffer.write(chr(int(sys.argv[1], 16)).encode('utf-8'))" "$1" 2>/dev/null
}

_px_git_icons() {
  _px_ic_github=$(_px_char f113)
  _px_ic_branch=$(_px_char f418)
  _px_ic_dirty=$(_px_char f044)
  _px_ic_clean=$(_px_char f058)
}
_px_git_icons

_px_git_owner() {
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

_px_git_status_compact() {
  local dir="$1" porcelain counts sum ahead behind
  porcelain=$(git -C "$dir" status --porcelain 2>/dev/null)
  if [[ -n "$porcelain" ]]; then
    printf '\033[31m%s\033[0m' "$_px_ic_dirty"
    [[ "$porcelain" == *'??'* ]] && printf ' \033[33m?\033[0m'
    [[ "$porcelain" == *' M'* || "$porcelain" == *'M '* || "$porcelain" == *'MM'* ]] && printf ' \033[33m!\033[0m'
    [[ "$porcelain" == *$'\nM '* || "$porcelain" == *$'\nA '* || "$porcelain" == 'M '* || "$porcelain" == 'A '* ]] && printf ' \033[32m+\033[0m'
    return
  fi
  counts=$(git -C "$dir" rev-list --left-right --count @{upstream}...HEAD 2>/dev/null) || {
    printf '\033[32m%s\033[0m' "$_px_ic_clean"
    return
  }
  sum=$(echo "$counts" | awk '{print $1+$2}')
  if [[ "$sum" == 0 ]]; then
    printf '\033[32m%s\033[0m' "$_px_ic_clean"
    return
  fi
  behind=${counts%%[[:space:]]*}
  ahead=${counts##*[[:space:]]}
  (( behind )) && printf ' \033[33m↓%s\033[0m' "$behind"
  (( ahead ))  && printf ' \033[33m↑%s\033[0m' "$ahead"
}

_px_git_line() {
  local dir="$1" branch owner
  [[ -d "$dir/.git" ]] || return 1
  owner=$(_px_git_owner "$dir")
  branch=$(git -C "$dir" branch --show-current 2>/dev/null)
  printf ' '
  if [[ -n "$owner" ]]; then
    case "$owner" in
      lso0)       printf '\033[38;5;214m%s\033[0m \033[38;5;214m%-12s\033[0m' "$_px_ic_github" "$owner" ;;
      j4y-w4lk3r) printf '\033[38;5;205m%s\033[0m \033[38;5;205m%-12s\033[0m' "$_px_ic_github" "$owner" ;;
      *)          printf '\033[38;5;141m%s\033[0m \033[38;5;141m%-12s\033[0m' "$_px_ic_github" "$owner" ;;
    esac
  else
    printf '%-14s' '—'
  fi
  printf ' \033[38;5;213m%s\033[0m \033[38;5;213m%-10s\033[0m' "$_px_ic_branch" "${branch:-?}"
  _px_git_status_compact "$dir"
}

_px_visible_len() {
  local s="$1" len
  len=$(print -P -- "$s" | sed $'s/\033\\[[0-9;]*m//g' | wc -m | tr -d ' ')
  print -r -- "$len"
}

_lag() {
  local name entry line gitinfo vis pad maxw=0 i
  local -a names lines gitinfos

  names=(${(f)"$(eza -1a --color=never --icons=never "${_px_eza_sort[@]}" . 2>/dev/null)"})
  (( ${#names[@]} )) || return 0

  for name in "${names[@]}"; do
    [[ "$name" == '.' || "$name" == '..' ]] && continue
    entry="$PWD/$name"
    line=$(eza -lad --icons=always --color=always --no-filesize -- "$name")
    gitinfo=""
    [[ -d "$entry/.git" ]] && gitinfo=$(_px_git_line "$entry" 2>/dev/null)
    lines+=("$line")
    gitinfos+=("$gitinfo")
    vis=$(_px_visible_len "$line")
    (( vis > maxw )) && maxw=$vis
  done

  for i in {1..${#lines[@]}}; do
    line=$lines[i]
    gitinfo=$gitinfos[i]
    if [[ -n "$gitinfo" ]]; then
      vis=$(_px_visible_len "$line")
      pad=$(( maxw - vis + 2 ))
      (( pad < 2 )) && pad=2
      printf '%s%*s' "$line" "$pad" ""
      print -n "$gitinfo"
      print
    else
      print -P -- "$line"
    fi
  done
}

# Git-aware listing for immediate children.
unalias la 2>/dev/null

la() {
  eza --icons=always -la "${_px_eza_sort[@]}" "$@"
}

lag() {
  if (( $# )); then
    eza --icons=always -la "${_px_eza_sort[@]}" "$@"
  else
    _lag "$@"
  fi
}
