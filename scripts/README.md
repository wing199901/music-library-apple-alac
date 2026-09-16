# Lidarr → ALAC wrapper

Custom-script wrapper for **On Release Import / On Upgrade**. Converts lossless masters into a **parallel ALAC tree** (same relative path) and embeds album art using a fixed priority. Masters stay put: the script never writes `.m4a` into `MASTER_ROOT` and never deletes sources.

Apple Music ingest stays **manual / semi-auto**: after new ALAC files appear, use File → **Add Folder to Library…** on the ALAC root (or Delete-from-Library + re-Add for cover/tag refreshes). This wrapper does not talk to Apple Music.

Not a fork of TheCaptain989/lidarr-flac2mp3.

## Wire up in Lidarr

1. Put `ffmpeg` + `ffprobe` on the PATH of the user/container that runs Lidarr. Docker/Linux also needs `bash` and `curl` (Cover Art Archive). Example extra packages: `ffmpeg`, `bash`, `curl`.
2. Mount both trees into the Lidarr container (or use Windows native paths):

   | Env | Linux/Docker default | Windows example |
   | --- | --- | --- |
   | `MASTER_ROOT` | `/music` | `M:\` |
   | `ALAC_ROOT` | `/music-alac` | `D:\Music-ALAC` |

3. **Settings → Connect → + → Custom Script**
   - Name: `lidarr-to-alac`
   - Path: `/scripts/lidarr-to-alac.sh` (Linux/Docker) or `C:\path\to\lidarr-to-alac.ps1` (Windows)
   - Enable **On Release Import** and **On Upgrade** only
   - **Test** must exit 0 (the scripts print `lidarr-to-alac: Test OK`)
4. Optional env on the Lidarr process: `LOG_FILE` (default `$ALAC_ROOT/_lidarr_to_alac.log`), `COVER_ART_ARCHIVE=0` to disable network art.

On Import/Upgrade Lidarr sets `lidarr_eventtype=AlbumDownload` and `lidarr_addedtrackpaths` (pipe-separated). MusicBrainz **Release** ID is `lidarr_albumrelease_mbid` (not `lidarr_album_mbid`, which is the release group).

## CLI (batch test)

```bash
# Linux/Docker
export MASTER_ROOT=/music ALAC_ROOT=/music-alac
./scripts/lidarr-to-alac.sh --scan
./scripts/lidarr-to-alac.sh "/music/Artist/Album/track.flac"
./scripts/test-lidarr-to-alac.sh   # synthetic sine/color fixtures; needs ffmpeg
```

```powershell
# Windows
$env:MASTER_ROOT = 'M:\'
$env:ALAC_ROOT = 'D:\Music-ALAC'
.\scripts\lidarr-to-alac.ps1 -Scan
.\scripts\lidarr-to-alac.ps1 'M:\Artist\Album\track.flac'
```

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
6. If still none: skip embed, log clearly, treat as non-fatal.

Skip embed when the `.m4a` already has a video / attached-pic stream. Embed uses audio `-c:a copy` + `mjpeg` `attached_pic`.

## Apple Music

New or changed `.m4a` files are not picked up by Sync Library until you **Add Folder** (or re-Add after Delete from Library, keeping files on disk). See [RUNBOOK.md](../RUNBOOK.md).
