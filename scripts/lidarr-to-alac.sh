#!/usr/bin/env bash
# lidarr-to-alac.sh — lossless (prefer FLAC) → parallel ALAC tree + cover embed.
# Primary: Lidarr Docker/Linux Custom Script (On Release Import / On Upgrade).
# Also: CLI for batch tests. Does not write into the master/FLAC root.
#
# Cover priority (exact):
#   1. Embedded picture from the source lossless file
#   2. Album folder cover.jpg / Cover.jpg
#   3. Album folder folder.jpg / Folder.jpg
#   4. Other Lidarr art in the album folder (named list; prefer larger)
#   5. Cover Art Archive, only with a MusicBrainz Release ID (never scrape)
#   6. Skip embed, log, treat missing art as non-fatal
set -euo pipefail

VERSION="1.0.0"
CAA_UA="music-library-apple-alac/${VERSION} (https://github.com/wing199901/music-library-apple-alac)"

MASTER_ROOT="${MASTER_ROOT:-/music}"
ALAC_ROOT="${ALAC_ROOT:-/music-alac}"
LOG_FILE="${LOG_FILE:-}"
FFMPEG="${FFMPEG:-ffmpeg}"
FFPROBE="${FFPROBE:-ffprobe}"
CURL_BIN="${CURL_BIN:-curl}"
COVER_ART_ARCHIVE="${COVER_ART_ARCHIVE:-1}"
CAA_RELEASE_URL="${CAA_RELEASE_URL:-https://coverartarchive.org/release/%s/front}"

LOSSY_EXT="|mp3|m4a|aac|ogg|opus|wma|mp4|mpc|"
LOSSLESS_EXT="|flac|dsf|dff|tak|ape|wav|wv|aiff|aif|w64|tta|"

SKIP_DIR_NAMES="|system volume information|\$recycle.bin|recycler|.trash|.trashes|#recycle|@eadir|.spotlight-v100|.fseventsd|"

WORK_DIR=""
CONVERT_OK=0
CONVERT_SKIP=0
CONVERT_FAIL=0
COVER_OK=0
COVER_SKIP=0
COVER_NONE=0

usage() {
  cat <<'EOF'
Usage: lidarr-to-alac.sh [--scan] [--print-cover FILE] [FILE_OR_DIR ...]

Lidarr: wire as Settings → Connect → Custom Script (On Release Import + On Upgrade).
Reads lidarr_eventtype / lidarr_addedtrackpaths (pipe-separated). Test → exit 0.

CLI:
  --scan              Walk MASTER_ROOT (prefer .flac per stem)
  --print-cover FILE  Print "kind<TAB>path" for FILE and exit (cover resolver)
  FILE_OR_DIR         Convert those files, or recurse directories

Env:
  MASTER_ROOT   default /music          (Windows example: M:\)
  ALAC_ROOT     default /music-alac     (Windows example: D:\Music-ALAC)
  LOG_FILE      default $ALAC_ROOT/_lidarr_to_alac.log
  COVER_ART_ARCHIVE=0 to disable Cover Art Archive
  FFMPEG FFPROBE CURL_BIN
EOF
}

log() {
  local msg="$1"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local line="$ts $msg"
  # stderr so command substitutions (cover resolver) stay clean. Ops log is LOG_FILE.
  printf '%s\n' "$line" >&2
  if [[ -n "${LOG_FILE}" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
  fi
}

die() {
  log "ERROR $1"
  exit 1
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

ext_of() {
  local base
  base="$(basename "$1")"
  case "$base" in
    *.*) printf '%s' "${base##*.}" | tr '[:upper:]' '[:lower:]' ;;
    *) printf '' ;;
  esac
}

stem_of() {
  local base
  base="$(basename "$1")"
  printf '%s' "${base%.*}"
}

is_lossy() {
  local e
  e="$(ext_of "$1")"
  [[ "$LOSSY_EXT" == *"|$e|"* ]]
}

is_lossless() {
  local e
  e="$(ext_of "$1")"
  [[ "$LOSSLESS_EXT" == *"|$e|"* ]]
}

is_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

is_lidarr_art_name() {
  # Canonical step-4 name list (case-insensitive). cover.jpg/folder.jpg also
  # appear here so COVER.JPG can still match after exact step 2/3 miss.
  case "$(lower "$1")" in
    cover.jpg|cover.jpeg|cover.png|cover.webp|cover.bmp) return 0 ;;
    folder.jpg|folder.jpeg|folder.png|folder.webp|folder.bmp) return 0 ;;
    poster.jpg|poster.jpeg|poster.png|poster.webp) return 0 ;;
    fanart.jpg|fanart.jpeg|fanart.png|fanart.webp) return 0 ;;
    banner.jpg|banner.jpeg|banner.png|banner.webp) return 0 ;;
    disc.jpg|disc.jpeg|disc.png|disc.webp) return 0 ;;
    front.jpg|front.jpeg|front.png|front.webp) return 0 ;;
    back.jpg|back.jpeg|back.png|back.webp) return 0 ;;
    album.jpg|album.jpeg|album.png|album.webp) return 0 ;;
    albumart.jpg|albumart.jpeg|albumart.png|albumartsmall.jpg) return 0 ;;
    artwork.jpg|artwork.jpeg|artwork.png|artwork.webp) return 0 ;;
    scan.jpg|scan.jpeg|scan.png) return 0 ;;
    logo.jpg|logo.jpeg|logo.png|clearlogo.png|clearlogo.jpg) return 0 ;;
    *) return 1 ;;
  esac
}

