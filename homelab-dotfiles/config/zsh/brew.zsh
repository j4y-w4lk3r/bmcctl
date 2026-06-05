# Brew sync — update, upgrade, and clean up with gum spinners.
brs() {
  gum style \
    --border rounded --border-foreground 6 --padding "0 2" --margin "0 0 1 0" \
    --bold \
    "Brew Sync" \
    "" \
    "Enter your sudo password to continue"

  sudo -p '' -v || return 1
  clear

  gum style \
    --border rounded --border-foreground 4 --padding "0 2" --margin "0 0 1 0" \
    --bold \
    "Brew Sync" \
    "" \
    "update · formulae · casks · cleanup"

  local log="/tmp/brs-$(date +%Y%m%d_%H%M%S).log"
  : > "$log"

  _brs_step() {
    local title="$1"; shift
    printf "\n=== %s ===\n" "$title" >> "$log"

    gum spin --spinner dot --title "$title..." -- "$@" 2>&1 | tee -a "$log" > /dev/null

    local rc=${pipestatus[1]}

    if [ "$rc" -ne 0 ]; then
      gum style --foreground 1 --bold "✗ Failed: $title"
      echo "log: $log"
      return 1
    fi
  }

  _brs_step "Updating Homebrew"    brew update || return 1
  _brs_step "Upgrading formulae"   brew upgrade --formula || return 1

  _brs_step "Upgrading casks" brew upgrade --cask --greedy || {
    gum style --foreground 3 "⚠ Some casks failed, continuing anyway"
    echo "log: $log"
  }

  _brs_step "Removing unused deps" brew autoremove || return 1
  _brs_step "Cleaning up"          brew cleanup || return 1

  echo ""
  gum style \
    --border rounded --border-foreground 2 --padding "0 2" --margin "0 0" \
    --bold --foreground 2 \
    "✓ Brew sync complete" \
    "" \
    "log: $log"

  unfunction _brs_step
}