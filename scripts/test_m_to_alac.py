#!/usr/bin/env python3
# ASCII-only unit tests for m_to_alac.py (no audio fixtures required).
"""unittest coverage for path mapping, overlay skip, and cover-name rules."""
from __future__ import annotations

import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import m_to_alac as m  # noqa: E402


class DefaultRootsTests(unittest.TestCase):
    def test_linux_defaults(self):
        with mock.patch.object(m.os, "name", "posix"):
            self.assertEqual(m.default_master_root(), Path("/music"))
            self.assertEqual(m.default_alac_root(), Path("/music-alac"))

    def test_windows_defaults(self):
        with mock.patch.object(m.os, "name", "nt"):
            self.assertEqual(m.default_master_root(), Path("M:\\"))
            self.assertEqual(m.default_alac_root(), Path("D:\\Music-ALAC"))


class ExtAndSkipTests(unittest.TestCase):
    def test_lossy_never_source(self):
        for ext in (".mp3", ".m4a", ".aac", ".ogg", ".opus", ".wma", ".mp4"):
            self.assertTrue(m.is_lossy(Path("x" + ext)))
            self.assertFalse(m.is_lossless(Path("x" + ext)))

    def test_lossless_ok(self):
        for ext in (".flac", ".wav", ".dsf", ".ape", ".tak", ".wv"):
            self.assertTrue(m.is_lossless(Path("x" + ext)))
            self.assertFalse(m.is_lossy(Path("x" + ext)))

    def test_skip_system_dirs(self):
        self.assertTrue(m.should_skip_dir("System Volume Information"))
        self.assertTrue(m.should_skip_dir("$RECYCLE.BIN"))
        self.assertTrue(m.should_skip_dir(".hidden"))
        self.assertFalse(m.should_skip_dir("Artist"))


class PathMappingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.master = Path(self.tmp.name) / "music"
        self.alac = Path(self.tmp.name) / "music-alac"
        self.master.mkdir()
        self.alac.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def test_same_relative_path_m4a(self):
        src = self.master / "Artist" / "Album" / "01 Track.flac"
        dest = m.dest_for_source(src, self.master, self.alac)
        self.assertEqual(dest, self.alac / "Artist" / "Album" / "01 Track.m4a")

    def test_outside_master_returns_none(self):
        src = Path(self.tmp.name) / "other" / "x.flac"
        self.assertIsNone(m.dest_for_source(src, self.master, self.alac))

    def test_prefer_flac_same_stem(self):
        d = self.master / "A"
        d.mkdir()
        wav = d / "track.wav"
        flac = d / "track.flac"
        wav.write_bytes(b"wav")
        flac.write_bytes(b"flac")
        self.assertEqual(m.prefer_source(wav), flac)

    def test_collect_prefers_flac_skips_lossy(self):
        album = self.master / "Artist" / "Mix"
        album.mkdir(parents=True)
        (album / "a.wav").write_bytes(b"wav")
        (album / "a.flac").write_bytes(b"flac")
        (album / "b.mp3").write_bytes(b"mp3")
        (album / "c.wav").write_bytes(b"wav")
        chosen = m.collect_sources(self.master)
        stems = {src.name for src in chosen.values()}
        self.assertIn("a.flac", stems)
        self.assertNotIn("a.wav", stems)
        self.assertNotIn("b.mp3", stems)
        self.assertIn("c.wav", stems)


class OverlayTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_missing_or_empty_needs_convert(self):
        src = self.dir / "a.flac"
        dst = self.dir / "a.m4a"
        src.write_bytes(b"x")
        self.assertTrue(m.needs_convert(src, dst))
        dst.write_bytes(b"")
        self.assertTrue(m.needs_convert(src, dst))

    def test_skip_when_dest_exists_and_not_older(self):
        src = self.dir / "a.flac"
        dst = self.dir / "a.m4a"
        src.write_bytes(b"src")
        time.sleep(0.05)
        dst.write_bytes(b"dst-ok")
        self.assertFalse(m.needs_convert(src, dst))

    def test_convert_when_source_newer(self):
        src = self.dir / "a.flac"
        dst = self.dir / "a.m4a"
        dst.write_bytes(b"old")
        time.sleep(0.05)
        src.write_bytes(b"new")
        self.assertTrue(m.needs_convert(src, dst))


class CoverNameTests(unittest.TestCase):
    def test_lidarr_art_names(self):
        self.assertTrue(m.is_lidarr_art_name("poster.jpg"))
        self.assertTrue(m.is_lidarr_art_name("COVER.PNG"))
        self.assertTrue(m.is_lidarr_art_name("folder.webp"))
        self.assertFalse(m.is_lidarr_art_name("notes.txt"))
        self.assertFalse(m.is_lidarr_art_name("track.flac"))

    def test_uuid(self):
        self.assertTrue(m.is_uuid("12345678-1234-1234-1234-1234567890ab"))
        self.assertFalse(m.is_uuid("not-a-uuid"))
        self.assertFalse(m.is_uuid("12345678-1234-1234-1234-1234567890"))


class LidarrEnvTests(unittest.TestCase):
    def test_parse_pipe_paths(self):
        self.assertEqual(
            m.parse_added_track_paths("/a.flac|/b.flac"),
            ["/a.flac", "/b.flac"],
        )

    def test_event_from_env(self):
        with mock.patch.dict(os.environ, {"lidarr_eventtype": "AlbumDownload"}, clear=False):
            self.assertEqual(m.lidarr_event(None), "AlbumDownload")

    def test_cli_event_overrides_env(self):
        with mock.patch.dict(os.environ, {"lidarr_eventtype": "AlbumDownload"}, clear=False):
            self.assertEqual(m.lidarr_event("Test"), "Test")


class CoverFilePickTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.album = Path(self.tmp.name) / "album"
        self.album.mkdir()
        self.src = self.album / "song.flac"
        self.src.write_bytes(b"flac")

    def tearDown(self):
        self.tmp.cleanup()

    def test_cover_jpg_before_folder_jpg(self):
        (self.album / "cover.jpg").write_bytes(b"c")
        (self.album / "folder.jpg").write_bytes(b"f")
        kind, path = m.pick_folder_cover(self.album)
        self.assertEqual(kind, "cover.jpg")
        self.assertEqual(path, self.album / "cover.jpg")

    def test_cover_jpg_capital_c(self):
        (self.album / "Cover.jpg").write_bytes(b"c")
        kind, path = m.pick_folder_cover(self.album)
        self.assertEqual(kind, "cover.jpg")
        self.assertEqual(path.name, "Cover.jpg")

    def test_folder_jpg(self):
        (self.album / "folder.jpg").write_bytes(b"f")
        kind, path = m.pick_folder_cover(self.album)
        self.assertEqual(kind, "folder.jpg")

    def test_none_when_no_art(self):
        kind, path = m.pick_folder_cover(self.album)
        self.assertEqual(kind, "none")
        self.assertIsNone(path)


if __name__ == "__main__":
    unittest.main()
