# ADR 0006 — Add Folder ingest + cover embed (no re-convert)

**Context:** After ALAC convert+verify, need Apple Music on Windows and album art.

**Decision:** Ingest with File → Add Folder to Library on `D:\Music-ALAC` (Copy to Media OFF). Fix missing art by embedding into existing `.m4a` (`-c:a copy`), not re-encoding audio. Use same-folder temp files on Windows.

**Why:** Add Folder is simpler than Auto-Add for a full tree; Apple ignores loose `folder.jpg` for unmatched uploads; re-convert is unnecessary when only art/tags are wrong.