skip_dir_name() {
  local n
  n="$(lower "$1")"
  [[ "$n" == .* ]] && return 0
  [[ "$SKIP_DIR_NAMES" == *"|$n|"* ]]
}

canon() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath -m "$p"
  else
    printf '%s' "$p"
  fi
}

under_root() {
  local path root
  path="$(canon "$1")"
  root="$(canon "$2")"
  path="${path%/}"
  root="${root%/}"
  [[ "$path" == "$root" || "$path" == "$root"/* ]]
}

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}

has_video_stream() {
  local file="$1" out
  out="$("$FFPROBE" -v error -select_streams v -show_entries stream=index -of csv=p=0 "$file" 2>/dev/null || true)"
  [[ -n "$out" ]]
}

image_area() {
  local file="$1" dim w h
  dim="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$file" 2>/dev/null || true)"
  w="${dim%x*}"
  h="${dim#*x}"
  if [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]]; then
    printf '%s' $((w * h))
  else
    printf '0'
  fi
}

file_size() {
  if stat -c %s "$1" >/dev/null 2>&1; then
    stat -c %s "$1"
  else
    stat -f %z "$1"
  fi
}

extract_embedded_pic() {
  local src="$1" dest="$2"
  "$FFMPEG" -hide_banner -loglevel error -nostdin -y -i "$src" \
    -an -map 0:v:0 -frames:v 1 -c:v mjpeg -q:v 2 -f image2 "$dest" </dev/null 2>/dev/null
}

pick_larger_image() {
  # stdin: paths, one per line. stdout: winner path (or empty)
  local best="" best_area=-1 best_size=-1 f area sz
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    area="$(image_area "$f")"
    sz="$(file_size "$f")"
    if ((area > best_area || (area == best_area && sz > best_size))); then
      best="$f"
      best_area="$area"
      best_size="$sz"
    fi
  done
  printf '%s' "$best"
}

read_release_mbid_from_tags() {
  local file="$1" line key val key_l
  while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    key="${key#TAG:}"
    key_l="$(lower "$key")"
    case "$key_l" in
      musicbrainz_albumid|"musicbrainz album id"|musicbrainz_releaseid|"musicbrainz release id")
        if is_uuid "$val"; then
          printf '%s' "$val"
          return 0
        fi
        ;;
    esac
  done < <("$FFPROBE" -v error -show_entries format_tags -of default=nw=1 "$file" 2>/dev/null || true)
  return 1
}

resolve_release_mbid() {
  local src="$1" env_id tag_id
  env_id="${lidarr_albumrelease_mbid:-${Lidarr_AlbumRelease_MBId:-${RELEASE_MBID:-}}}"
  if is_uuid "$env_id"; then
    printf '%s' "$env_id"
    return 0
  fi
  tag_id="$(read_release_mbid_from_tags "$src" || true)"
  if is_uuid "$tag_id"; then
    printf '%s' "$tag_id"
    return 0
  fi
  return 1
}

fetch_cover_art_archive() {
  local mbid="$1" dest="$2" url
  # shellcheck disable=SC2059
  url="$(printf "$CAA_RELEASE_URL" "$mbid")"
  "$CURL_BIN" -fsSL -A "$CAA_UA" --max-time 30 -o "$dest" "$url"
}

find_cover() {
  # Prints: kind<TAB>path   kind is one of:
  # embedded, cover.jpg, folder.jpg, folder-art, cover-art-archive, none
  local src="$1"
  local album_dir
  album_dir="$(dirname "$src")"
  local pic="$WORK_DIR/embedded-$(stem_of "$src")-$$.jpg"

  if has_video_stream "$src"; then
    if extract_embedded_pic "$src" "$pic" && [[ -s "$pic" ]]; then
      printf 'embedded\t%s\n' "$pic"
      return 0
    fi
  fi

  local name
  for name in cover.jpg Cover.jpg; do
    if [[ -f "$album_dir/$name" ]]; then
      printf 'cover.jpg\t%s\n' "$album_dir/$name"
      return 0
    fi
  done

  for name in folder.jpg Folder.jpg; do
    if [[ -f "$album_dir/$name" ]]; then
      printf 'folder.jpg\t%s\n' "$album_dir/$name"
      return 0
    fi
  done

  local cand="" f base
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    if is_lidarr_art_name "$base"; then
      cand+="$f"$'\n'
    fi
  done < <(find "$album_dir" -maxdepth 1 -type f -print0 2>/dev/null)
  local winner
  winner="$(printf '%s' "$cand" | pick_larger_image)"
  if [[ -n "$winner" && -f "$winner" ]]; then
    printf 'folder-art\t%s\n' "$winner"
    return 0
  fi

  if [[ "$COVER_ART_ARCHIVE" == "1" ]]; then
    local mbid caa
    mbid="$(resolve_release_mbid "$src" || true)"
    if is_uuid "$mbid"; then
      caa="$WORK_DIR/caa-$mbid.jpg"
      if [[ ! -s "$caa" ]]; then
        if fetch_cover_art_archive "$mbid" "$caa" && [[ -s "$caa" ]]; then
          :
        else
          rm -f "$caa"
        fi
      fi
      if [[ -s "$caa" ]]; then
        printf 'cover-art-archive\t%s\n' "$caa"
        return 0
      fi
      log "COVER_CAA_MISS mbid=$mbid src=$src"
    else
      log "COVER_CAA_SKIP no MusicBrainz Release ID for $src"
    fi
  fi

  printf 'none\t\n'
  return 0
}

prefer_source() {
  local src="$1"
  local dir stem flac
  dir="$(dirname "$src")"
  stem="$(stem_of "$src")"
  flac="$dir/$stem.flac"
  if [[ -f "$flac" ]]; then
    printf '%s' "$flac"
  else
    printf '%s' "$src"
  fi
}

rel_under_master() {
  local src="$1"
  local full root
  full="$(canon "$src")"
  root="$(canon "$MASTER_ROOT")"
  root="${root%/}"
  full="${full%/}"
  if [[ "$full" == "$root" ]]; then
    printf ''
    return 0
  fi
  if [[ "$full" == "$root"/* ]]; then
    printf '%s' "${full#"$root"/}"
    return 0
  fi
  return 1
}

dest_for_source() {
  local src="$1" rel dir stem dest
  rel="$(rel_under_master "$src")" || return 1
  dir="$(dirname "$rel")"
  stem="$(stem_of "$src")"
  if [[ "$dir" == "." ]]; then
    dest="$(canon "$ALAC_ROOT")/$stem.m4a"
  else
    dest="$(canon "$ALAC_ROOT")/$dir/$stem.m4a"
  fi
  printf '%s' "$dest"
}

assert_dest_safe() {
  local dest="$1"
  if under_root "$dest" "$MASTER_ROOT"; then
    log "REFUSE would write ALAC inside MASTER_ROOT dest=$dest master=$MASTER_ROOT"
    return 1
  fi
  if ! under_root "$dest" "$ALAC_ROOT"; then
    log "REFUSE dest not under ALAC_ROOT dest=$dest alac=$ALAC_ROOT"
    return 1
  fi
  return 0
}

needs_convert() {
  local src="$1" dest="$2"
  if [[ ! -f "$dest" ]] || [[ ! -s "$dest" ]]; then
    return 0
  fi
  local sm dm
  sm="$(stat -c %Y "$src" 2>/dev/null || stat -f %m "$src")"
  dm="$(stat -c %Y "$dest" 2>/dev/null || stat -f %m "$dest")"
  [[ "$sm" -gt "$dm" ]]
}

convert_one() {
  local src="$1" dest="$2"
  local partial dir
  dir="$(dirname "$dest")"
  mkdir -p "$dir"
  # Same-volume temp; .partial.m4a + -f mp4 (plain .m4a.partial fails the mp4 muxer)
  partial="${dest%.m4a}.partial.m4a"
  rm -f "$partial"
  if ! "$FFMPEG" -hide_banner -loglevel error -nostdin -y -i "$src" \
    -map 0:a:0 -map_metadata 0 -vn -c:a alac -f mp4 "$partial" </dev/null; then
    rm -f "$partial"
    return 1
  fi
  if [[ ! -s "$partial" ]]; then
    rm -f "$partial"
    return 1
  fi
  mv -f "$partial" "$dest"
  return 0
}

embed_cover() {
  local dest="$1" cover="$2"
  local tmp
  tmp="${dest%.m4a}.embed.partial.m4a"
  rm -f "$tmp"
  if ! "$FFMPEG" -hide_banner -loglevel error -nostdin -y \
    -i "$dest" -i "$cover" \
    -map 0:a:0 -map 1:0 -map_metadata 0 \
    -c:a copy -c:v:0 mjpeg -disposition:v:0 attached_pic \
    -f mp4 "$tmp" </dev/null; then
    rm -f "$tmp"
    return 1
  fi
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$dest"
  return 0
}

process_source() {
  local raw="$1"
  local src dest kind cover

  if [[ ! -f "$raw" ]]; then
    log "SKIP_MISSING $raw"
    return 0
  fi

  src="$(prefer_source "$raw")"

  if is_lossy "$src"; then
    log "SKIP_LOSSY $src"
    CONVERT_SKIP=$((CONVERT_SKIP + 1))
    return 0
  fi
  if ! is_lossless "$src"; then
    log "SKIP_NOT_LOSSLESS $src"
    CONVERT_SKIP=$((CONVERT_SKIP + 1))
    return 0
  fi

  if ! dest="$(dest_for_source "$src")"; then
    log "SKIP_OUTSIDE_MASTER $src master=$MASTER_ROOT"
    CONVERT_SKIP=$((CONVERT_SKIP + 1))
    return 0
  fi
  if ! assert_dest_safe "$dest"; then
    CONVERT_FAIL=$((CONVERT_FAIL + 1))
    return 0
  fi

  if needs_convert "$src" "$dest"; then
    log "CONV $src -> $dest"
    if convert_one "$src" "$dest"; then
      CONVERT_OK=$((CONVERT_OK + 1))
      log "CONV_OK $dest"
    else
      CONVERT_FAIL=$((CONVERT_FAIL + 1))
      log "CONV_FAIL $src"
      return 0
    fi
  else
    CONVERT_SKIP=$((CONVERT_SKIP + 1))
    log "SKIP_UPTODATE $dest"
  fi

  if has_video_stream "$dest"; then
    log "COVER_SKIP already has video/attached pic: $dest"
    COVER_SKIP=$((COVER_SKIP + 1))
    return 0
  fi

  IFS=$'\t' read -r kind cover <<<"$(find_cover "$src")"
  if [[ "$kind" == "none" || -z "$cover" ]]; then
    log "COVER_NONE no art for $dest (convert ok; missing art non-fatal)"
    COVER_NONE=$((COVER_NONE + 1))
    return 0
  fi

  log "COVER_EMBED kind=$kind cover=$cover dest=$dest"
  if embed_cover "$dest" "$cover"; then
    COVER_OK=$((COVER_OK + 1))
    log "COVER_OK kind=$kind dest=$dest"
  else
    log "COVER_FAIL kind=$kind dest=$dest (convert kept; embed non-fatal)"
    COVER_NONE=$((COVER_NONE + 1))
  fi
}

path_has_skip_dir() {
  local f="$1" part
  local rest="$f"
  while [[ "$rest" == */* ]]; do
    part="${rest%%/*}"
    rest="${rest#*/}"
    if [[ -n "$part" ]] && skip_dir_name "$part"; then
      return 0
    fi
  done
  if [[ -n "$rest" ]] && skip_dir_name "$rest"; then
    return 0
  fi
  return 1
}

