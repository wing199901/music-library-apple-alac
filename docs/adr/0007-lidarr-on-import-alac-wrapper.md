# ADR 0007 — One Python CLI for bulk overlay and Lidarr On Import/Upgrade

**Context:** ADR 0003 used a one-shot `ffmpeg` batch for the first library. New Lidarr imports need the same parallel ALAC tree and Apple-visible embedded art without mixing ALAC into the FLAC/master root. Dual Python files and PowerShell wrappers were encoding/launcher workarounds, not extra features.

**Decision:** Ship a single ASCII-safe `scripts/m_to_alac.py`. Windows runs it with `py` (or `python`); Docker/Linux with `python3`. It does bulk overlay (`MASTER_ROOT` → `ALAC_ROOT`, same relative path) and Lidarr Connect Custom Script (On Release Import / On Upgrade) via env (`lidarr_eventtype`, `lidarr_addedtrackpaths`, `lidarr_albumrelease_mbid`) or CLI flags. Cover embed follows a fixed six-step priority (embedded pic → `cover.jpg` → `folder.jpg` → named Lidarr folder art by size → Cover Art Archive with a MusicBrainz Release ID only → skip). Do not fork TheCaptain989/lidarr-flac2mp3. Do not ship `.ps1` / `.sh` converters. Apple Music Add Folder remains manual.

**Why:** One file is what operators actually run; `py` already selects Python on Windows. Custom Script env is enough to convert only new files; CAA-only (no random scrape) keeps art sourcing legitimate; same-volume `*.partial.m4a` + `-f mp4` matches the campaign muxer/Windows replace constraints.
