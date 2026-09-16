#!/usr/bin/env bash
# Synthetic-audio tests for lidarr-to-alac.sh (no copyrighted music).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/lidarr-to-alac.sh"
PASS=0
FAIL=0

if [[ ! -x "$SCRIPT" ]]; then
  chmod +x "$SCRIPT"
fi

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing $1"; exit 1; }
}
need ffmpeg
need ffprobe

WORKDIR="$(mktemp -d /tmp/lidarr-to-alac-test.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

MASTER="$WORKDIR/music"
ALAC="$WORKDIR/music-alac"
LOG="$WORKDIR/test.log"
mkdir -p "$MASTER" "$ALAC"

run() {
  MASTER_ROOT="$MASTER" ALAC_ROOT="$ALAC" LOG_FILE="$LOG" COVER_ART_ARCHIVE=0 \
    "$SCRIPT" "$@"
}

assert() {
  local name="$1"
  shift
  if "$@"; then
    PASS=$((PASS + 1))
    echo "PASS $name"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL $name"
  fi
}

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    echo "PASS $name"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL $name got=$(printf %q "$got") want=$(printf %q "$want")"
  fi
}

assert_contains() {
  local name="$1" hay="$2" needle="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "PASS $name"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL $name missing $(printf %q "$needle") in $(printf %q "$hay")"
  fi
}

codec_of() {
  ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$1"
}

vdim_of() {
  ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$1" 2>/dev/null || true
}

make_wav() {
  local out="$1"
  mkdir -p "$(dirname "$out")"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i sine=frequency=440:duration=0.25 -c:a pcm_s16le "$out"
}

make_flac() {
  local out="$1"
  mkdir -p "$(dirname "$out")"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i sine=frequency=440:duration=0.25 -c:a flac "$out"
}

make_flac_tagged() {
  local out="$1" mbid="$2"
  mkdir -p "$(dirname "$out")"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i sine=frequency=440:duration=0.25 \
    -c:a flac -metadata MUSICBRAINZ_ALBUMID="$mbid" "$out"
}

make_flac_with_pic() {
  local out="$1" w="$2" h="$3" color="$4"
  mkdir -p "$(dirname "$out")"
  local pic="$WORKDIR/pic-${color}-${w}x${h}.jpg" audio="$WORKDIR/audio-tmp.flac"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=${color}:s=${w}x${h}" -frames:v 1 "$pic"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i sine=frequency=440:duration=0.25 -c:a flac "$audio"
  ffmpeg -hide_banner -loglevel error -y -i "$audio" -i "$pic" \
    -map 0:a -map 1:v -c:a copy -c:v mjpeg -disposition:v attached_pic "$out"
}

make_jpg() {
  local out="$1" w="$2" h="$3" color="$4"
  mkdir -p "$(dirname "$out")"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=${color}:s=${w}x${h}" -frames:v 1 "$out"
}

make_png() {
  local out="$1" w="$2" h="$3" color="$4"
  mkdir -p "$(dirname "$out")"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=${color}:s=${w}x${h}" -frames:v 1 "$out"
}

print_kind() {
  local file="$1"
  MASTER_ROOT="$MASTER" ALAC_ROOT="$ALAC" LOG_FILE="$LOG" COVER_ART_ARCHIVE=0 \
    "$SCRIPT" --print-cover "$file" | awk -F '\t' '{print $1}'
}

echo "== Test event =="
set +e
lidarr_eventtype=Test "$SCRIPT"
te=$?
set -e
assert_eq "test-event-exit0" "$te" "0"

echo "== Convert FLAC to ALAC, keep master, relative path =="
album="$MASTER/Artist/Album One"
make_flac "$album/01 Track.flac"
run "$album/01 Track.flac"
dst="$ALAC/Artist/Album One/01 Track.m4a"
assert "dest-exists" test -f "$dst"
assert_eq "codec-alac" "$(codec_of "$dst")" "alac"
assert "master-untouched-no-m4a" test ! -f "$album/01 Track.m4a"
assert "master-flac-kept" test -f "$album/01 Track.flac"
assert "no-partial-left" test ! -f "$ALAC/Artist/Album One/01 Track.partial.m4a"

