# 1Password CLI — lazy auth (see scripts/op-ensure-auth.sh)
export OP_BIOMETRIC_UNLOCK_ENABLED="${OP_BIOMETRIC_UNLOCK_ENABLED:-true}"
export OP_ACCOUNT="${OP_ACCOUNT:-j4y00}"

_op_session_file="${HOME}/.config/op/cli-session.env"
[[ -f "$_op_session_file" ]] && source "$_op_session_file"

_op_ensure_signin() {
  command -v op >/dev/null 2>&1 || return 1
  op whoami &>/dev/null && return 0
  # Non-interactive: desktop app integration when unlocked.
  OP_BIOMETRIC_UNLOCK_ENABLED=true op signin --account "$OP_ACCOUNT" &>/dev/null || return 1
  local token
  token=$(OP_BIOMETRIC_UNLOCK_ENABLED=true op signin --account "$OP_ACCOUNT" --raw 2>/dev/null) || return 1
  [[ -z "$token" ]] && return 1
  mkdir -p "${_op_session_file:h}"
  print -r -- "export OP_ACCOUNT=${OP_ACCOUNT}" >"$_op_session_file"
  print -r -- "export OP_SESSION_${OP_ACCOUNT}=${token}" >>"$_op_session_file"
  chmod 600 "$_op_session_file"
  source "$_op_session_file"
}

op() {
  _op_ensure_signin || true
  command op "$@"
}
