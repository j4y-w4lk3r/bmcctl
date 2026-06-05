# gid — git/gh account manager (powered by fzf).
#
#   gid               fzf-pick + switch (most common — default)
#   gid w[ho]         show current git + gh identity
#   gid l[ist]        list saved accounts
#   gid add           interactively add a new account row
#   gid login [user]  run `gh auth login` + (optionally) append to TSV
#   gid edit          open ~/.config/git-accounts.tsv in $EDITOR
#   gid rm <label>    remove an account
#   gid -h | help     show usage
#
# Account data lives in ~/.config/git-accounts.tsv (TAB-separated):
#
#   label   name   email                                          gh_user
#   lso0    WG011  141449357+WG011@users.noreply.github.com       lso0
#   j4y     j4y    j4y_w4lk3r@pobox.com                            j4y-w4lk3r
#
# Backwards compat: gswitch / gwhoami / gsw all still work; they just call
# `gid` under the hood. Use `gid` going forward — shorter and discoverable.
#
# Sourced from .zshrc:
#   [ -f ~/.config/zsh/git-account.zsh ] && source ~/.config/zsh/git-account.zsh

gid() {
    local cfg="${GIT_ACCOUNTS_FILE:-$HOME/.config/git-accounts.tsv}"
    local sub="${1:-switch}"
    case "$sub" in
        ""|switch|sw|s)        _gid_switch "$cfg" ;;
        who|whoami|w)          _gid_who ;;
        list|ls|l)             _gid_list "$cfg" ;;
        add|new|a)             _gid_add "$cfg" ;;
        login|auth)            _gid_login "$cfg" "${@:2}" ;;
        edit|e)                _gid_edit "$cfg" ;;
        rm|remove|del|delete)  _gid_rm "$cfg" "${2:-}" ;;
        help|-h|--help|h)      _gid_help ;;
        *)
            print -u2 -- "gid: unknown subcommand: $sub"
            print -u2 -- "(run \`gid -h\` for usage)"
            return 2
            ;;
    esac
}

# ---- subcommand implementations -------------------------------------------

_gid_help() {
    cat <<'EOF'
gid — git/gh account manager

USAGE
  gid                       fzf-pick + switch (default)
  gid w   | who             show current git + gh identity
  gid l   | list            list saved accounts
  gid add                   interactively add a new account row
  gid login [gh_user]       gh auth login → optionally append to TSV
  gid edit                  open the TSV in $EDITOR
  gid rm <label>            remove an account
  gid -h  | help            this message

CONFIG
  ~/.config/git-accounts.tsv     TAB-separated: label name email gh_user

EXAMPLES
  gid                       # quick switch
  gid login                 # log into a new GH account, then append to TSV
  gid login j4y-w4lk3r      # log in specifically as j4y-w4lk3r
  gid add                   # add a row without authenticating yet
  gid w                     # who am I right now (git + gh)?

BACKWARDS COMPAT
  gswitch / gsw  → gid switch
  gwhoami        → gid who
EOF
}

_gid_require_fzf() {
    if ! command -v fzf >/dev/null 2>&1; then
        print -u2 -- "gid: fzf not in PATH (install: brew install fzf)"
        return 1
    fi
}

_gid_require_cfg() {
    local cfg="$1"
    if [[ ! -f "$cfg" ]]; then
        print -u2 -- "gid: no config at $cfg"
        print -u2 -- "     run \`gid add\` to create one"
        return 1
    fi
}

