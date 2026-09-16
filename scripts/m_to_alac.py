#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Lossless -> parallel ALAC tree + cover embed. One CLI for bulk overlay and Lidarr.

Bulk: walk MASTER_ROOT to ALAC_ROOT (same relative paths). Prefer .flac.
Lidarr: On Release Import / On Upgrade via env or CLI flags.

Windows: py scripts/m_to_alac.py
Docker:  python3 /scripts/m_to_alac.py
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

VERSION = "1.0.0"
CAA_UA = (
    "music-library-apple-alac/%s "
    "(https://github.com/wing199901/music-library-apple-alac)" % VERSION
)
DEFAULT_CAA_URL = "https://coverartarchive.org/release/%s/front"
UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)

SKIP_DIR_NAMES = {
    "system volume information",
    "$recycle.bin",
    "recycler",
    ".trash",
    ".trashes",
    "#recycle",
    "@eadir",
    ".spotlight-v100",
    ".fseventsd",
}

FLAC_EXT = {".flac"}
LOSSLESS_EXT = {
    ".flac",
    ".dsf",
    ".dff",
    ".tak",
    ".ape",
    ".wav",
    ".wv",
    ".aiff",
    ".aif",
    ".w64",
    ".tta",
}
LOSSY_EXT = {".mp3", ".m4a", ".aac", ".ogg", ".opus", ".wma", ".mp4", ".mpc"}

LIDARR_ART_NAMES = {
    "cover.jpg",
    "cover.jpeg",
    "cover.png",
    "cover.webp",
    "cover.bmp",
    "folder.jpg",
    "folder.jpeg",
    "folder.png",
    "folder.webp",
    "folder.bmp",
    "poster.jpg",
    "poster.jpeg",
    "poster.png",
    "poster.webp",
    "fanart.jpg",
    "fanart.jpeg",
    "fanart.png",
    "fanart.webp",
    "banner.jpg",
    "banner.jpeg",
    "banner.png",
    "banner.webp",
    "disc.jpg",
    "disc.jpeg",
    "disc.png",
    "disc.webp",
    "front.jpg",
    "front.jpeg",
    "front.png",
    "front.webp",
    "back.jpg",
    "back.jpeg",
    "back.png",
    "back.webp",
    "album.jpg",
    "album.jpeg",
    "album.png",
    "album.webp",
    "albumart.jpg",
    "albumart.jpeg",
    "albumart.png",
    "albumartsmall.jpg",
    "artwork.jpg",
    "artwork.jpeg",
    "artwork.png",
    "artwork.webp",
    "scan.jpg",
    "scan.jpeg",
    "scan.png",
    "logo.jpg",
    "logo.jpeg",
    "logo.png",
    "clearlogo.png",
    "clearlogo.jpg",
}

# Process config set by main(); None until then so import stays side-effect free.
CFG = None

CONVERT_OK = 0
CONVERT_SKIP = 0
CONVERT_FAIL = 0
OUTSIDE_MASTER = 0
COVER_OK = 0
COVER_SKIP = 0
COVER_NONE = 0
COVER_FAIL = 0


class Config(object):
    def __init__(
        self,
        master_root,
        alac_root,
        log_file,
        ffmpeg,
        ffprobe,
        curl_bin,
        cover_art_archive,
        release_mbid,
        work_dir,
        quiet,
        caa_url,
    ):
        self.master_root = Path(master_root)
        self.alac_root = Path(alac_root)
        self.log_file = Path(log_file) if log_file else None
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.curl_bin = curl_bin
        self.cover_art_archive = cover_art_archive
        self.release_mbid = release_mbid or ""
        self.work_dir = Path(work_dir) if work_dir else None
        self.quiet = quiet
        self.caa_url = caa_url


def default_master_root():
    """Platform default MASTER_ROOT when env/argv are unset."""
    if os.name == "nt":
        return Path("M:\\")
    return Path("/music")


def default_alac_root():
    """Platform default ALAC_ROOT when env/argv are unset."""
    if os.name == "nt":
        return Path("D:\\Music-ALAC")
    return Path("/music-alac")


def env_first(*names):
    for name in names:
        val = os.environ.get(name)
        if val is not None and str(val).strip() != "":
            return val
    return ""


