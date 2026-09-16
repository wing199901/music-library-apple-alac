# ADR 0007 — Lidarr On Import/Upgrade ALAC wrapper + cover priority

**Context:** ADR 0003 used a one-shot `ffmpeg` batch for the first library. New Lidarr imports need the same parallel ALAC tree and Apple-visible embedded art without mixing ALAC into the FLAC/master root.

**Decision:** Ship original `scripts/lidarr-to-alac.sh` (Docker/Linux primary) and `scripts/lidarr-to-alac.ps1` (Windows) as Lidarr Connect Custom Scripts for On Release Import / On Upgrade. Map `MASTER_ROOT` → `ALAC_ROOT` with the same relative path. Cover embed follows a fixed six-step priority (embedded pic → `cover.jpg` → `folder.jpg` → named Lidarr folder art by size → Cover Art Archive with a MusicBrainz Release ID only → skip). Do not fork TheCaptain989/lidarr-flac2mp3. Apple Music Add Folder remains manual.

**Why:** Custom Script env (`lidarr_addedtrackpaths`, `lidarr_albumrelease_mbid`) is enough to convert only new files; CAA-only (no random scrape) keeps art sourcing legitimate; same-volume `*.partial.m4a` + `-f mp4` matches the campaign muxer/Windows replace constraints.
