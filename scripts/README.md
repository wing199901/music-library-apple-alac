# m_to_alac.py — one CLI for bulk overlay and Lidarr

Single ASCII-safe Python entrypoint. Converts lossless masters into a **parallel ALAC tree** (same relative path) and embeds album art using a fixed priority. Masters stay put: the script never writes `.m4a` into `MASTER_ROOT` and never deletes sources.

Windows uses **`py`**. There is no `.ps1` wrapper and no second “ascii” Python file.

Apple Music ingest stays **manual / semi-auto**: after new ALAC files appear, use File → **Add Folder to Library…** on the ALAC root (or Delete-from-Library + re-Add for cover/tag refreshes). This script does not talk to Apple Music.

Not a fork of TheCaptain989/lidarr-flac2mp3.

## Run it

```text
# Windows bulk overlay (defaults MASTER_ROOT=M:\  ALAC_ROOT=D:\Music-ALAC)
py scripts\m_to_alac.py
py scripts\m_to_alac.py M:\ D:\Music-ALAC

# Linux/Docker bulk overlay (defaults /music → /music-alac)
python3 scripts/m_to_alac.py
python3 scripts/m_to_alac.py --scan

# One album / files (still mapped under MASTER_ROOT)
py scripts\m_to_alac.py M:\Artist\Album\track.flac
```

Need `ffmpeg` and `ffprobe` on PATH (`FFMPEG` / `FFPROBE` override).

## Lidarr Custom Script Path

**Settings → Connect → + → Custom Script**

| | |
| --- | --- |
| Name | `m_to_alac` |
| **Windows Path** | `py C:\path\to\music-library-apple-alac\scripts\m_to_alac.py` (or `python C:\path\to\…\scripts\m_to_alac.py`) |
| **Docker Path** | `python3 /scripts/m_to_alac.py` (mount this repo’s `scripts/` at `/scripts`, and both music trees) |
| On | **On Release Import** and **On Upgrade** only |
| Test | must exit 0 (`m_to_alac: Test OK` on stdout) |

On Import/Upgrade Lidarr sets `lidarr_eventtype=AlbumDownload` and `lidarr_addedtrackpaths` (pipe-separated). MusicBrainz **Release** ID is `lidarr_albumrelease_mbid` (not `lidarr_album_mbid`, which is the release group).

Equivalent CLI flags: `--event AlbumDownload --added-tracks "a.flac|b.flac" --release-mbid <uuid>`.

## Environment

| Env | Linux/Docker default | Windows default |
| --- | --- | --- |
| `MASTER_ROOT` | `/music` | `M:\` |
| `ALAC_ROOT` | `/music-alac` | `D:\Music-ALAC` |
| `LOG_FILE` | `$ALAC_ROOT/_m_to_alac.log` | `%ALAC_ROOT%\_m_to_alac.log` |
| `COVER_ART_ARCHIVE` | `1` (set `0` to disable network art) | same |

Optional: `FFMPEG`, `FFPROBE`, `CURL_BIN` (Cover Art Archive; otherwise Python `urllib`), `CAA_RELEASE_URL`.

Never point `ALAC_ROOT` at the FLAC/master tree.

## Convert behavior

- Prefer `.flac`; other lossless (`.wav`, `.dsf`, `.ape`, …) only if needed
- Never lossy → ALAC
- `ffmpeg -c:a alac -f mp4` → `*.partial.m4a` on the **same volume** as the destination, then replace `*.m4a`
- Overlay: skip encode when the `.m4a` exists and is not older than the source
- Convert failure → exit 1; missing art → log `COVER_NONE` and still exit 0

## Cover embed priority

1. Embedded picture from the source lossless file (FLAC/etc.)
2. Same album folder: `cover.jpg` / `Cover.jpg`
3. Same album folder: `folder.jpg` / `Folder.jpg`
4. Other Lidarr-downloaded art already in the album folder; **prefer the larger image** (pixel area, then file size). Name list (case-insensitive):

   `cover.png` `cover.jpeg` `cover.webp` `cover.bmp`  
   `folder.png` `folder.jpeg` `folder.webp` `folder.bmp`  
   `poster.jpg` `poster.jpeg` `poster.png` `poster.webp`  
   `fanart.jpg` `fanart.jpeg` `fanart.png` `fanart.webp`  
   `banner.jpg` `banner.jpeg` `banner.png` `banner.webp`  
   `disc.jpg` `disc.jpeg` `disc.png` `disc.webp`  
   `front.jpg` `front.jpeg` `front.png` `front.webp`  
   `back.jpg` `back.jpeg` `back.png` `back.webp`  
   `album.jpg` `album.jpeg` `album.png` `album.webp`  
   `albumart.jpg` `albumart.jpeg` `albumart.png` `albumartsmall.jpg`  
   `artwork.jpg` `artwork.jpeg` `artwork.png` `artwork.webp`  
   `scan.jpg` `scan.jpeg` `scan.png`  
   `logo.jpg` `logo.jpeg` `logo.png` `clearlogo.png` `clearlogo.jpg`  
   plus `cover.jpg` / `folder.jpg` as a case-insensitive fallback (e.g. `COVER.JPG`) if steps 2–3 missed them

5. Only if a MusicBrainz **Release** ID is available (Lidarr `lidarr_albumrelease_mbid`, or tags such as `MUSICBRAINZ_ALBUMID`): fetch `https://coverartarchive.org/release/<mbid>/front`. Never scrape random web images. Never use the release-group ID as a CAA `/release/` lookup.
6. If still none: skip embed, log `COVER_NONE`, treat as non-fatal.

Skip embed when the `.m4a` already has a video / attached-pic stream. Embed uses audio `-c:a copy` + `mjpeg` `attached_pic`.

## Tests (no copyrighted music)

Synthetic sine/color fixtures via ffmpeg:

```bash
python3 scripts/test_m_to_alac.py          # path/cover rules; no ffmpeg
bash scripts/test-m-to-alac.sh             # convert + cover; needs ffmpeg
```

## Apple Music

New or changed `.m4a` files are not picked up by Sync Library until you **Add Folder** (or re-Add after Delete from Library, keeping files on disk). See [RUNBOOK.md](../RUNBOOK.md).
