# Music library → Apple Music (ALAC mirror runbook)

Practical runbook for keeping **lossless masters** (e.g. Lidarr / FLAC) and feeding **Apple Music on Windows** via a parallel **ALAC** tree + Sync Library.

## Start here

- **[RUNBOOK.md](./RUNBOOK.md)** — architecture, changelog of a real campaign, repeatable steps, pitfalls
- **[scripts/README.md](./scripts/README.md)** — one Python CLI: bulk overlay + Lidarr Custom Script
- **[CONTEXT.md](./CONTEXT.md)** — glossary
- **[docs/adr/](./docs/adr/)** — short architecture decision records

## What this is / isn’t

- **Is:** convert lossless → ALAC, embed covers, Add Folder, Sync Library, tag/grouping fixes, Lidarr On Import/Upgrade hook
- **Isn’t:** a guarantee that Apple’s cloud keeps your ALAC (unmatched uploads often become AAC 256); not a Navidrome/Jellyfin primary path

## Script

One entrypoint: **[scripts/m_to_alac.py](./scripts/m_to_alac.py)** (ASCII-safe). Windows: `py`. No `.ps1` wrappers.

```text
# Windows bulk overlay
py scripts\m_to_alac.py

# Lidarr Custom Script (Path must be an existing file)
#   Windows Path:  C:\path\to\scripts\m_to_alac.py
#     or Path py.exe  Arguments: C:\path\to\scripts\m_to_alac.py
#   Docker Path:   /scripts/m_to_alac.py
#     or Path /usr/bin/python3  Arguments: /scripts/m_to_alac.py
# Interactive:     py C:\path\to\scripts\m_to_alac.py
#                  python3 /scripts/m_to_alac.py
```

Env: `MASTER_ROOT`, `ALAC_ROOT`, `LOG_FILE`, `COVER_ART_ARCHIVE`. Details: [scripts/README.md](./scripts/README.md).

## License

Documentation and scripts: use freely; no warranty. Your music files are yours — this repo does not include audio.
