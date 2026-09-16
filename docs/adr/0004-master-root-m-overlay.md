# ADR 0004 — Master root `M:\`, overlay convert, FLAC-first

**Context:** Need a single mapping into `D:\Music-ALAC` and a resumable full-library job.

**Decision:** Treat `M:\` as the FLAC master root. Mirror to `D:\Music-ALAC\<same relative path>`. Prefer `.flac`; if absent, allow other lossless extensions. Overlay policy: convert only missing or stale ALAC (source newer than target).

**Why:** Matches a typical Windows library layout; overlay avoids re-encoding terabytes on reruns; FLAC-first keeps Lidarr masters primary without stranding TAK/DSF-only folders.
