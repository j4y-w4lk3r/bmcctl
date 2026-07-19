# install-host progress UI — source from install-host.sh only.
# Provides step counter, ETA, progress bar, and a live ticker during long ops.

[[ -n ${_BMCCTL_PROG_LOADED:-} ]] && return 0
_BMCCTL_PROG_LOADED=1

# shellcheck disable=SC2034
PROG_LABEL=""
PROG_START=0
PROG_STEP=0
PROG_STEP_TOTAL=0
PROG_STEP_TITLE=""
PROG_STEP_START=0
PROG_EST_TOTAL=0
PROG_EST_DONE=0
PROG_DETAIL="starting"
PROG_TICK_PID=""
PROG_DETAIL_FILE=""

# ANSI (disable with NO_COLOR=1)
if [[ -n ${NO_COLOR:-} ]]; then
	_C='' _G='' _Y='' _R='' _M='' _B='' _D='' _BD='' _RST=''
else
	_C=$'\033[36m' _G=$'\033[32m' _Y=$'\033[33m' _R=$'\033[31m'
	_M=$'\033[35m' _B=$'\033[34m' _D=$'\033[2m' _BD=$'\033[1m' _RST=$'\033[0m'
fi

prog_init() {
	local label=$1 total_steps=$2 est_total_sec=$3
	PROG_LABEL=$label
	PROG_START=$(date +%s)
	PROG_STEP=0
	PROG_STEP_TOTAL=$total_steps
	PROG_EST_TOTAL=$est_total_sec
	PROG_EST_DONE=0
	PROG_DETAIL_FILE=$(mktemp)
	echo "initializing" >"$PROG_DETAIL_FILE"
	printf '\n%s╔══════════════════════════════════════════════════════════════╗%s\n' "$_BD" "$_RST"
	printf '%s║%s  %s%-14s%s  bmcctl install-host%-27s%s║%s\n' \
		"$_BD" "$_RST" "$_M" "$label" "$_RST" "" "$_BD" "$_RST"
	printf '%s║%s  %s~%s min estimated · %s%d steps%s%*s%s║%s\n' \
		"$_BD" "$_RST" "$_D" "$(( (est_total_sec + 59) / 60 ))" "$_D" "$total_steps" "$_RST" \
		$((27 - ${#total_steps})) "" "$_BD" "$_RST"
	printf '%s╚══════════════════════════════════════════════════════════════╝%s\n\n' "$_BD" "$_RST"
}

_prog_elapsed() {
	local now=$(( $(date +%s) - PROG_START ))
	printf '%dm%02ds' $((now / 60)) $((now % 60))
}

_prog_eta_sec() {
	local rem=$(( PROG_EST_TOTAL - PROG_EST_DONE ))
	(( rem < 0 )) && rem=0
	echo "$rem"
}

_prog_bar() {
	local pct=$1 width=28 i filled=0
	(( pct < 0 )) && pct=0
	(( pct > 100 )) && pct=100
	filled=$(( pct * width / 100 ))
	printf '%s[' "$_M"
	for ((i = 0; i < filled; i++)); do printf '█'; done
	for ((i = filled; i < width; i++)); do printf '░'; done
	printf ']%s %3d%%' "$_RST" "$pct"
}

_prog_status_line() {
	local eta=$(_prog_eta_sec)
	local detail
	detail=$(<"$PROG_DETAIL_FILE" 2>/dev/null || echo "")
	[[ -z $detail ]] && detail="working"
	printf '\r%s┌─%s step %d/%d  %s  elapsed %s  ~%sm left  %s│%s\n' \
		"$_C" "$_RST" "$PROG_STEP" "$PROG_STEP_TOTAL" "$(_prog_bar $(( PROG_EST_DONE * 100 / PROG_EST_TOTAL )))" \
		"$(_prog_elapsed)" "$(( (eta + 59) / 60 ))" "$_D" "$_RST"
	printf '└─ %s▸ %s%s  %s%s\n' "$_BD" "$_RST" "$PROG_STEP_TITLE" "$_C" "${detail:0:72}" "$_RST"
}

prog_stop_tick() {
	if [[ -n $PROG_TICK_PID ]]; then
		kill "$PROG_TICK_PID" 2>/dev/null || true
		wait "$PROG_TICK_PID" 2>/dev/null || true
		PROG_TICK_PID=""
	fi
}

prog_start_tick() {
	prog_stop_tick
	_prog_status_line
	(
		while true; do
			sleep 2
			_prog_status_line
		done
	) &
	PROG_TICK_PID=$!
}

prog_detail() {
	printf '%s' "${1:-}" >"$PROG_DETAIL_FILE"
}

prog_begin_step() {
	local est_sec=$1
	shift
	PROG_STEP=$((PROG_STEP + 1))
	PROG_STEP_TITLE=$*
	PROG_STEP_START=$(date +%s)
	prog_stop_tick
	printf '\n%s━━━ [%d/%d] %s%s%s\n' \
		"$_BD" "$PROG_STEP" "$PROG_STEP_TOTAL" "$_C" "$PROG_STEP_TITLE" "$_RST"
	if [[ -n $est_sec && $est_sec -ge 60 ]]; then
		printf '%s    (~%s min budget for this step)%s\n' "$_D" "$(( (est_sec + 59) / 60 ))" "$_RST"
	elif [[ -n $est_sec && $est_sec -gt 0 ]]; then
		printf '%s    (~%s sec)%s\n' "$_D" "$est_sec" "$_RST"
	fi
	prog_detail "starting…"
}

prog_end_step() {
	local est_sec=${1:-0}
	prog_stop_tick
	local took=$(( $(date +%s) - PROG_STEP_START ))
	PROG_EST_DONE=$(( PROG_EST_DONE + est_sec ))
	printf '%s    step done in %dm%02ds%s\n' "$_D" $((took / 60)) $((took % 60)) "$_RST"
}

prog_ok()   { printf '%s  ✓ %s%s\n' "$_G" "$*" "$_RST"; }
prog_warn() { printf '%s  ! %s%s\n' "$_Y" "$*" "$_RST"; }
prog_die()  { prog_stop_tick; printf '%s  ✗ %s%s\n' "$_R" "$*" "$_RST" >&2; exit "${2:-1}"; }

_prog_detail_from_line() {
	local line=$1
	case "$line" in
		*PowerState=On*|*installer\ is\ running*)
			prog_detail "installer running on host (pacstrap + configure)" ;;
		*waiting*PowerState=On*|*POST*)
			prog_detail "waiting for host POST + live ISO boot" ;;
		*waiting*install\ to\ complete*|*PowerState=Off*)
			prog_detail "unattended install in progress (partition → pacstrap → chroot)" ;;
		*install\ completed*)
			prog_detail "install finished — host powered off" ;;
		*mounted\ nfs:*)
			prog_detail "BMC mounted installer ISO via NFS" ;;
		*boot\ override*)
			prog_detail "boot override set — powering host" ;;
		*\[mkarchiso\]*|*mkarchiso*)
			prog_detail "mkarchiso: building installer image" ;;
		*pacstrap*|*render-config*)
			prog_detail "$line" ;;
	esac
}

