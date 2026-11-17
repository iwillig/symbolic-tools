#!/usr/bin/env python3
"""Isolated regression tests for scripts/build_nif.sh (no Cargo build required)."""
import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "scripts/build_nif.sh"
CRATES = ("symbolic_ts", "symbolic_text", "symbolic_nlprule", "symbolic_nlp")


class BuildNifTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        (self.root / "scripts").mkdir()
        shutil.copy(SCRIPT, self.root / "scripts/build_nif.sh")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.stub("cargo", "exit 0")
        self.stub("uname", "echo Linux")
        self.stub("patchelf", 'echo "$@" >> "$PATCH_LOG"; exit "${PATCH_EXIT:-0}"')
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        PATCH_LOG=str(self.root / "patch.log"))
        self.env.pop("SYMBOLIC_SKIP_NLP", None)
        self.env.pop("PATCH_EXIT", None)
        for crate in CRATES:
            artifact = self.root / "native" / crate / "target/release" / f"lib{crate}.so"
            artifact.parent.mkdir(parents=True)
            artifact.write_bytes(f"new {crate}".encode())
            artifact.chmod(0o755)
        self.priv = self.root / "priv"
        self.priv.mkdir()
        self.profile = self.root / "_build/test/lib/symbolic_tools/priv"
        self.profile.mkdir(parents=True)
        self.link = self.root / "_build/default/lib/symbolic_tools/priv"
        self.link.parent.mkdir(parents=True)
        self.link.symlink_to(self.priv, target_is_directory=True)

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def run_build(self, **env):
        return subprocess.run(["bash", str(self.root / "scripts/build_nif.sh")],
                              env={**self.env, **env}, text=True, capture_output=True)

    def add_libtorch(self):
        lib = self.root / "native/symbolic_nlp/target/release/build/torch/out/libtorch/libtorch/lib/libtorch_cpu.so"
        lib.parent.mkdir(parents=True)
        lib.touch()

    def test_skip_removes_stale_nlp_and_preserves_modes_and_open_file(self):
        (self.priv / "symbolic_nlp.so").write_bytes(b"stale")
        (self.profile / "symbolic_nlp.so").write_bytes(b"stale profile")
        old = self.priv / "symbolic_ts.so"
        old.write_bytes(b"old mapped library")
        with old.open("rb") as opened:
            old_inode = os.fstat(opened.fileno()).st_ino
            result = self.run_build(SYMBOLIC_SKIP_NLP="1")
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual(b"old mapped library", opened.read())
            self.assertNotEqual(old_inode, old.stat().st_ino)
        for crate in CRATES[:-1]:
            for directory in (self.priv, self.profile):
                installed = directory / f"{crate}.so"
                self.assertEqual(f"new {crate}".encode(), installed.read_bytes())
                self.assertEqual(0o755, stat.S_IMODE(installed.stat().st_mode))
        self.assertFalse((self.priv / "symbolic_nlp.so").exists())
        self.assertFalse((self.profile / "symbolic_nlp.so").exists())
        self.assertFalse((self.root / "patch.log").exists())
        # A second, clean skip build is also valid.
        result = self.run_build(SYMBOLIC_SKIP_NLP="1")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse((self.profile / "symbolic_nlp.so").exists())

    def test_patchelf_failure_is_visible_and_does_not_replace_old_nlp(self):
        self.add_libtorch()
        old = self.priv / "symbolic_nlp.so"
        old.write_bytes(b"old nlp")
        result = self.run_build(PATCH_EXIT="7")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("ERROR: failed to set libtorch rpath", result.stderr)
        self.assertEqual(b"old nlp", old.read_bytes())
        self.assertEqual([], list(self.priv.glob(".symbolic_nlp.*")))

    def test_normal_build_installs_nlp_in_both_locations(self):
        self.add_libtorch()
        result = self.run_build()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("--set-rpath", (self.root / "patch.log").read_text())
        for directory in (self.priv, self.profile):
            path = directory / "symbolic_nlp.so"
            self.assertEqual(b"new symbolic_nlp", path.read_bytes())
            self.assertEqual(0o755, stat.S_IMODE(path.stat().st_mode))


if __name__ == "__main__":
    unittest.main()