echo "== Never lossy → ALAC =="
make_wav "$MASTER/Artist/Lossy/x.wav"
ffmpeg -hide_banner -loglevel error -y -i "$MASTER/Artist/Lossy/x.wav" -c:a aac "$MASTER/Artist/Lossy/x.m4a"
run "$MASTER/Artist/Lossy/x.m4a"
assert "lossy-not-converted" test ! -f "$ALAC/Artist/Lossy/x.m4a"

echo "== Prefer .flac over .wav same stem =="
make_wav "$MASTER/Artist/Prefer/track.wav"
make_flac "$MASTER/Artist/Prefer/track.flac"
run --scan
assert "prefer-flac-dest" test -f "$ALAC/Artist/Prefer/track.m4a"
assert_eq "prefer-flac-codec" "$(codec_of "$ALAC/Artist/Prefer/track.m4a")" "alac"

echo "== Cover priority 1: embedded beats cover.jpg =="
p1="$MASTER/Artist/P1"
make_flac_with_pic "$p1/song.flac" 80 60 red
make_jpg "$p1/cover.jpg" 40 40 blue
assert_eq "p1-kind" "$(print_kind "$p1/song.flac")" "embedded"
run "$p1/song.flac"
assert_eq "p1-embedded-dim" "$(vdim_of "$ALAC/Artist/P1/song.m4a")" "80x60"

echo "== Cover priority 2: cover.jpg before folder.jpg =="
p2="$MASTER/Artist/P2"
make_flac "$p2/song.flac"
make_jpg "$p2/cover.jpg" 32 32 green
make_jpg "$p2/folder.jpg" 200 200 blue
assert_eq "p2-kind" "$(print_kind "$p2/song.flac")" "cover.jpg"
run "$p2/song.flac"
assert_eq "p2-cover-dim" "$(vdim_of "$ALAC/Artist/P2/song.m4a")" "32x32"

echo "== Cover priority 3: folder.jpg / Folder.jpg =="
p3="$MASTER/Artist/P3"
make_flac "$p3/song.flac"
make_jpg "$p3/folder.jpg" 48 48 yellow
make_png "$p3/poster.png" 300 300 red
assert_eq "p3-kind" "$(print_kind "$p3/song.flac")" "folder.jpg"
run "$p3/song.flac"
assert_eq "p3-folder-dim" "$(vdim_of "$ALAC/Artist/P3/song.m4a")" "48x48"

echo "== Cover.jpg exact name (Cover.jpg) =="
p3b="$MASTER/Artist/P3b"
make_flac "$p3b/song.flac"
make_jpg "$p3b/Cover.jpg" 36 36 cyan
assert_eq "p3b-kind" "$(print_kind "$p3b/song.flac")" "cover.jpg"

echo "== Cover priority 4: named Lidarr art, prefer larger =="
p4="$MASTER/Artist/P4"
make_flac "$p4/song.flac"
make_png "$p4/cover.png" 20 20 red
make_jpg "$p4/poster.jpg" 120 90 blue
assert_eq "p4-kind" "$(print_kind "$p4/song.flac")" "folder-art"
run "$p4/song.flac"
assert_eq "p4-larger-dim" "$(vdim_of "$ALAC/Artist/P4/song.m4a")" "120x90"

echo "== Cover priority 6: missing art is non-fatal, convert succeeds =="
p6="$MASTER/Artist/P6"
make_flac "$p6/song.flac"
set +e
run "$p6/song.flac"
p6e=$?
set -e
assert_eq "p6-exit0" "$p6e" "0"
assert "p6-converted" test -f "$ALAC/Artist/P6/song.m4a"
assert_eq "p6-kind" "$(print_kind "$p6/song.flac")" "none"
assert_contains "p6-log-none" "$(cat "$LOG")" "COVER_NONE"

