# bmcctl-greeting — colored install stamp for homelab hosts.
# Reads /etc/bmcctl-install-id (written by bmcctl ISO install.sh).
# Sourced from zshrc.linux on interactive login.

bmcctl_show_greeting() {
  [[ -o interactive ]] || return 0
  [[ -f /etc/bmcctl-install-id ]] || return 0
  [[ -n "${BMCCTL_GREETING_DONE:-}" ]] && return 0
  typeset -g BMCCTL_GREETING_DONE=1

  local line key val host id at_raw at_iso date_fmt time_fmt
  local -A stamp=()

  while IFS= read -r line; do
    [[ "$line" == *"="* ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    stamp[$key]="$val"
  done </etc/bmcctl-install-id

  host="${stamp[hostname]:-$(hostname -s)}"
  id="${stamp[id]:-?}"
  at_raw="${stamp[installed_at]:-}"

  if [[ -n "$at_raw" ]]; then
    at_iso="${at_raw%Z}"
    date_fmt="$(TZ=UTC date -d "${at_iso}Z" +%d/%m/%Y 2>/dev/null)" || date_fmt="?"
    time_fmt="$(TZ=UTC date -d "${at_iso}Z" +%H:%M 2>/dev/null)" || time_fmt="?"
  else
    date_fmt="?"
    time_fmt="?"
  fi

  print -P -- "%F{81}  ┌─ %F{120}bmcctl fresh install%F{81} ─────────────────────────────────────%f"
  print -P -- "%F{81}  │%f  %F{245}host:%f        %B%F{255}${host}%f%b"
  print -P -- "%F{81}  │%f  %F{245}installed:%f   %B%F{255}${date_fmt} ${time_fmt} (UTC)%f%b"
  print -P -- "%F{81}  │%f  %F{245}install-id:%f  %B%F{255}${id}%f%b"
  print -P -- "%F{81}  └────────────────────────────────────────────────────────────%f"
  print ""
}

bmcctl_show_greeting
