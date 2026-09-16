# ADR 0001 — ALAC root on `D:\Music-ALAC`

**Context:** Dual FLAC+ALAC needs ~+1.2TB+; NAS has no free space for the mirror.

**Decision:** Put the ALAC mirror root at `D:\Music-ALAC` on a local data drive (example `D:\Music-ALAC`), not on a full NAS when space is limited.

**Why:** Capacity constraint on NAS; keeps parallel tree off the FLAC volume if FLAC lives elsewhere (e.g. M: / Lidarr paths).
