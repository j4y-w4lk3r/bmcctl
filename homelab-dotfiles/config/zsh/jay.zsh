# jay — tmux session launcher with per-profile setup (powered by fzf).
#
#   jay     1) fzf-pick a profile from ~/.config/jay/profiles/*.zsh
#           2) fzf-pick (or type) a tmux session name from existing
#              sessions + the defaults: j4y, j4y1, j4y2, j4y3, j4y4
#           3) if the session exists -> just `tmux attach`
#              else -> source the profile (which must define
#                      `jay_profile_setup <session>`) and attach
#
# Profiles live in ~/.config/jay/profiles/ and each one is a small zsh
# script that defines a function:
#
#   jay_profile_setup() {
#     local session="$1"
#     tmux new-session -d -s "$session" -n main
#     # ...split panes, set env, cd into projects, etc.
#   }
#
# Sourced from .zshrc:
#   [ -f ~/.config/zsh/jay.zsh ] && source ~/.config/zsh/jay.zsh

jay() {
  local profiles_dir="$HOME/.config/jay/profiles"
  local profile_path profile_name
  local -a profile_paths
  local base="j4y" chosen

  [[ -d "$profiles_dir" ]] || { echo "jay: missing $profiles_dir"; return 1; }

  # Use zsh globbing (not `ls`) to avoid iconified output from aliases (eza --icons).
  profile_paths=("$profiles_dir"/*.zsh(N))
  (( ${#profile_paths} )) || { echo "jay: no profiles in $profiles_dir"; return 1; }

  profile_path=$(
    printf '%s\n' "${profile_paths[@]}" |
      fzf --prompt="jay profile > " --height=40% --reverse --delimiter='/' --with-nth=-1
  )
  [[ -n "$profile_path" ]] || return 0
  profile_name="${profile_path:t:r}"

  chosen=$(
    {
      tmux list-sessions -F '#S' 2>/dev/null
      printf '%s\n' "$base" "${base}1" "${base}2" "${base}3" "${base}4"
    } | awk 'NF' | sort -u | fzf --prompt="jay session > " --height=40% --reverse
  )
  [[ -n "$chosen" ]] || return 0

  if tmux has-session -t "$chosen" 2>/dev/null; then
    tmux attach -t "$chosen"
    return
  fi

  unset -f jay_profile_setup 2>/dev/null
  source "$profile_path" || { echo "jay: failed to load $profile_path"; return 1; }
  typeset -f jay_profile_setup >/dev/null || { echo "jay: profile must define jay_profile_setup()"; return 1; }

  jay_profile_setup "$chosen" || return 1
  tmux attach-session -t "$chosen"
}