# Run a long command; log to file, update detail from output.
# Do NOT pipe through a while-loop that prints to stdout — that deadlocks
# against the main tee when the progress ticker is also writing.
prog_run_logged() {
	local log=$1
	shift
	local tail_pid="" cmd_pid="" st=0
	prog_start_tick
	: >"$log"
	(
		touch "$log"
		tail -n0 -F "$log" 2>/dev/null | while IFS= read -r line; do
			_prog_detail_from_line "$line"
		done
	) &
	tail_pid=$!
	"$@" >>"$log" 2>&1 &
	cmd_pid=$!
	while kill -0 "$cmd_pid" 2>/dev/null; do
		sleep 2
		if [[ -n $PROG_STEP_START ]]; then
			local step_elapsed=$(( $(date +%s) - PROG_STEP_START ))
			local detail
			detail=$(<"$PROG_DETAIL_FILE" 2>/dev/null || true)
			if [[ $detail == *"unattended install in progress"* ]]; then
				prog_detail "unattended install in progress — polling BMC (${step_elapsed}s elapsed, no news is normal)"
			fi
		fi
	done
	wait "$cmd_pid"
	st=$?
	kill "$tail_pid" 2>/dev/null || true
	wait "$tail_pid" 2>/dev/null || true
	# Replay captured output once (avoids competing with the live ticker).
	while IFS= read -r line; do
		printf '%s%s%s\n' "$_D" "$line" "$_RST"
	done <"$log"
	prog_stop_tick
	return "$st"
}

prog_finish() {
	prog_stop_tick
	local total=$(( $(date +%s) - PROG_START ))
	printf '\n%s╔══════════════════════════════════════════════════════════════╗%s\n' "$_G" "$_RST"
	printf '%s║%s  %s✓ install-host finished%s  total %dm%02ds%*s%s║%s\n' \
		"$_G" "$_RST" "$_BD" "$_RST" $((total / 60)) $((total % 60)) \
		$((22)) "" "$_G" "$_RST"
	printf '%s╚══════════════════════════════════════════════════════════════╝%s\n\n' "$_G" "$_RST"
	[[ -n $PROG_DETAIL_FILE && -f $PROG_DETAIL_FILE ]] && rm -f "$PROG_DETAIL_FILE"
}

prog_fail() {
	prog_stop_tick
	printf '\n%s╔══════════════════════════════════════════════════════════════╗%s\n' "$_R" "$_RST"
	printf '%s║%s  %s✗ install-host failed%s at step %d/%d: %s%*s%s║%s\n' \
		"$_R" "$_RST" "$_BD" "$_RST" "$PROG_STEP" "$PROG_STEP_TOTAL" "$PROG_STEP_TITLE" \
		$((29 - ${#PROG_STEP_TITLE})) "" "$_R" "$_RST"
	printf '%s╚══════════════════════════════════════════════════════════════╝%s\n\n' "$_R" "$_RST"
	[[ -n $PROG_DETAIL_FILE && -f $PROG_DETAIL_FILE ]] && rm -f "$PROG_DETAIL_FILE"
}