def is_lossy(path):
    return Path(path).suffix.lower() in LOSSY_EXT


def is_lossless(path):
    return Path(path).suffix.lower() in LOSSLESS_EXT


def should_skip_dir(name):
    n = name.lower()
    return n in SKIP_DIR_NAMES or n.startswith(".")


def is_uuid(value):
    return bool(value) and UUID_RE.match(str(value)) is not None


def is_lidarr_art_name(name):
    return name.lower() in LIDARR_ART_NAMES


def parse_added_track_paths(raw):
    if not raw:
        return []
    return [p for p in str(raw).split("|") if p]


def lidarr_event(cli_event):
    if cli_event:
        return cli_event
    return env_first("lidarr_eventtype", "Lidarr_EventType")


def log(msg):
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    line = "%s %s" % (ts, msg)
    quiet = bool(CFG and CFG.quiet)
    if not quiet:
        print(line, file=sys.stderr, flush=True)
    log_path = CFG.log_file if CFG else None
    if log_path:
        try:
            log_path.parent.mkdir(parents=True, exist_ok=True)
            with open(log_path, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        except OSError:
            pass


def die(msg, code=1):
    log("ERROR %s" % msg)
    sys.exit(code)


def ffmpeg_bin():
    if CFG:
        return CFG.ffmpeg
    return env_first("FFMPEG") or "ffmpeg"


def ffprobe_bin():
    if CFG:
        return CFG.ffprobe
    return env_first("FFPROBE") or "ffprobe"


def _resolved(path):
    return Path(path).expanduser().resolve()


def under_root(path, root):
    try:
        _resolved(path).relative_to(_resolved(root))
        return True
    except (ValueError, OSError):
        return False


def dest_for_source(src, master_root, alac_root):
    src = Path(src)
    master = Path(master_root)
    alac = Path(alac_root)
    rel = None
    try:
        rel = _resolved(src).relative_to(_resolved(master))
    except (ValueError, OSError):
        try:
            rel = src.relative_to(master)
        except ValueError:
            return None
    return alac / rel.parent / (src.stem + ".m4a")


def prefer_source(src):
    src = Path(src)
    flac = src.with_suffix(".flac")
    if flac.is_file():
        return flac
    return src


def needs_convert(src, dest):
    dest = Path(dest)
    src = Path(src)
    if not dest.is_file() or dest.stat().st_size == 0:
        return True
    try:
        return src.stat().st_mtime > dest.stat().st_mtime
    except OSError:
        return True


def collect_sources(src_root):
    """Map (parent_rel, stem) -> Path, preferring .flac; never lossy."""
    src_root = Path(src_root)
    chosen = {}
    for dirpath, dirnames, filenames in os.walk(src_root):
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
            if ext in LOSSY_EXT:
                continue
            if ext not in LOSSLESS_EXT:
                continue
            by_stem.setdefault(p.stem, []).append(p)
        for stem, paths in by_stem.items():
            flacs = [p for p in paths if p.suffix.lower() in FLAC_EXT]
            pick = sorted(flacs)[0] if flacs else sorted(paths)[0]
            chosen[(str(rel_parent), stem)] = pick
    return chosen


def has_video_stream(path):
    cmd = [
        ffprobe_bin(),
        "-v",
        "error",
        "-select_streams",
        "v",
        "-show_entries",
        "stream=index",
        "-of",
        "csv=p=0",
        str(path),
    ]
    try:
        out = subprocess.run(
            cmd, check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True
        )
        return bool((out.stdout or "").strip())
    except OSError:
        return False


def image_area(path):
    cmd = [
        ffprobe_bin(),
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=width,height",
        "-of",
        "csv=p=0:s=x",
        str(path),
    ]
    try:
        out = subprocess.run(
            cmd, check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True
        )
        dim = (out.stdout or "").strip()
        if "x" not in dim:
            return 0
        w, h = dim.split("x", 1)
        if w.isdigit() and h.isdigit():
            return int(w) * int(h)
    except OSError:
        return 0
    return 0


def file_size(path):
    try:
        return Path(path).stat().st_size
    except OSError:
        return 0


def pick_larger_image(paths):
    best = None
    best_area = -1
    best_size = -1
    for p in paths:
        p = Path(p)
        if not p.is_file():
            continue
        area = image_area(p)
        sz = file_size(p)
        if area > best_area or (area == best_area and sz > best_size):
            best = p
            best_area = area
            best_size = sz
    return best


def pick_folder_cover(album_dir):
    """Steps 2-4: cover.jpg, folder.jpg, then named Lidarr art (larger wins)."""
    album_dir = Path(album_dir)
    for name in ("cover.jpg", "Cover.jpg"):
        p = album_dir / name
        if p.is_file():
            return "cover.jpg", p
    for name in ("folder.jpg", "Folder.jpg"):
        p = album_dir / name
        if p.is_file():
            return "folder.jpg", p
    cands = []
    try:
        for p in album_dir.iterdir():
            if p.is_file() and is_lidarr_art_name(p.name):
                cands.append(p)
    except OSError:
        pass
    winner = pick_larger_image(cands)
    if winner is not None:
        return "folder-art", winner
    return "none", None


def extract_embedded_pic(src, dest):
    cmd = [
        ffmpeg_bin(),
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        "-y",
        "-i",
        str(src),
        "-an",
        "-map",
        "0:v:0",
        "-frames:v",
        "1",
        "-c:v",
        "mjpeg",
        "-q:v",
        "2",
        "-f",
        "image2",
        str(dest),
    ]
    try:
        r = subprocess.run(cmd, check=False, stdin=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return r.returncode == 0 and Path(dest).is_file() and Path(dest).stat().st_size > 0
    except OSError:
        return False


def read_release_mbid_from_tags(src):
    cmd = [
        ffprobe_bin(),
        "-v",
        "error",
        "-show_entries",
        "format_tags",
        "-of",
        "default=nw=1",
        str(src),
    ]
    try:
        out = subprocess.run(
            cmd, check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True
        )
    except OSError:
        return ""
    for line in (out.stdout or "").splitlines():
        if "=" not in line:
            continue
        key, val = line.split("=", 1)
        if key.startswith("TAG:"):
            key = key[4:]
        key_l = key.strip().lower()
        if key_l in (
            "musicbrainz_albumid",
            "musicbrainz album id",
            "musicbrainz_releaseid",
            "musicbrainz release id",
        ):
            if is_uuid(val.strip()):
                return val.strip()
    return ""


def resolve_release_mbid(src):
    if CFG and is_uuid(CFG.release_mbid):
        return CFG.release_mbid
    env_id = env_first(
        "lidarr_albumrelease_mbid", "Lidarr_AlbumRelease_MBId", "RELEASE_MBID"
    )
    if is_uuid(env_id):
        return env_id
    tag_id = read_release_mbid_from_tags(src)
    if is_uuid(tag_id):
        return tag_id
    return ""


def fetch_cover_art_archive(mbid, dest):
    url_tmpl = (CFG.caa_url if CFG else None) or env_first("CAA_RELEASE_URL") or DEFAULT_CAA_URL
    try:
        url = url_tmpl % mbid
    except (TypeError, ValueError):
        url = url_tmpl.replace("{0}", mbid).replace("%s", mbid)
    dest = Path(dest)
    curl_bin = (CFG.curl_bin if CFG else None) or env_first("CURL_BIN")
    if curl_bin:
        cmd = [
            curl_bin,
            "-fsSL",
            "-A",
            CAA_UA,
            "--max-time",
            "30",
            "-o",
            str(dest),
            url,
        ]
        try:
            r = subprocess.run(cmd, check=False)
            return r.returncode == 0 and dest.is_file() and dest.stat().st_size > 0
        except OSError:
            return False
    req = urllib.request.Request(url, headers={"User-Agent": CAA_UA})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = resp.read()
        if not data:
            return False
        dest.write_bytes(data)
        return dest.is_file() and dest.stat().st_size > 0
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError):
        return False


def find_cover(src):
    """Return (kind, path). kind: embedded, cover.jpg, folder.jpg, folder-art, cover-art-archive, none."""
    src = Path(src)
    album_dir = src.parent
    work = CFG.work_dir if CFG and CFG.work_dir else Path(tempfile.gettempdir())

    if has_video_stream(src):
        pic = work / ("embedded-%s-%s.jpg" % (src.stem, os.getpid()))
        if extract_embedded_pic(src, pic):
            return "embedded", pic

    kind, path = pick_folder_cover(album_dir)
    if kind != "none":
        return kind, path

    enabled = True if CFG is None else CFG.cover_art_archive
    env_caa = env_first("COVER_ART_ARCHIVE")
    if env_caa != "" and CFG is None:
        enabled = env_caa != "0"
    if enabled:
        mbid = resolve_release_mbid(src)
        if is_uuid(mbid):
            caa = work / ("caa-%s.jpg" % mbid)
            if not (caa.is_file() and caa.stat().st_size > 0):
                if not fetch_cover_art_archive(mbid, caa):
                    try:
                        caa.unlink()
                    except OSError:
                        pass
            if caa.is_file() and caa.stat().st_size > 0:
                return "cover-art-archive", caa
            log("COVER_CAA_MISS mbid=%s src=%s" % (mbid, src))
        else:
            log("COVER_CAA_SKIP no MusicBrainz Release ID for %s" % src)

    return "none", None


def assert_dest_safe(dest):
    dest = Path(dest)
    if under_root(dest, CFG.master_root):
        log("REFUSE would write ALAC inside MASTER_ROOT dest=%s master=%s" % (dest, CFG.master_root))
        return False
    if not under_root(dest, CFG.alac_root):
        log("REFUSE dest not under ALAC_ROOT dest=%s alac=%s" % (dest, CFG.alac_root))
        return False
    return True


def convert_one(src, dest):
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    # Same-volume temp; *.partial.m4a + -f mp4 (plain .m4a.partial fails the muxer).
    partial = dest.with_name(dest.stem + ".partial.m4a")
    if partial.exists():
        try:
            partial.unlink()
        except OSError:
            pass
    cmd = [
        ffmpeg_bin(),
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        "-y",
        "-i",
        str(src),
        "-map",
        "0:a:0",
        "-map_metadata",
        "0",
        "-vn",
        "-c:a",
        "alac",
        "-f",
        "mp4",
        str(partial),
    ]
    try:
        subprocess.run(cmd, check=True, stdin=subprocess.DEVNULL)
        if not partial.is_file() or partial.stat().st_size == 0:
            if partial.exists():
                partial.unlink()
            return False
        os.replace(str(partial), str(dest))
        return True
    except (subprocess.CalledProcessError, OSError) as exc:
        log("CONV_FAIL detail=%s" % exc)
        if partial.exists():
            try:
                partial.unlink()
            except OSError:
                pass
        return False


def embed_cover(dest, cover):
    dest = Path(dest)
    tmp = dest.with_name(dest.stem + ".embed.partial.m4a")
    if tmp.exists():
        try:
            tmp.unlink()
        except OSError:
            pass
    cmd = [
        ffmpeg_bin(),
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        "-y",
        "-i",
        str(dest),
        "-i",
        str(cover),
        "-map",
        "0:a:0",
        "-map",
        "1:0",
        "-map_metadata",
        "0",
        "-c:a",
        "copy",
        "-c:v:0",
        "mjpeg",
        "-disposition:v:0",
        "attached_pic",
        "-f",
        "mp4",
        str(tmp),
    ]
    try:
        subprocess.run(cmd, check=True, stdin=subprocess.DEVNULL)
        if not tmp.is_file() or tmp.stat().st_size == 0:
            if tmp.exists():
                tmp.unlink()
            return False
        os.replace(str(tmp), str(dest))
        return True
    except (subprocess.CalledProcessError, OSError):
        if tmp.exists():
            try:
                tmp.unlink()
            except OSError:
                pass
        return False


def process_source(raw):
    global CONVERT_OK, CONVERT_SKIP, CONVERT_FAIL, OUTSIDE_MASTER
    global COVER_OK, COVER_SKIP, COVER_NONE, COVER_FAIL
    raw = Path(raw)
    if not raw.is_file():
        log("SKIP_MISSING %s" % raw)
        return

    src = prefer_source(raw)
    if is_lossy(src):
        log("SKIP_LOSSY %s" % src)
        CONVERT_SKIP += 1
        return
    if not is_lossless(src):
        log("SKIP_NOT_LOSSLESS %s" % src)
        CONVERT_SKIP += 1
        return

    dest = dest_for_source(src, CFG.master_root, CFG.alac_root)
    if dest is None:
        log("SKIP_OUTSIDE_MASTER %s master=%s" % (src, CFG.master_root))
        CONVERT_SKIP += 1
        OUTSIDE_MASTER += 1
        return
    if not assert_dest_safe(dest):
        CONVERT_FAIL += 1
        return

    if needs_convert(src, dest):
        log("CONV %s -> %s" % (src, dest))
        if convert_one(src, dest):
            CONVERT_OK += 1
            log("CONV_OK %s" % dest)
        else:
            CONVERT_FAIL += 1
            log("CONV_FAIL %s" % src)
            return
    else:
        CONVERT_SKIP += 1
        log("SKIP_UPTODATE %s" % dest)

    if has_video_stream(dest):
        log("COVER_SKIP already has video/attached pic: %s" % dest)
        COVER_SKIP += 1
        return

    kind, cover = find_cover(src)
    if kind == "none" or cover is None:
        log("COVER_NONE no art for %s (convert ok; missing art non-fatal)" % dest)
        COVER_NONE += 1
        return

    log("COVER_EMBED kind=%s cover=%s dest=%s" % (kind, cover, dest))
    if embed_cover(dest, cover):
        COVER_OK += 1
        log("COVER_OK kind=%s dest=%s" % (kind, dest))
    else:
        log("COVER_FAIL kind=%s dest=%s (convert kept; embed non-fatal)" % (kind, dest))
        COVER_FAIL += 1


def process_path_arg(path):
    path = Path(path)
    if path.is_dir():
        chosen = collect_sources(path)
        for src in sorted(chosen.values(), key=lambda p: str(p)):
            process_source(src)
    else:
        process_source(path)


def missing_tools():
    missing = []
    for bin_name in (env_first("FFMPEG") or "ffmpeg", env_first("FFPROBE") or "ffprobe"):
        if shutil.which(bin_name) is None and not Path(bin_name).is_file():
            missing.append(bin_name)
    return missing


def require_tools():
    missing = missing_tools()
    if missing:
        die("ffmpeg/ffprobe not found (%s)" % ", ".join(missing))


def init_config(master_root, alac_root, quiet, release_mbid):
    global CFG
    master = Path(master_root)
    alac = Path(alac_root)
    try:
        master_r = master.resolve()
        alac_r = alac.resolve()
    except OSError:
        master_r, alac_r = master, alac
    if master_r == alac_r:
        # Log file may not exist yet; print before CFG is set.
        print("ERROR ALAC_ROOT must not equal MASTER_ROOT (got %s)" % alac, file=sys.stderr)
        sys.exit(1)
    log_file = env_first("LOG_FILE") or str(alac / "_m_to_alac.log")
    work = Path(tempfile.mkdtemp(prefix="m-to-alac."))
    caa_env = env_first("COVER_ART_ARCHIVE")
    caa_on = caa_env != "0"
    CFG = Config(
        master_root=master,
        alac_root=alac,
        log_file=log_file,
        ffmpeg=env_first("FFMPEG") or "ffmpeg",
        ffprobe=env_first("FFPROBE") or "ffprobe",
        curl_bin=env_first("CURL_BIN"),
        cover_art_archive=caa_on,
        release_mbid=release_mbid or "",
        work_dir=work,
        quiet=quiet,
        caa_url=env_first("CAA_RELEASE_URL") or DEFAULT_CAA_URL,
    )
    CFG.alac_root.mkdir(parents=True, exist_ok=True)
    return work


def cleanup_work(work):
    if work and Path(work).is_dir():
        shutil.rmtree(work, ignore_errors=True)


def build_parser():
    p = argparse.ArgumentParser(
        prog="m_to_alac.py",
        description="Lossless to parallel ALAC tree + cover embed (bulk overlay or Lidarr).",
    )
    p.add_argument(
        "--scan",
        action="store_true",
        help="Walk MASTER_ROOT (default when no files and no Lidarr event)",
    )
    p.add_argument("--print-cover", metavar="FILE", help="Print kind<TAB>path for FILE and exit")
    p.add_argument("--master-root", help="Source/master root (env MASTER_ROOT)")
    p.add_argument("--alac-root", help="ALAC dest root (env ALAC_ROOT)")
    p.add_argument("--event", help="Lidarr event type (or env lidarr_eventtype)")
    p.add_argument(
        "--added-tracks",
        help="Pipe-separated paths (or env lidarr_addedtrackpaths)",
    )
    p.add_argument(
        "--release-mbid",
        help="MusicBrainz Release ID (or env lidarr_albumrelease_mbid)",
    )
    p.add_argument(
        "paths",
        nargs="*",
        help="Files/dirs to convert, or SRC_ROOT DST_ROOT for bulk overlay",
    )
    return p


def looks_like_audio(path):
    return is_lossy(path) or is_lossless(path)


def main(argv=None):
    global CONVERT_OK, CONVERT_SKIP, CONVERT_FAIL, OUTSIDE_MASTER
    global COVER_OK, COVER_SKIP, COVER_NONE, COVER_FAIL
    CONVERT_OK = CONVERT_SKIP = CONVERT_FAIL = OUTSIDE_MASTER = 0
    COVER_OK = COVER_SKIP = COVER_NONE = COVER_FAIL = 0

    args = build_parser().parse_args(argv)
    event = lidarr_event(args.event)

    if event == "Test":
        # stdout only. Lidarr records stderr as Error.
        missing = missing_tools()
        if missing:
            print("m_to_alac: Test FAIL missing %s" % ", ".join(missing))
            return 1
        print("m_to_alac: Test OK")
        return 0

    require_tools()

    master = args.master_root or env_first("MASTER_ROOT") or str(default_master_root())
    alac = args.alac_root or env_first("ALAC_ROOT") or str(default_alac_root())
    paths = list(args.paths)
    do_scan = bool(args.scan)

    if (
        not do_scan
        and not args.print_cover
        and not event
        and len(paths) == 2
        and not looks_like_audio(paths[0])
        and not looks_like_audio(paths[1])
    ):
        master, alac = paths[0], paths[1]
        paths = []
        do_scan = True

    quiet = event == "AlbumDownload"
    work = None
    try:
        work = init_config(master, alac, quiet, args.release_mbid)
        log(
            "START version=%s master=%s alac=%s event=%s"
            % (VERSION, CFG.master_root, CFG.alac_root, event or "cli")
        )

        if args.print_cover:
            kind, path = find_cover(args.print_cover)
            line = "%s\t%s" % (kind, path if path is not None else "")
            print(line)
            log("PRINT_COVER %s -> %s" % (args.print_cover, line))
            return 0

        if event == "AlbumDownload":
            added = args.added_tracks or env_first(
                "lidarr_addedtrackpaths", "Lidarr_AddedTrackPaths"
            )
            if not added:
                log("AlbumDownload with empty lidarr_addedtrackpaths; nothing to do")
                return 0
            for p in parse_added_track_paths(added):
                process_source(p)
        elif do_scan or (not paths and not event):
            if not CFG.master_root.is_dir():
                die("MASTER_ROOT not a directory: %s" % CFG.master_root)
            chosen = collect_sources(CFG.master_root)
            for src in sorted(chosen.values(), key=lambda p: str(p)):
                process_source(src)
        elif paths:
            for a in paths:
                process_path_arg(a)
        elif event:
            log("IGNORE event=%s (only AlbumDownload / Test / CLI)" % event)
            return 0
        else:
            build_parser().print_usage(sys.stderr)
            return 2

        log(
            "DONE ok=%s skip=%s fail=%s outside=%s cover_ok=%s cover_skip=%s cover_none=%s cover_fail=%s"
            % (
                CONVERT_OK,
                CONVERT_SKIP,
                CONVERT_FAIL,
                OUTSIDE_MASTER,
                COVER_OK,
                COVER_SKIP,
                COVER_NONE,
                COVER_FAIL,
            )
        )
        if event == "AlbumDownload" and CONVERT_OK == 0 and CONVERT_FAIL == 0 and OUTSIDE_MASTER > 0:
            err = (
                "ERROR no tracks under MASTER_ROOT "
                "(set MASTER_ROOT / --master-root to Lidarr library root)"
            )
            log(err)
            print(err, file=sys.stderr, flush=True)
            return 1
        if CONVERT_FAIL:
            return 1
        return 0
    finally:
        cleanup_work(work)


if __name__ == "__main__":
    sys.exit(main())
