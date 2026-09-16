# -*- coding: utf-8 -*-
"""One-shot: M:\\ -> D:\\Music-ALAC parallel ALAC mirror via ffmpeg -c:a alac. Overlay resume."""
import os
import subprocess
import sys
from pathlib import Path
from datetime import datetime, timezone

SRC_ROOT = None  # set from argv
DST_ROOT = None

SKIP_DIR_NAMES = {
    "System Volume Information",
    "$RECYCLE.BIN",
    "Recycler",
    ".Trash",
    ".Trashes",
    "#recycle",
    "@eaDir",
    ".Spotlight-V100",
    ".fseventsd",
}

FLAC_EXT = {".flac"}
OTHER_LOSSLESS = {".dsf", ".dff", ".tak", ".ape", ".wav", ".wv", ".aiff", ".aif", ".w64", ".tta"}
LOSSY = {".mp3", ".m4a", ".aac", ".ogg", ".opus", ".wma", ".mp4"}
# note: .m4a under SRC could be already alac/aac — treat as non-source for convert input


def log(msg, log_path):
    line = f"{datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} {msg}"
    print(msg, flush=True)
    try:
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def should_skip_dir(name: str) -> bool:
    return name in SKIP_DIR_NAMES or name.startswith(".")


def collect_sources(src_root: Path):
    """Yield (src_path, rel_posix_without_ext) preferring flac per directory stem."""
    # Map: (parent_rel, stem) -> chosen Path
    chosen = {}
    for dirpath, dirnames, filenames in os.walk(src_root):
        # prune
        dirnames[:] = [d for d in dirnames if not should_skip_dir(d)]
        parent = Path(dirpath)
        try:
            rel_parent = parent.relative_to(src_root)
        except ValueError:
            continue
        by_stem = {}
        for fn in filenames:
            p = parent / fn
            ext = p.suffix.lower()
            if ext in LOSSY:
                continue
            if ext not in FLAC_EXT and ext not in OTHER_LOSSLESS:
                continue
            stem = p.stem
            by_stem.setdefault(stem, []).append(p)
        for stem, paths in by_stem.items():
            flacs = [p for p in paths if p.suffix.lower() in FLAC_EXT]
            pick = sorted(flacs)[0] if flacs else sorted(paths)[0]
            key = (str(rel_parent), stem)
            chosen[key] = pick
    return chosen


def needs_convert(src: Path, dst: Path) -> bool:
    if not dst.exists() or dst.stat().st_size == 0:
        return True
    try:
        return src.stat().st_mtime > dst.stat().st_mtime
    except OSError:
        return True


def convert_one(src: Path, dst: Path, log_path: Path) -> str:
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_suffix(".m4a.partial")
    if tmp.exists():
        try:
            tmp.unlink()
        except OSError:
            pass
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(src),
        "-map_metadata", "0",
        "-c:a", "alac",
        str(tmp),
    ]
    # DSD/high-rate: let ffmpeg pick PCM intermediate; alac encoder accepts
    try:
        subprocess.run(cmd, check=True)
        tmp.replace(dst)
        return "OK"
    except Exception as e:
        if tmp.exists():
            try:
                tmp.unlink()
            except OSError:
                pass
        return f"FAIL {e}"


def main():
    global SRC_ROOT, DST_ROOT
    if len(sys.argv) < 3:
        print("usage: script.py <SRC_ROOT> <DST_ROOT>", file=sys.stderr)
        sys.exit(1)
    SRC_ROOT = Path(sys.argv[1])
    DST_ROOT = Path(sys.argv[2])
    if not SRC_ROOT.is_dir():
        print(f"FAIL missing src {SRC_ROOT}", file=sys.stderr)
        sys.exit(1)
    DST_ROOT.mkdir(parents=True, exist_ok=True)
    log_path = DST_ROOT / "_convert_log.txt"
    log(f"START src={SRC_ROOT} dst={DST_ROOT}", log_path)

    chosen = collect_sources(SRC_ROOT)
    log(f"sources={len(chosen)}", log_path)

    ok = skip = fail = 0
    fails = []
    for i, ((rel_parent, stem), src) in enumerate(sorted(chosen.items(), key=lambda x: (x[0][0], x[0][1])), 1):
        rel_dir = Path(rel_parent)
        dst = DST_ROOT / rel_dir / (stem + ".m4a")
        if not needs_convert(src, dst):
            skip += 1
            if i % 200 == 0 or i == 1:
                log(f"[{i}/{len(chosen)}] SKIP {dst.relative_to(DST_ROOT)}", log_path)
            continue
        log(f"[{i}/{len(chosen)}] CONV {src} -> {dst}", log_path)
        result = convert_one(src, dst, log_path)
        if result == "OK":
            ok += 1
        else:
            fail += 1
            fails.append(f"{src} :: {result}")
            log(f"  {result}", log_path)

    log(f"DONE ok={ok} skip={skip} fail={fail} total_sources={len(chosen)}", log_path)
    if fails:
        log("FAILURES:", log_path)
        for f in fails[:50]:
            log(f"  {f}", log_path)
        if len(fails) > 50:
            log(f"  ... +{len(fails)-50} more", log_path)
    print("\n=== SUMMARY ===", flush=True)
    print(f"ok={ok} skip={skip} fail={fail} sources={len(chosen)}", flush=True)
    print(f"log={log_path}", flush=True)
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
