# ADR 0005 — Verify = counts/sizes + sampled ffprobe

**Context:** Must catch bad encodes before Auto-Add / Sync Library.

**Decision:** Pre-Apple verify is (1) file count and total size comparison between source lossless set and ALAC mirror, and (2) sampled ffprobe checks (ALAC codec, duration ≈ source). Manual listening optional, not required for “verify done.”

**Why:** Automatable, scalable to ~1.2TB; separates encode health from Apple matching issues.
