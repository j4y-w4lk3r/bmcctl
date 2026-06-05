# fzf: Karabiner-friendly bindings
# Requires: ~/.fzf.zsh sourced first (loads fzf widgets + __fzf_select)

# Debug helper: run `fzf_debug_keyseq` then press the key combo.
# It prints the raw bytes (hex) and a quoted string you can paste into bindkey.
if (( $+functions[fzf-file-widget] )) || (( $+functions[fzf-history-widget] )) || (( $+functions[fzf-cd-widget] )); then
  fzf-copy-abs-path-widget() {
    setopt localoptions pipefail no_aliases 2>/dev/null
    local sel abs
    sel="$(__fzf_select -1)"
    local ret=$?
    if [[ $ret -ne 0 || -z "$sel" ]]; then
      zle reset-prompt
      return 0
    fi
    sel="${sel%%[[:space:]]#}"
    abs="${${(Q)sel}:a}"
    print -rn -- "$abs" | pbcopy
    zle reset-prompt
    return 0
  }
  zle -N fzf-copy-abs-path-widget

  # Keep defaults (Ctrl-T / Ctrl-R / Alt-C) untouched.
  # Only add Ctrl-Y for "copy absolute path" (Karabiner maps j+y → Ctrl-Y).
  zle -N fzf-copy-abs-path-widget
  bindkey -M emacs '^Y' fzf-copy-abs-path-widget
  bindkey -M viins '^Y' fzf-copy-abs-path-widget
  bindkey -M vicmd '^Y' fzf-copy-abs-path-widget

  # Karabiner maps j+d → Ctrl-G (extra binding for fzf-cd-widget)
  bindkey -M emacs '^G' fzf-cd-widget
  bindkey -M viins '^G' fzf-cd-widget
  bindkey -M vicmd '^G' fzf-cd-widget
fi
