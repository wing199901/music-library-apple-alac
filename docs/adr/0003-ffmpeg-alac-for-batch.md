# ADR 0003 — Batch ALAC via `ffmpeg -c:a alac`

**Context:** Need a one-shot / scripted full-library convert; Lidarr Custom Script (`flac2alac.sh`) is oriented to On Import hooks.

**Decision:** Use `ffmpeg -c:a alac` → `.m4a` for this full-library batch.

**Why:** Widely available on Windows; simpler for bulk path mirroring. Lidarr `flac2alac.sh` can still be considered later for On Import/Upgrade only.
