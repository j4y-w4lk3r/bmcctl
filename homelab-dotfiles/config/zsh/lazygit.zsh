# lazygit.zsh — lg wrapper: [Y/n] when not in a git repo (lazygit defaults to y/N).

_lg_read_tty() {
  read -r "$1" </dev/tty
}

# Alias may persist from an earlier .zshrc or pre-wrapper shell session.
unalias lg 2>/dev/null

_lg_config() {
  print -r -- "${LG_CONFIG_FILE:-$HOME/.config/lazygit/config.yml}"
}

lg() {
  local cfg="$(_lg_config)"
  if ! git rev-parse --git-dir &>/dev/null; then
    print -n "Not in a git repository. Create a new git repository? [Y/n] " >&2
    local reply
    _lg_read_tty reply
    if [[ -z "$reply" || "$reply" == [yY] ]]; then
      git init || return $?
    else
      local skip="$HOME/.config/lazygit/not-a-repo-skip.yml"
      LG_CONFIG_FILE="${cfg},${skip}" command lazygit "$@"
      return
    fi
  fi
  LG_CONFIG_FILE="$cfg" command lazygit "$@"
}

export LG_CONFIG_FILE="${LG_CONFIG_FILE:-$HOME/.config/lazygit/config.yml}"
