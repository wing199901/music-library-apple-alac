# Apple Music playlist restore — runbook

Operations checklist for putting **catalog tracks** back onto Apple Music playlists from local jsonl exports. Separate from the Windows ALAC ingest path in [RUNBOOK.md](../RUNBOOK.md).

## Goal

Restore Apple Music playlists from local jsonl exports under `/Users/wing199901/Music/playlist-restore/jsonl/`.

- One playlist at a time, **most-missing first**.
- Prefer the **shared catalog** (Add to Library / Add to Playlist).
- Do **not** mass-delete extras already on a playlist.
- Skip **Pop** / **City Pop** unless asked.

## Paths

| Item | Value |
| --- | --- |
| Work dir | `/Users/wing199901/Music/playlist-restore/` |
| jsonl exports | `/Users/wing199901/Music/playlist-restore/jsonl/` |
| Dated audit JSON | `playlist-restore/` |
| Mac | Stevens-MacBook-Pro |
| Sync Library | **ON** |

## Music.app UI (critical — corrected 2026-10-14)

Use the control next to the **track**, not the window chrome.

1. Always use the **song-row** ⋯「更多」button next to each track (search results or album track list).
2. That menu includes **加至資料庫** (Add to Library) and **加至播放清單** (Add to Playlist).
3. Do **not** use the **toolbar** ⋯「更多」 — different control; often no Add actions.
4. Do **not** use **檔案 → 加入資料庫⋯** — opens a local file picker, not catalog add.
5. Every catalog track has Add. If those items are missing, the wrong ⋯ was used. The earlier conclusion “HK account cannot add JP-only” was a **wrong-control** mistake, not a hard region lock.

## HK search naming

The HK storefront often lists titles in **romanization**. Match the jsonl English `name`.

- Prefer the romanized / jsonl `name` first.
- Use JP kanji or kana only as a fallback.
- Example: search `Mabutano Ura`, not `目蓋の裏`. Kanji can return **0 hits**.

## Matching rules

| Case | Rule |
| --- | --- |
| **Live** | jsonl Live → add that Live release. Refuse a studio substitute. Studio and Live may coexist when jsonl has both rows. |
| **OG vs cover** | jsonl original → refuse cover, remix, TV-size, karaoke, orgel, and the wrong artist. OG and cover coexist only when jsonl has a separate row for each. |
| Standing skip | Cantonese「情人」. |

## Reliable fill path

1. Playlist-scoped audit vs jsonl (matched / expected).
2. Music.app search: romanized title + artist.
3. Song-row ⋯ → **加至資料庫** (Add to Library) if needed → **加至播放清單** (Add to Playlist). Once the track is in the library, AppleScript may duplicate it into the playlist by persistent ID.
4. Re-audit. Log anything still sticky, with a reason.
5. Write dated JSON under `playlist-restore/`.

## Why restores took long

- Many playlists.
- The Mac went offline mid-run.
- Music **1.7** UI change: the toolbar ⋯ was used for a while (wrong control).
- Sticky titles need romanized search and the song-row menu.

## Snapshot 2026-10-14

| Playlist | jsonl OGs |
| --- | --- |
| モブサイコ100 | **8/8** |
| JoJo | **23/23** |

Covers, piano, and orgel versions may still sit on the playlist. They are **not** counted as OG.
