# Music library → Apple Music (ALAC mirror runbook)

Practical runbook for keeping **lossless masters** (e.g. Lidarr / FLAC) and feeding **Apple Music on Windows** via a parallel **ALAC** tree + Sync Library.

## Start here

- **[RUNBOOK.md](./RUNBOOK.md)** — architecture, changelog of a real campaign, repeatable steps, pitfalls
- **[scripts/README.md](./scripts/README.md)** — Lidarr Custom Script wrapper (On Import/Upgrade)
- **[CONTEXT.md](./CONTEXT.md)** — glossary
- **[docs/adr/](./docs/adr/)** — short architecture decision records

## What this is / isn’t

- **Is:** convert lossless → ALAC, embed covers, Add Folder, Sync Library, tag/grouping fixes, Lidarr On Import/Upgrade wrapper
- **Isn’t:** a guarantee that Apple’s cloud keeps your ALAC (unmatched uploads often become AAC 256); not a Navidrome/Jellyfin primary path

## Scripts

- **Lidarr continuous import:** [scripts/README.md](./scripts/README.md) — `lidarr-to-alac.sh` (Docker/Linux) and `lidarr-to-alac.ps1` (Windows)
- One-shot campaign helpers: `m_to_alac.py`, `run_m_to_alac.ps1` (adapt paths before use)

## License

Documentation and scripts: use freely; no warranty. Your music files are yours — this repo does not include audio.
