# ADR 0003 — Batch ALAC via `ffmpeg -c:a alac`

**Context:** Need a one-shot / scripted full-library convert; Lidarr Custom Script hooks are oriented to On Import.

**Decision:** Use `ffmpeg -c:a alac` → `.m4a` for this full-library batch. The same encoder is used by `scripts/m_to_alac.py` for overlay reruns and Lidarr On Import/Upgrade (see ADR 0007).

**Why:** Widely available on Windows; simpler for bulk path mirroring. One Python CLI covers both the campaign batch and continuous import.
