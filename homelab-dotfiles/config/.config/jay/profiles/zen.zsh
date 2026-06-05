#!/usr/bin/env zsh
jay_profile_setup() {
  local session="$1"
  [[ -n "$session" ]] || return 1

  tmux new-session -d -s "$session" -n yazi -c "$HOME" 'yazi'
  tmux new-window -t "$session" -n pi "zsh -i -c 'pi; exec zsh'"
  tmux new-window -t "$session" -n tls 'tls'
  tmux new-window -t "$session" -n fresh "zsh -i -c 'echo \"hello world 🙂\"; exec zsh'"
}