echo "== Skip embed if m4a already has a video stream =="
p7="$MASTER/Artist/P7"
make_flac "$p7/song.flac"
make_jpg "$p7/cover.jpg" 64 64 red
run "$p7/song.flac"
before="$(vdim_of "$ALAC/Artist/P7/song.m4a")"
make_jpg "$p7/cover.jpg" 200 200 blue
run "$p7/song.flac"
after="$(vdim_of "$ALAC/Artist/P7/song.m4a")"
assert_eq "p7-skip-reembed-dim" "$after" "$before"
assert_contains "p7-log-skip" "$(cat "$LOG")" "COVER_SKIP already has video"

echo "== Lidarr AlbumDownload env (pipe-separated) =="
p8="$MASTER/Artist/P8"
make_flac "$p8/a.flac"
make_flac "$p8/b.flac"
MASTER_ROOT="$MASTER" ALAC_ROOT="$ALAC" LOG_FILE="$LOG" COVER_ART_ARCHIVE=0 \
  lidarr_eventtype=AlbumDownload \
  lidarr_addedtrackpaths="$p8/a.flac|$p8/b.flac" \
  "$SCRIPT"
assert "p8-a" test -f "$ALAC/Artist/P8/a.m4a"
assert "p8-b" test -f "$ALAC/Artist/P8/b.m4a"

echo "== Cover Art Archive only with Release ID; mock curl =="
fakebin="$WORKDIR/fakebin"
mkdir -p "$fakebin"
caa_img="$WORKDIR/caa.jpg"
make_jpg "$caa_img" 77 55 orange
cat >"$fakebin/curl" <<EOF
#!/bin/sh
out=""
url=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -A|--max-time|-fsSL) shift ;;
    --max-time) shift 2 ;;
    http*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
echo "\$url" > "$WORKDIR/caa-url.txt"
cp "$caa_img" "\$out"
EOF
chmod +x "$fakebin/curl"
p5="$MASTER/Artist/P5"
mbid="12345678-1234-1234-1234-1234567890ab"
make_flac_tagged "$p5/song.flac" "$mbid"
PATH="$fakebin:$PATH" MASTER_ROOT="$MASTER" ALAC_ROOT="$ALAC" LOG_FILE="$LOG" \
  COVER_ART_ARCHIVE=1 CURL_BIN="$fakebin/curl" \
  "$SCRIPT" --print-cover "$p5/song.flac" >"$WORKDIR/p5.out"
assert_eq "p5-kind" "$(awk -F '\t' '{print $1}' "$WORKDIR/p5.out")" "cover-art-archive"
assert_contains "p5-url-release" "$(cat "$WORKDIR/caa-url.txt")" "/release/${mbid}/front"

echo "== CAA skipped without MusicBrainz Release ID (no scrape) =="
p5b="$MASTER/Artist/P5b"
make_flac "$p5b/song.flac"
PATH="$fakebin:$PATH" MASTER_ROOT="$MASTER" ALAC_ROOT="$ALAC" LOG_FILE="$LOG" \
  COVER_ART_ARCHIVE=1 CURL_BIN="$fakebin/curl" \
  "$SCRIPT" --print-cover "$p5b/song.flac" >"$WORKDIR/p5b.out"
assert_eq "p5b-kind-none" "$(awk -F '\t' '{print $1}' "$WORKDIR/p5b.out")" "none"

echo "== Refuse ALAC into master root =="
set +e
MASTER_ROOT="$MASTER" ALAC_ROOT="$MASTER" LOG_FILE="$LOG" COVER_ART_ARCHIVE=0 \
  "$SCRIPT" "$album/01 Track.flac"
refuse=$?
set -e
assert "refuse-same-root-nonzero" test "$refuse" -ne 0

echo
echo "=== RESULT pass=$PASS fail=$FAIL ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
