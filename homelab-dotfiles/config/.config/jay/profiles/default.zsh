#!/usr/bin/env zsh
#
# Jay profile: default
# Called as: jay_profile_setup <session_name>
#
# Yazi tab layout is driven by the projects.yazi plugin — we don't hardcode
# tabs here. To change which tabs the yazi window opens with, do this from
# inside Yazi:
#   1. Arrange tabs however you want (t to create, T to close, etc.)
#   2. Shift+W then s    -> save current project
#   3. Name it "px"      -> overwrites the existing px project
# Project data is persisted in ~/.local/state/yazi/.dds, so jay will pick
# up the new layout automatically next time.
#
# Override the loaded project name with: JAY_YAZI_PROJECT=foo jay

jay_profile_setup() {
  local session="$1"
  [[ -n "$session" ]] || return 1

  # --- yazi: auto-load a projects.yazi project on launch -------------------
  # Dispatches "plugin projects load <name>" to the yazi instance we just
  # launched, via ya's DDS (uses --client-id + `ya emit-to` so the receiver
  # is explicit). Override the project name with: JAY_YAZI_PROJECT=foo jay
  local yazi_project="${JAY_YAZI_PROJECT:-px}"
  local yazi_id=$RANDOM
  ( (sleep 1.5; ya emit-to "$yazi_id" plugin projects "load $yazi_project") & ) 2>/dev/null

  tmux new-session -d -s "$session" -n yazi -c "$HOME" "yazi --client-id $yazi_id"
  tmux new-window -t "$session" -n btop 'btop'
  tmux new-window -t "$session" -n pikvm "zsh -i -c 'pikvm; exec zsh'"
  tmux new-window -t "$session" -n rui "zsh -i -c 'rui; exec zsh'"

  tmux new-window -t "$session" -n yu0 "zsh -i -c 'tmux wait-for -S yu0-ready; exec zsh'"
  tmux wait-for yu0-ready
  tmux send-keys -t "$session:yu0" 'yu0 restart' Enter

  tmux new-window -t "$session" -n fastfetch "zsh -i -c 'fastfetch; exec zsh'"
  tmux new-window -t "$session" -n fresh "zsh -i -c 'echo \"hello world 🙂\"; exec zsh'"
}

