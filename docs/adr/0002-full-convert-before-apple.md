# ADR 0002 — Full convert, verify before Apple Music

**Context:** Feeding Auto-Add before the mirror is complete makes Sync Library / unmatched AAC hard to debug.

**Decision:** Convert the **full** FLAC master library to the ALAC mirror first; **do not** Auto-Add or Update Cloud Library until convert + verify pass.

**Why:** Separates encode failures from Apple ingest/matching failures; Q4 (ingest batching) deferred until after verify.
