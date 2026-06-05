# imgconv.zsh — `ic` image converter.
#
# Two fzf pickers: first choose an output format, then multi-select
# images from the current tree. macOS `sips` does the actual encode.

# ic — image convert: fzf multi-select files, then choose a sips output format.
ic() {
  command -v fzf >/dev/null 2>&1 || { echo >&2 "ic: install fzf (brew install fzf)"; return 1; }
  command -v sips >/dev/null 2>&1 || { echo >&2 "ic: sips not found"; return 1; }

  local fmt ext
  fmt=$(
    printf '%s\n' jpeg png tiff bmp gif |
      fzf --prompt="format > " --height=30% --reverse
  ) || return 0
  [[ -n "$fmt" ]] || return 0

  local -a files
  files=(${(f)"$(
    {
      if command -v fd >/dev/null 2>&1; then
        fd -e heic -e HEIC -e heif -e HEIF -e jpg -e JPG -e jpeg -e JPEG -e png -e PNG -e tiff -e TIFF -e bmp -e BMP -e gif -e GIF -e webp -e WEBP . 2>/dev/null
      else
        find . -maxdepth 5 -type f \( \
          -iname '*.heic' -o -iname '*.heif' -o -iname '*.jpg' -o -iname '*.jpeg' \
          -o -iname '*.png' -o -iname '*.tiff' -o -iname '*.bmp' -o -iname '*.gif' \
          -o -iname '*.webp' \
        \) 2>/dev/null
      fi
    } | fzf --multi --prompt="images > " --height=60% --reverse \
             --header=$'Tab=select · Enter=convert · Ctrl-C=cancel'
  )"})
  (( ${#files} )) || return 0

  ext="$fmt"
  [[ "$fmt" == "jpeg" ]] && ext="jpg"

  local ok=0 fail=0 f dir base out
  for f in "${files[@]}"; do
    dir="${f:h}"
    base="${f:t:r}"
    out="${dir}/${base}.${ext}"
    if sips -s format "$fmt" "$f" --out "$out" >/dev/null 2>&1; then
      printf '✓ %s -> %s\n' "$f" "$out"
      (( ok++ ))
    else
      printf '✗ %s (failed)\n' "$f"
      (( fail++ ))
    fi
  done

  printf '\n%d converted, %d failed\n' "$ok" "$fail"
}