collect_scan_sources() {
  # Prefer .flac per (parent, stem); else other lossless. Never lossy.
  local root="$1"
  local dirpath f ext stem key
  declare -A chosen=()

  while IFS= read -r -d '' f; do
    path_has_skip_dir "$f" && continue
    ext="$(ext_of "$f")"
    [[ "$LOSSLESS_EXT" == *"|$ext|"* ]] || continue
    dirpath="$(dirname "$f")"
    stem="$(stem_of "$f")"
    key="$dirpath/$stem"
    if [[ "$ext" == "flac" ]]; then
      chosen["$key"]="$f"
    elif [[ -z "${chosen[$key]+x}" ]]; then
      chosen["$key"]="$f"
    fi
  done < <(find "$root" -type f -print0 2>/dev/null)

  local k
  for k in "${!chosen[@]}"; do
    printf '%s\n' "${chosen[$k]}"
  done
}

collect_dir_sources() {
  collect_scan_sources "$1"
}

process_path_arg() {
  local p="$1"
  if [[ -d "$p" ]]; then
    local f
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      process_source "$f"
    done < <(collect_dir_sources "$p" | sort)
  else
    process_source "$p"
  fi
}

require_tools() {
  command -v "$FFMPEG" >/dev/null 2>&1 || die "ffmpeg not found ($FFMPEG)"
  command -v "$FFPROBE" >/dev/null 2>&1 || die "ffprobe not found ($FFPROBE)"
}

