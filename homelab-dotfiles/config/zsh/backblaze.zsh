# backblaze.zsh — Dynamic Backblaze B2 helpers via rclone.

# Get the first B2 remote automatically
_BB_REMOTE_NAME=$(rclone listremotes 2>/dev/null | grep -m1 'b2' | sed 's/:$//')
if [[ -z "$_BB_REMOTE_NAME" ]]; then
    # Fallback to first remote if no b2-specific found
    _BB_REMOTE_NAME=$(rclone listremotes 2>/dev/null | head -1 | sed 's/:$//')
fi

# Current active bucket (can be changed with bb use)
_BB_CURRENT_BUCKET=""
_BB_FULL_REMOTE=""

_bb_init() {
    # If no bucket is set, try to find the first bucket
    if [[ -z "$_BB_CURRENT_BUCKET" ]] && [[ -n "$_BB_REMOTE_NAME" ]]; then
        local first_bucket
        first_bucket=$(rclone lsd "${_BB_REMOTE_NAME}:" 2>/dev/null | awk '{print $NF}' | head -1)
        if [[ -n "$first_bucket" ]]; then
            _BB_CURRENT_BUCKET="$first_bucket"
            _BB_FULL_REMOTE="${_BB_REMOTE_NAME}:${_BB_CURRENT_BUCKET}"
        fi
    fi
}

bb() {
    _bb_init
    
    local cmd="${1:-help}"
    case "$cmd" in
        push|pull|ls|size|check|sync|open|help|-h|--help)
            (( $# > 0 )) && shift ;;
        buckets|list)
            shift
            _bb_list_buckets "$@"
            ;;
        use|switch)
            shift
            _bb_use_bucket "$@"
            ;;
        current)
            _bb_current_bucket
            ;;
        create|new)
            shift
            _bb_create_bucket "$@"
            ;;
        delete|remove)
            shift
            _bb_delete_bucket "$@"
            ;;
        info|stats)
            shift
            _bb_bucket_info "$@"
            ;;
        menu|interactive|i)
            _bb_menu
            ;;
        *)
            cmd="push" ;;
    esac
    
    case "$cmd" in
        push)           _bb_push  "$@" ;;
        pull)           _bb_pull  "$@" ;;
        ls)             _bb_ls    "$@" ;;
        size)           _bb_size  "$@" ;;
        check)          _bb_check "$@" ;;
        sync)           _bb_sync  "$@" ;;
        open)           _bb_open ;;
        help|-h|--help) _bb_help ;;
    esac
}

