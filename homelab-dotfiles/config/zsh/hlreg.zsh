# hlreg — homelab host registry on the VPS (Headscale control server).
#
#   hlreg push          report this host to the VPS registry
#   hlreg ls            list registered hosts (from VPS)
#   hlreg show [host]   show one host record
#
# ENV: HLREG_HOST (default j4y-control-01), HLREG_PATH, HLREG_USER

_hlreg_script() {
  local s
  for s in \
    "$HOME/px/bmcctl/scripts/homelab-registry-push.sh" \
    "$HOME/bmcctl/scripts/homelab-registry-push.sh" \
    /usr/local/lib/bmcctl/homelab-registry-push.sh; do
    [[ -x "$s" ]] && { print -r -- "$s"; return 0; }
  done
  return 1
}

_hlreg_ssh() {
  local host="${HLREG_HOST:-j4y-control-01}"
  if command -v tailscale >/dev/null 2>&1; then
    tailscale ssh "${HLREG_USER:-j4y}@${host}" "$@"
  else
    ssh "${HLREG_USER:-j4y}@${host}" "$@"
  fi
}

hlreg() {
  case "${1:-}" in
    push|report)
      local script
      script=$(_hlreg_script) || {
        print -u2 "hlreg: homelab-registry-push.sh not found"
        return 1
      }
      shift
      bash "$script" "$@"
      ;;
    ls|list)
      _hlreg_ssh "python3 -c \"
import json, os
p=os.environ.get('HLREG_PATH', '/home/j4y/homelab/hosts.json')
d=json.load(open(p))
for h in d.get('hosts', []):
    print(f\\\"{h.get('hostname','?'):12}  {h.get('tailscale_ip') or '-':15}  {h.get('lan_ip') or '-':15}  {h.get('installed_at') or '-'}\\\")
\"" 2>/dev/null || {
        print -u2 "hlreg: could not read registry on ${HLREG_HOST:-j4y-control-01}"
        return 1
      }
      ;;
    show)
      shift
      local name="${1:-$(hostname -s)}"
      _hlreg_ssh "python3 -c \"
import json, os, sys
p=os.environ.get('HLREG_PATH', '/home/j4y/homelab/hosts.json')
d=json.load(open(p))
name=sys.argv[1]
for h in d.get('hosts', []):
    if h.get('hostname') == name:
        import pprint; pprint.pp(h)
        break
else:
    print('not found:', name); sys.exit(1)
\"" "$name"
      ;;
    -h|--help|help|"")
      cat <<'EOF'
hlreg — homelab host registry (stored on VPS)

  hlreg push          push this host's install stamp to the VPS
  hlreg ls            list all registered hosts
  hlreg show [name]   show one host (default: this hostname)

ENV
  HLREG_HOST   SSH target (default: j4y-control-01)
  HLREG_PATH   remote JSON path (default: ~/homelab/hosts.json)
EOF
      ;;
    *)
      print -u2 "hlreg: unknown command: $1 (try: hlreg help)"
      return 1
      ;;
  esac
}