_gid_switch() {
    local cfg="$1"
    _gid_require_cfg "$cfg" || return 1
    _gid_require_fzf       || return 1

    local sel
    sel=$(awk -F'\t' '!/^#/ && NF>=4 {
        printf "%-12s | %-10s | %-44s | %s\n", $1, $2, $3, $4
    }' "$cfg" | fzf \
        --prompt="git/gh account> " \
        --height=40% --reverse --no-mouse --border \
        --header="$(printf '%-12s | %-10s | %-44s | %s' label name email gh_user)") || return 0

    local label name email gh_user
    label=${${(s:|:)sel}[1]// /}
    name=${${(s:|:)sel}[2]## #};   name=${name%% #}
    email=${${(s:|:)sel}[3]## #};  email=${email%% #}
    gh_user=${${(s:|:)sel}[4]## #}; gh_user=${gh_user%% #}

    git config --global user.name  "$name"
    git config --global user.email "$email"
    print -P "%F{green}✓ git%f $name <$email>"

    if gh auth switch --hostname github.com --user "$gh_user" >/dev/null 2>&1; then
        print -P "%F{green}✓ gh %f switched active account to %B$gh_user%b"
    else
        print -P "%F{yellow}⚠ gh %f not yet logged in as %B$gh_user%b"
        print "    run:  gid login $gh_user"
    fi
}

_gid_who() {
    local n e g
    n=$(git config --global --get user.name  2>/dev/null)
    e=$(git config --global --get user.email 2>/dev/null)
    g=$(gh api user --jq .login 2>/dev/null) || g="(gh: not logged in or token invalid)"
    print -P "%F{cyan}git%f $n <$e>"
    print -P "%F{cyan}gh %f $g"
}

_gid_list() {
    local cfg="$1"
    if [[ ! -f "$cfg" ]]; then
        print "(no accounts saved — run \`gid add\`)"
        return
    fi
    awk -F'\t' '!/^#/ && NF>=4 {
        printf "  %-10s  name=%-12s  email=%-40s  gh=%s\n", $1, $2, $3, $4
    }' "$cfg"
}

_gid_add() {
    local cfg="$1"
    local label name email gh_user

    print "Add a new git/gh account to $cfg"
    print
    read "label?Label (short, e.g. work or personal): "
    read "name?Git author name (e.g. Jane Doe): "
    read "email?Git author email: "
    read "gh_user?GitHub username: "

    if [[ -z "$label" || -z "$name" || -z "$email" || -z "$gh_user" ]]; then
        print -P "%F{red}✗%f all four fields are required, aborting"
        return 1
    fi

    # Make sure the parent dir exists; create the file with header if first row.
    mkdir -p "${cfg:h}"
    if [[ ! -f "$cfg" ]]; then
        cat > "$cfg" <<'EOF'
# git/gh account switcher data — TAB-separated columns:
#   label   name   email                                          gh_user
EOF
    fi

    # Overwrite if label already exists (warn first).
    if grep -q "^${label}	" "$cfg" 2>/dev/null; then
        print -P "%F{yellow}⚠%f label '$label' already exists — overwriting"
        local tmp
        tmp=$(mktemp)
        grep -v "^${label}	" "$cfg" > "$tmp" && mv "$tmp" "$cfg"
    fi

    printf '%s\t%s\t%s\t%s\n' "$label" "$name" "$email" "$gh_user" >> "$cfg"
    print -P "%F{green}✓%f added '$label' to $cfg"
    print
    print "Next: run  gid login $gh_user  to authenticate gh."
}

_gid_login() {
    local cfg="$1"
    local hint="${2:-}"
    _gid_require_fzf || return 1

    # Step 1: fzf-pick which account we're logging in for. Existing rows
    # come from the TSV; the synthetic '+ new account' row lets the user
    # add an account on the fly without first running `gid add`.
    local rows new_row sel
    new_row="+ new account                                                                                                          "
    if [[ -f "$cfg" ]]; then
        rows=$(awk -F'\t' '!/^#/ && NF>=4 {
            printf "%-12s | %-10s | %-44s | %s\n", $1, $2, $3, $4
        }' "$cfg")
    fi
    sel=$(printf '%s\n%s\n' "$rows" "$new_row" | sed '/^$/d' | fzf \
        --prompt="log in as> " \
        --height=40% --reverse --no-mouse --border \
        --header="$(printf '%-12s | %-10s | %-44s | %s' label name email gh_user)") || return 0

    # Step 2: extract identity. If the user chose '+ new account', prompt
    # for the four fields once. Otherwise parse them out of the fzf line.
    local label name email gh_user
    if [[ "$sel" == "+ new account"* ]]; then
        print
        print -P "%F{cyan}New account%f — answer 4 short questions, then paste a token:"
        read "label?  label (short, e.g. work or personal): "
        read "name?  git author name: "
        read "email?  git author email: "
        read "gh_user?  GitHub username: "
        if [[ -z "$label" || -z "$name" || -z "$email" || -z "$gh_user" ]]; then
            print -P "%F{red}✗%f all four fields are required, aborting"
            return 1
        fi
    else
        label=${${(s:|:)sel}[1]// /}
        name=${${(s:|:)sel}[2]## #};   name=${name%% #}
        email=${${(s:|:)sel}[3]## #};  email=${email%% #}
        gh_user=${${(s:|:)sel}[4]## #}; gh_user=${gh_user%% #}
    fi

    # Step 3: open the PAT creation page in the browser and prompt for it.
    # Only ONE input from the user from this point on — the token itself.
    print
    print -P "%F{cyan}Logging in as%f %B$gh_user%b ($label)"
    print "Opening PAT creation page in your browser..."
    print "  https://github.com/settings/tokens/new"
    print "  → Suggested scopes:  repo, read:org, gist, workflow"
    if command -v open >/dev/null 2>&1; then
        open "https://github.com/settings/tokens/new?description=gh-cli-${gh_user}&scopes=repo,read:org,gist,workflow" >/dev/null 2>&1
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "https://github.com/settings/tokens/new?description=gh-cli-${gh_user}&scopes=repo,read:org,gist,workflow" >/dev/null 2>&1
    fi
    print

    local token
    if ! read -s "token?Paste your GitHub PAT (hidden — press Enter when done): "; then
        print
        print -P "%F{red}✗%f no token read, aborting"
        return 1
    fi
    print  # newline after silent read
    if [[ -z "$token" ]]; then
        print -P "%F{red}✗%f no token provided, aborting"
        return 1
    fi

    # Step 4: hand the token to gh non-interactively. --with-token reads
    # the token from stdin and skips every other prompt. --git-protocol
    # https also configures gh as the git credential helper for github.com.
    if ! print -r -- "$token" | gh auth login --hostname github.com --git-protocol https --with-token; then
        print -P "%F{red}✗%f gh auth login rejected the token"
        return 1
    fi

    # Step 5: verify which account gh actually thinks we are now. If the
    # token belongs to a different user than what's in the TSV row we
    # picked, prefer the truth (the token's actual owner).
    local actual
    actual=$(gh api user --jq .login 2>/dev/null) || {
        print -P "%F{red}✗%f gh auth stored, but cannot read /user — token may lack 'read:user' scope"
        return 1
    }
    if [[ "$actual" != "$gh_user" ]]; then
        print -P "%F{yellow}⚠%f token belongs to '$actual', not '$gh_user' — using actual"
        gh_user="$actual"
    fi

    # Step 6: make this the active gh account (no-op if it already was).
    gh auth switch --hostname github.com --user "$gh_user" >/dev/null 2>&1

    # Step 7: persist the row to the TSV if it's new.
    mkdir -p "${cfg:h}"
    [[ -f "$cfg" ]] || printf '# label\tname\temail\tgh_user\n' > "$cfg"
    if ! grep -q "^${label}	" "$cfg" 2>/dev/null; then
        printf '%s\t%s\t%s\t%s\n' "$label" "$name" "$email" "$gh_user" >> "$cfg"
        print -P "%F{green}✓%f added '$label' to $cfg"
    fi

    # Step 8: apply git config so commits start using this identity right away.
    git config --global user.name  "$name"
    git config --global user.email "$email"

    print
    print -P "%F{green}✓ git%f $name <$email>"
    print -P "%F{green}✓ gh %f $gh_user (active)"
}

_gid_edit() {
    local cfg="$1"
    "${EDITOR:-vi}" "$cfg"
}

_gid_rm() {
    local cfg="$1" label="$2"
    if [[ -z "$label" ]]; then
        print -u2 -- "Usage: gid rm <label>"
        print -u2 -- "       (run \`gid list\` to see labels)"
        return 2
    fi
    if [[ ! -f "$cfg" ]] || ! grep -q "^${label}	" "$cfg" 2>/dev/null; then
        print -P "%F{yellow}⚠%f no account labeled '$label' in $cfg"
        return 1
    fi
    local tmp
    tmp=$(mktemp)
    grep -v "^${label}	" "$cfg" > "$tmp" && mv "$tmp" "$cfg"
    print -P "%F{green}✓%f removed '$label' from $cfg"
}

# ---- backwards compat -----------------------------------------------------

gswitch() { gid switch }
gwhoami() { gid who }
alias gsw='gid switch'