_bb_help() {
    cat <<EOF

[1;36mbb — Backblaze B2 helpers via rclone[0m
Remote: [33m${_BB_REMOTE_NAME}[0m
Current bucket: [33m${_BB_CURRENT_BUCKET:-none}[0m

[1;33m📁 BASIC OPERATIONS[0m
  bb push <src>           Upload (additive, never deletes)
  bb pull <name> [dest]   Download (default: ./<name>)
  bb ls [path]            List B2 contents
  bb size [path]          Show size + file count

[1;33m🔍 VERIFICATION & SYNC[0m
  bb check <src>          Verify local vs B2 (no changes)
  bb sync <src>           ⚠️ MIRROR (deletes remote files not in src)

[1;33m🌐 BUCKET MANAGEMENT[0m
  bb buckets              List all buckets
  bb use <name>           Switch to a different bucket
  bb current              Show current bucket
  bb create <name>        Create a new bucket
  bb delete <name>        Delete a bucket (with confirmation)
  bb info [bucket]        Show bucket statistics

[1;33m🌐 UTILITIES[0m
  bb open                 Open B2 web UI in browser
  bb menu                 Interactive menu mode
  bb help                 This help

[1;33m💡 EXAMPLES[0m
  bb use lsybb0          # Switch to bucket 'lsybb0'
  bb push ~/Photos --transfers 8
  bb pull mybackup ./restore
  bb ls / | less

EOF
}

_bb_list_buckets() {
    echo "📦 Backblaze B2 Buckets (Remote: ${_BB_REMOTE_NAME})"
    echo "═══════════════════════════════════════════"
    
    local buckets
    buckets=$(rclone lsd "${_BB_REMOTE_NAME}:" 2>/dev/null | awk '{print $NF}')
    
    if [[ -z "$buckets" ]]; then
        echo "No buckets found"
        return 1
    fi
    
    while IFS= read -r bucket; do
        if [[ -n "$bucket" ]]; then
            local current=""
            [[ "$bucket" == "$_BB_CURRENT_BUCKET" ]] && current=" ✓ CURRENT"
            printf "\n📁 \033[1;32m%s\033[0m%s\n" "$bucket" "$current"
            
            local stats
            stats=$(rclone size "${_BB_REMOTE_NAME}:$bucket" 2>/dev/null)
            local size
            local count
            size=$(echo "$stats" | grep "Total size" | awk '{print $3, $4}')
            count=$(echo "$stats" | grep "Total objects" | awk '{print $3}')
            
            echo "   Files: ${count:-0}"
            echo "   Size: ${size:-0 B}"
        fi
    done <<< "$buckets"
    
    echo ""
    echo "💡 Use 'bb use <bucket-name>' to switch buckets"
}

_bb_use_bucket() {
    local bucket="${1:-}"
    if [[ -z "$bucket" ]]; then
        echo "Current bucket: ${_BB_CURRENT_BUCKET:-none}"
        echo ""
        echo "Available buckets:"
        rclone lsd "${_BB_REMOTE_NAME}:" 2>/dev/null | awk '{print "  - " $NF}'
        return
    fi
    
    if rclone lsd "${_BB_REMOTE_NAME}:$bucket" &>/dev/null; then
        _BB_CURRENT_BUCKET="$bucket"
        _BB_FULL_REMOTE="${_BB_REMOTE_NAME}:${_BB_CURRENT_BUCKET}"
        echo "✓ Switched to bucket: $bucket"
    else
        echo "✗ Bucket '$bucket' not found"
        echo "Available buckets:"
        rclone lsd "${_BB_REMOTE_NAME}:" 2>/dev/null | awk '{print "  - " $NF}'
        return 1
    fi
}

_bb_current_bucket() {
    if [[ -z "$_BB_CURRENT_BUCKET" ]]; then
        echo "No bucket selected. Use 'bb use <bucket-name>'"
    else
        echo "Current bucket: $_BB_CURRENT_BUCKET"
        echo "Full remote: $_BB_FULL_REMOTE"
    fi
}

_bb_create_bucket() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        echo "Usage: bb create <bucket-name>"
        return 2
    fi
    
    if rclone lsd "${_BB_REMOTE_NAME}:$name" &>/dev/null; then
        echo "✗ Bucket '$name' already exists"
        return 1
    fi
    
    echo "Creating bucket: $name"
    rclone mkdir "${_BB_REMOTE_NAME}:$name"
    
    if [[ $? -eq 0 ]]; then
        echo "✓ Bucket '$name' created successfully"
        echo "  Use 'bb use $name' to switch to it"
    else
        echo "✗ Failed to create bucket"
        return 1
    fi
}

_bb_delete_bucket() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        echo "Usage: bb delete <bucket-name>"
        return 2
    fi
    
    local file_count
    file_count=$(rclone ls "${_BB_REMOTE_NAME}:$name" 2>/dev/null | wc -l | tr -d ' ')
    
    echo "⚠️  WARNING: Deleting bucket '$name'"
    echo "   Files in bucket: $file_count"
    echo "   This action CANNOT be undone!"
    printf "\nType the bucket name to confirm deletion: "
    
    local confirm
    read -r confirm
    
    if [[ "$confirm" != "$name" ]]; then
        echo "Deletion aborted"
        return 1
    fi
    
    rclone purge "${_BB_REMOTE_NAME}:$name"
    
    if [[ $? -eq 0 ]]; then
        echo "✓ Bucket '$name' deleted successfully"
        if [[ "$_BB_CURRENT_BUCKET" == "$name" ]]; then
            _BB_CURRENT_BUCKET=""
            _BB_FULL_REMOTE=""
            echo "Note: Current bucket was deleted"
        fi
    else
        echo "✗ Failed to delete bucket"
        return 1
    fi
}

_bb_bucket_info() {
    local bucket="${1:-$_BB_CURRENT_BUCKET}"
    
    if [[ -z "$bucket" ]]; then
        echo "No bucket specified. Use 'bb info <bucket-name>' or set a current bucket with 'bb use'"
        return 1
    fi
    
    echo "📊 Bucket Information: $bucket"
    echo "═══════════════════════════════════════════"
    
    local stats
    stats=$(rclone size "${_BB_REMOTE_NAME}:$bucket" 2>/dev/null)
    
    if [[ -z "$stats" ]]; then
        echo "✗ Bucket '$bucket' not found or empty"
        return 1
    fi
    
    echo "$stats" | sed 's/^/  /'
}

_bb_push() {
    [[ -n "$1" ]] || { echo "bb push: missing <src>"; return 2; }
    [[ -n "$_BB_CURRENT_BUCKET" ]] || { echo "No bucket selected. Use 'bb use <bucket>' first"; return 1; }
    
    local src="${1%/}"
    local name
    name=$(basename "$src")
    rclone copy "$src" "${_BB_FULL_REMOTE}/${name}" -v --progress "${@:2}"
}  # Fixed: removed extra brace

_bb_pull() {
    [[ -n "$1" ]] || { echo "bb pull: missing <name>"; return 2; }
    [[ -n "$_BB_CURRENT_BUCKET" ]] || { echo "No bucket selected. Use 'bb use <bucket>' first"; return 1; }
    
    local name="$1"
    local dest="${2:-./$name}"
    rclone copy "${_BB_FULL_REMOTE}/${name}" "$dest" -v --progress "${@:3}"
}

_bb_ls() {
    [[ -n "$_BB_CURRENT_BUCKET" ]] || { echo "No bucket selected. Use 'bb use <bucket>' first"; return 1; }
    
    local path="${1:-}"
    rclone lsf "${_BB_FULL_REMOTE}/${path}" "${@:2}"
}

_bb_size() {
    [[ -n "$_BB_CURRENT_BUCKET" ]] || { echo "No bucket selected. Use 'bb use <bucket>' first"; return 1; }
    
    local path="${1:-}"
    rclone size "${_BB_FULL_REMOTE}/${path}"
}

_bb_check() {
    [[ -n "$1" ]] || { echo "bb check: missing <src>"; return 2; }
    [[ -n "$_BB_CURRENT_BUCKET" ]] || { echo "No bucket selected. Use 'bb use <bucket>' first"; return 1; }
    
    local src="${1%/}"
    local name
    name=$(basename "$src")
    rclone check "$src" "${_BB_FULL_REMOTE}/${name}" --one-way "${@:2}"
}

_bb_sync() {
    [[ -n "$1" ]] || { echo "bb sync: missing <src>"; return 2; }
    [[ -n "$_BB_CURRENT_BUCKET" ]] || { echo "No bucket selected. Use 'bb use <bucket>' first"; return 1; }
    
    local src="${1%/}"
    local name
    name=$(basename "$src")
    
    echo "── dry-run: bb sync ${src} → ${_BB_FULL_REMOTE}/${name} ──"
    rclone sync "$src" "${_BB_FULL_REMOTE}/${name}" --dry-run -v "${@:2}" || return $?
    echo
    printf 'This MIRRORS src to B2 (deletes B2 files not in src). Proceed? [y/N] '
    local ans
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "aborted"; return 1; }
    rclone sync "$src" "${_BB_FULL_REMOTE}/${name}" -v --progress "${@:2}"
}

_bb_open() {
    open "https://secure.backblaze.com/b2_buckets.htm"
}

_bb_menu() {
  local choice src name dest path bucket
  while true; do
    # ANSI clear screen and home cursor
    printf '\033[2J\033[H'
    
    printf '\033[1;36m═══════════════════════════════════════════════════════════════════════\033[0m\n'
    printf '  \033[1;37m󰋊 Backblaze B2 Manager - rclone helpers \033[0m\n'
    printf '  Remote: \033[33m󰌽 lsybb0:lsybb0/\033[0m\n'
    printf '\033[1;36m═══════════════════════════════════════════════════════════════════════\033[0m\n'
    printf '\n'
    printf '  \033[1;33m1)\033[0m 󰁝 Push (upload)\n'
    printf '  \033[1;33m2)\033[0m 󰁚 Pull (download)\n'
    printf '  \033[1;33m3)\033[0m 󰈢 List contents\n'
    printf '  \033[1;33m4)\033[0m 󰋓 Check size\n'
    printf '  \033[1;33m5)\033[0m 󰡨 Verify (check)\n'
    printf '  \033[1;31m6)\033[0m 󰃭 Mirror (sync) ⚠️\n'
    printf '  \033[1;33m7)\033[0m 󰇽 List buckets\n'
    printf '  \033[1;33m8)\033[0m 󰋓 Bucket info\n'
    printf '  \033[1;33m9)\033[0m 󰔄 Switch bucket\n'
    printf '  \033[1;33m0)\033[0m 󰃭 Create bucket\n'
    printf '  \033[1;31md)\033[0m 󰆴 Delete bucket ❌\n'
    printf '  \033[1;33mo)\033[0m 󰌽 Open web UI\n'
    printf '  \033[1;33mq)\033[0m 󰈴 Quit\n'
    printf '\n'
    printf '\033[1;36m═══════════════════════════════════════════════════════════════════════\033[0m\n'
    
    printf "󰁛 Choice: "
    read choice
    
    case $choice in
      1)
        printf "󰁝 Local path to push: "
        read src
        test -n "$src" && bb push "$src"
        ;;
      2)
        printf "󰁚 Remote name to pull: "
        read name
        printf "󰁝 Local destination [./%s]: " "$name"
        read dest
        bb pull "$name" "${dest:-./$name}"
        ;;
      3)
        printf "󰈢 Path (empty for root): "
        read path
        bb ls "$path" | less -R
        ;;
      4)
        printf "󰋓 Path (empty for root): "
        read path
        bb size "$path"
        ;;
      5)
        printf "󰡨 Local path to check: "
        read src
        test -n "$src" && bb check "$src"
        ;;
      6)
        printf "󰃭 Local path to mirror: "
        read src
        test -n "$src" && bb sync "$src"
        ;;
      7) 
        printf "󰇽 Listing buckets...\n"
        bb buckets | less -R 
        ;;
      8) 
        printf "󰋓 Fetching bucket info...\n"
        bb info 
        ;;
      9)
        printf "󰔄 Bucket name: "
        read bucket
        bb use "$bucket"
        ;;
      0)
        printf "󰃭 New bucket name: "
        read name
        test -n "$name" && bb create "$name"
        ;;
      d|D)
        printf "󰆴 Bucket name to delete: "
        read name
        test -n "$name" && bb delete "$name"
        ;;
      o|O) 
        printf "󰌽 Opening Backblaze web UI...\n"
        bb open 
        ;;
      q|Q)
        printf "󰈴 Goodbye!\n"
        break
        ;;
      *)
        printf "󰅙 Invalid choice\n"
        sleep 1
        ;;
    esac
    printf "\n"
    printf "󰏦 Press Enter to continue..."
    read
  done
}

# Initialize on load
_bb_init