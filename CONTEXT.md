# Music Library — domain glossary

## Glossary

| Term | Meaning |
| --- | --- |
| **FLAC master root** | `M:\` — Windows root of the source library tree to mirror. |
| **FLAC master** | Preferred lossless source file under the master root (`.flac`). |
| **Other lossless source** | If no `.flac` exists for that stem/path, may use `.dsf` / `.dff` / `.tak` / `.ape` / `.wav` / `.wv` / `.aiff` as convert input (still lossless→ALAC only; never lossy). |
| **ALAC mirror** | Parallel tree of Apple Lossless `.m4a` with the **same relative paths** under the ALAC root as under `M:\`. Never mixed into the FLAC/master tree. |
| **ALAC root** | `D:\Music-ALAC` Mapping (example): `M:\<rel>` → `D:\Music-ALAC\<rel>` (audio → `.m4a`). |
| **Overlay convert** | Skip existing ALAC when present and not older than source; convert missing or stale targets only (resumable). |
| **Sync Library** | Apple Music iCloud Music Library sync (locked ON). |
| **Lidarr (MusicBrainz only)** | Library manager; MusicBrainz metadata only. |
| **Add Folder / Update Cloud Library** | Apple ingest path on Windows (preferred over Auto-Add for this campaign). |
| **Batch converter** | `ffmpeg -c:a alac` → `.m4a` (temp `*.partial.m4a` + `-f mp4`). |
| **Verify (pre-Apple)** | File-count / total-size report (source lossless vs ALAC) plus sampled `ffprobe` (codec=alac, duration ≈ source). |
| **Cover embed** | Write attached_pic into existing `.m4a` (`-c:a copy`); required for Apple Music unmatched art. Priority: source embedded pic → `cover.jpg` → `folder.jpg` → named Lidarr folder art (larger wins) → Cover Art Archive (MusicBrainz Release ID only) → skip. |
| **Lidarr wrapper** | Custom Script on On Release Import / On Upgrade: `scripts/lidarr-to-alac.sh` / `.ps1`. Apple Music Add Folder remains manual. |

## Settled for this campaign

- Full-library convert to ALAC done (2309 tracks, ~143.6 GiB); verify passed; Apple ingest done.
- Prefer Add Folder + Sync Library; Copy to Media folder OFF.
- Covers via embed (not re-convert); same-volume temp files on Windows.
- See [RUNBOOK.md](./RUNBOOK.md) for procedures and changelog.
