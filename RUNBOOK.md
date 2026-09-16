# Runbook — Lidarr FLAC → ALAC mirror → Apple Music (Windows)

A **runbook** is an operations checklist: what we decided, what we ran, how to repeat it, and known failure modes. Follow this when re-converting, refreshing covers, or onboarding another machine.

Example layout from a Windows + Lidarr campaign (adapt drive letters).  
Reference campaign completed successfully after convert → verify → cover embed → Add Folder.

---

## Locked architecture

| Item | Decision |
| --- | --- |
| Cross-device playback | Apple Music app + **Sync Library ON** (Navidrome/Jellyfin deferred) |
| Masters | Lidarr FLAC (and other lossless) under `M:\` — do **not** mix ALAC into this tree |
| Apple feed tree | Parallel mirror `D:\Music-ALAC\<same relative path>\*.m4a` |
| Convert | Lossless → ALAC only (`ffmpeg -c:a alac`). Never MP3/AAC → ALAC |
| Ingest | Windows Music **File → Add Folder to Library…** on `D:\Music-ALAC` (still manual after Lidarr imports) |
| Continuous import | Lidarr Custom Script `scripts/lidarr-to-alac.sh` / `.ps1` (On Release Import / On Upgrade) writes the same relative path under `ALAC_ROOT` |
| Copy to Media folder | Prefer **OFF** (keep files on `D:\`) |
| Cloud reality | Catalog-matched → often Apple’s file; unmatched uploads → often **AAC 256** in the cloud |

---

## What we completed (changelog)

### Prep / masters (earlier)

- Gundam 10CD APE+CUE → per-track FLAC + `cover.jpg`
- Initial D MILLENNIUM BOX TAK+CUE → per-disc FLAC
- 陳奕迅 `廣東精選`: 17× DSF → FLAC (DSF kept)

### ALAC campaign (2026-09-15)

1. **Convert** `M:\` → `D:\Music-ALAC`  
   - Tool: `ffmpeg -c:a alac`, overlay resume  
   - Temp must be `*.partial.m4a` + `-f mp4` (plain `.m4a.partial` fails muxer)  
   - Result: **2309 / 2309** OK, ~**143.6 GiB** ALAC  
   - Log: `D:\Music-ALAC\_convert_log.txt`
2. **Size reality check**  
   - `M:\` ≈ **168 GiB** total (≈166 GiB lossless). Earlier ~1.2 TB was Lidarr/NAS **planning**, not this `M:\` batch.
3. **Verify**  
   - 2309 present, 0 missing/empty/partials  
   - Sample 40/40: codec `alac`, duration match  
   - Note: ALAC **does** keep 192 kHz (e.g. Coldplay); VLC “48 kHz” line can be wrong — trust **Decoded sample rate** / `ffprobe`
4. **Apple ingest**  
   - Add Folder to Library on `D:\Music-ALAC` + Sync Library / Update Cloud Library  
   - User confirmed library OK (2026-09-16)

### Covers (2026-09-15/16)

- Convert used `-vn` → no embedded art; Apple Music needs **embedded** `covr` (sidecar `folder.jpg` alone is not enough)
- Fix: embed from `M:\` `folder.jpg` / FLAC picture into existing `.m4a` with **audio `-c:a copy`** (no re-convert)
- Windows: temp file must be on **same volume** as target (`D:\…\*.new.m4a` then replace). `os.replace` from `C:\Temp` → `D:\` fails (WinError 17)
- Log: `D:\Music-ALAC\_cover_embed_log.txt`
- After embed: Music **Delete from Library** (keep disk files) → re-Add Folder to refresh art

### Tag / grouping fixes

| Album | Issue | Fix |
| --- | --- | --- |
| No Game No Life complete songs (2017) track 10 | `album_artist=V/A` vs others `Various Artists` (+ compilation) | Set track 10 `album_artist=Various Artists`, `compilation=1` |
| DECO*27 Conti New (2014) track 1 | Tags already consistent; **catalog match** pulled *Streaming Heart* elsewhere | Unify all 12: `album=Conti New (2014)`, `track=n/12`, `disc=1/1` |

---

## Repeatable procedures

### A. Full (or overlay) convert

```text
SRC = M:\
DST = D:\Music-ALAC
ffmpeg … -c:a alac -f mp4  <stem>.partial.m4a
then rename/replace to .m4a
Skip lossy sources. Prefer .flac per stem; else other lossless.
Overlay: skip if DST exists and not older than SRC.
```

Scripts from this campaign (on the doc box): `m_to_alac.py`, `run_m_to_alac.ps1`. Ongoing Lidarr imports: [scripts/lidarr-to-alac.sh](./scripts/lidarr-to-alac.sh) / [scripts/lidarr-to-alac.ps1](./scripts/lidarr-to-alac.ps1).

### B. Embed covers (no re-encode)

Apple Music needs **embedded** `covr` (sidecar `folder.jpg` alone is not enough). For each `.m4a` lacking a video/`attached_pic` stream, pick art in this **exact** order:

1. Embedded picture from the **source lossless** file (FLAC/etc.)
2. Same album folder: `cover.jpg` / `Cover.jpg`
3. Same album folder: `folder.jpg` / `Folder.jpg`
4. Any Lidarr-downloaded art already in the album folder — common names (case-insensitive), **prefer larger** images (pixel area, then bytes): `cover.png`, `folder.png`, `poster.jpg` / `poster.png`, `fanart.jpg`, `banner.jpg`, `disc.png`, `front.jpg`, `back.jpg`, `album.jpg`, `albumart.jpg`, `artwork.jpg`, `scan.jpg`, `logo.png`, `clearlogo.png` (plus `.jpeg` / `.webp` variants). Full list: [scripts/README.md](./scripts/README.md).
5. **Only** if a MusicBrainz **Release** ID is available (tags `MUSICBRAINZ_ALBUMID`, or Lidarr `lidarr_albumrelease_mbid`): fetch Cover Art Archive `/release/<mbid>/front`. Never scrape random web images. Do not use the release-group ID (`lidarr_album_mbid`) as a `/release/` lookup.
6. If still none: **skip embed**, log `COVER_NONE`, treat as non-fatal (convert success → exit 0).

Then:

1. `ffmpeg -i track.m4a -i cover.jpg -map 0:a:0 -map 1:0 -c:a copy -c:v:0 mjpeg -disposition:v:0 attached_pic -f mp4 track.embed.partial.m4a`
2. Replace on **same drive** (temp next to the target)
3. Re-Add in Music if UI still shows blanks

The Lidarr wrapper (`scripts/lidarr-to-alac.sh` / `.ps1`) runs this after each convert.

### C. Apple Music (Windows)

1. Settings → Files: **Copy files to Music Media folder when adding** = OFF (recommended)  
2. File → **Add Folder to Library…** → `D:\Music-ALAC`  
3. File → Library → **Update Cloud Library**  
4. To refresh after tag/cover changes: select those albums → **Delete from Library** (do not delete `D:\` files) → Add Folder again  

**Select All caution:** Library Select All deletes **library entries** (uploads + any Apple Music songs you previously Added to Library). It does **not** delete the Apple Music catalog itself. Prefer selecting only the albums you imported.

### D. Split-album triage

1. `ffprobe` all tracks: compare `album`, `album_artist`, `disc`, `compilation`  
2. If mismatch → unify tags (ffmpeg `-c copy -metadata …`)  
3. If tags match but one track still splits → likely **catalog match**; disambiguate `album` on **all** tracks (e.g. add year) and re-Add

### E. Continuous import (Lidarr Custom Script)

After the one-shot campaign, keep the ALAC mirror in sync as Lidarr imports or upgrades releases.

1. Install `ffmpeg` / `ffprobe` (and on Linux: `bash`, `curl`) where Lidarr runs.
2. Set `MASTER_ROOT` (`/music` or `M:\`) and `ALAC_ROOT` (`/music-alac` or `D:\Music-ALAC`). Never point `ALAC_ROOT` at the FLAC/master tree.
3. Lidarr **Settings → Connect → Custom Script**: path to `scripts/lidarr-to-alac.sh` (Docker/Linux) or `scripts/lidarr-to-alac.ps1` (Windows). Enable **On Release Import** and **On Upgrade**. Test must exit 0.
4. The script converts `lidarr_addedtrackpaths` (prefer `.flac`; skip lossy) to the same relative path under `ALAC_ROOT` as `.m4a`, then embeds cover using the priority in **B**.
5. Log file: `$ALAC_ROOT/_lidarr_to_alac.log` (override with `LOG_FILE`). Missing art logs `COVER_NONE` and does **not** fail the import.
6. **Apple Music is still manual:** File → Add Folder to Library on the ALAC root (or Delete from Library + re-Add for that album). Sync Library does not watch the folder by itself.

Details: [scripts/README.md](./scripts/README.md).

---

## ADRs

See `docs/adr/0001`–`0007` (ALAC on `D:`, full convert before Apple, ffmpeg ALAC, `M:\` overlay, verify before Apple, Add Folder + cover embed, Lidarr On Import wrapper).

---

## Out of scope / non-goals

- Primary path is **not** Navidrome/Jellyfin unless revisited  
- No lossy→ALAC “upgrades”  
- No guarantee of lossless **in the Apple cloud** for unmatched uploads  
- Remaining ~1.2 TB Lidarr/NAS content (if any) is **not** on this `M:\` working set until mounted/synced here
