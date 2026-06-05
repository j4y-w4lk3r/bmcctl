## Jay tmux profiles

`jay` loads profile files from `~/.config/jay/profiles/*.zsh`.

Each profile file must define:

- `jay_profile_setup() { ... }`

It will be called with one argument: the tmux session name to create.

Example (skeleton):

```zsh
jay_profile_setup() {
  local session="$1"
  tmux new-session -d -s "$session" -n main -c "$HOME"
}
```