init_paths() {
  MASTER_ROOT="$(canon "$MASTER_ROOT")"
  ALAC_ROOT="$(canon "$ALAC_ROOT")"
  if [[ -z "$LOG_FILE" ]]; then
    LOG_FILE="$ALAC_ROOT/_lidarr_to_alac.log"
  fi
  mkdir -p "$ALAC_ROOT"
  if under_root "$ALAC_ROOT" "$MASTER_ROOT" && [[ "$(canon "$ALAC_ROOT")" == "$(canon "$MASTER_ROOT")" ]]; then
    die "ALAC_ROOT must not equal MASTER_ROOT (got $ALAC_ROOT)"
  fi
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lidarr-to-alac.XXXXXX")"
  trap cleanup EXIT
}

lidarr_event() {
  printf '%s' "${lidarr_eventtype:-${Lidarr_EventType:-}}"
}

lidarr_added_paths() {
  printf '%s' "${lidarr_addedtrackpaths:-${Lidarr_AddedTrackPaths:-}}"
}

main() {
  local do_scan=0 print_cover="" args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --scan)
        do_scan=1
        shift
        ;;
      --print-cover)
        print_cover="${2:-}"
        shift 2 || die "--print-cover requires a file"
        ;;
      --)
        shift
        args+=("$@")
        break
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done

  require_tools

  local event
  event="$(lidarr_event)"
  if [[ "$event" == "Test" ]]; then
    # stdout only (Lidarr Debug). Do not write stderr — Lidarr records stderr as Error.
    printf 'lidarr-to-alac: Test OK\n'
    exit 0
  fi

  init_paths
  log "START version=$VERSION master=$MASTER_ROOT alac=$ALAC_ROOT event=${event:-cli}"

  if [[ -n "$print_cover" ]]; then
    local line
    line="$(find_cover "$print_cover")"
    printf '%s\n' "$line"
    log "PRINT_COVER $print_cover -> $line"
    exit 0
  fi

  if [[ "$event" == "AlbumDownload" ]]; then
    local added paths_ifs
    added="$(lidarr_added_paths)"
    if [[ -z "$added" ]]; then
      log "AlbumDownload with empty lidarr_addedtrackpaths; nothing to do"
      exit 0
    fi
    local p paths_ifs
    paths_ifs="$IFS"
    set -f
    IFS='|'
    # shellcheck disable=SC2086
    set -- $added
    IFS="$paths_ifs"
    set +f
    for p in "$@"; do
      [[ -n "$p" ]] || continue
      process_source "$p"
    done
  elif [[ "$do_scan" -eq 1 ]]; then
    [[ -d "$MASTER_ROOT" ]] || die "MASTER_ROOT not a directory: $MASTER_ROOT"
    local f
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      process_source "$f"
    done < <(collect_scan_sources "$MASTER_ROOT" | sort)
  elif [[ ${#args[@]} -gt 0 ]]; then
    local a
    for a in "${args[@]}"; do
      process_path_arg "$a"
    done
  elif [[ -n "$event" ]]; then
    log "IGNORE event=$event (only AlbumDownload / Test / CLI)"
    exit 0
  else
    usage >&2
    exit 2
  fi

  log "DONE ok=$CONVERT_OK skip=$CONVERT_SKIP fail=$CONVERT_FAIL cover_ok=$COVER_OK cover_skip=$COVER_SKIP cover_none=$COVER_NONE"
  if [[ "$CONVERT_FAIL" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
