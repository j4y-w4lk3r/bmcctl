# platform.zsh — macOS/Linux differences (clipboard, open, paths).

# Clipboard: pbcopy on macOS, wl-copy / xclip on Linux.
if command -v pbcopy >/dev/null 2>&1; then
  clipcopy()  { pbcopy; }
  clippaste() { pbpaste; }
elif command -v wl-copy >/dev/null 2>&1; then
  clipcopy()  { wl-copy; }
  clippaste() { wl-paste; }
elif command -v xclip >/dev/null 2>&1; then
  clipcopy()  { xclip -selection clipboard; }
  clippaste() { xclip -selection clipboard -o; }
else
  clipcopy()  { cat >/dev/null; }
  clippaste() { echo "(no clipboard tool)"; }
fi

# Open files: Cursor on macOS if present, else $EDITOR, else xdg-open.
open() {
  emulate -L zsh
  if (( $# == 0 )); then
    ${=EDITOR:-nvim} .
    return $?
  fi
  local a
  for a in "$@"; do
    if [[ "$a" == -* ]]; then
      command xdg-open "$@" 2>/dev/null || command open "$@"
      return $?
    fi
    if [[ "$a" == *"://"* || "$a" == mailto:* ]]; then
      command xdg-open "$@" 2>/dev/null || command open "$@"
      return $?
    fi
  done
  if command -v cursor >/dev/null 2>&1; then
    command cursor "$@"
  else
    ${=EDITOR:-nvim} "$@"
  fi
}
