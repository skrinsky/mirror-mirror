"""Environment + project-invariant tests.

Two concerns bundled here because the test suite is small:

1. **Runtime imports** the pipeline depends on. A missing one (e.g.
   torchcodec — see TEST_NOTES issue #8) breaks the whole audio→MIDI
   path silently. These tests would have surfaced #8 in seconds.

2. **Subprocess hygiene**: nothing under plugin/, training/, scripts/,
   or finetune/ may invoke a child Python with bare `"python"` — that
   string resolves to whichever interpreter is first on PATH and can
   silently escape `.venv`. See TEST_NOTES issues #6 (vendor) and
   #11 (server). Bare-python regressions become unrepresentable.

3. **Vendor pipeline contract**: pipeline.py run-batch must return a
   non-zero exit code when there's nothing to do. Pins the no-swallow
   behavior from the vendor fix (commit 1eae52d on jos-fail-fast,
   bumped into the parent at 367300b).
"""
import re
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent


# ── 1. runtime imports ──────────────────────────────────────────────────

class TestRuntimeImports:
    """Each test is one import that the pipeline needs at run time."""

    def test_torch(self):
        import torch
        # functional check, not just module presence
        torch.zeros(2, 2)

    def test_torchaudio(self):
        import torchaudio  # noqa: F401

    def test_torchcodec(self):
        """torchaudio≥2.10 routes save_audio through torchcodec; without it
        every demucs invocation dies on first stem write. Pins issue #8."""
        import torchcodec  # noqa: F401

    def test_basic_pitch_inference(self):
        """Pins issue #11's failure mode — basic_pitch must be importable
        from the same interpreter pipeline.py is launched with."""
        from basic_pitch.inference import predict, Model  # noqa: F401

    def test_demucs(self):
        import demucs  # noqa: F401

    def test_music21(self):
        import music21  # noqa: F401

    def test_pretty_midi(self):
        import pretty_midi  # noqa: F401

    def test_mido(self):
        import mido  # noqa: F401


# ── 2. no bare-"python" subprocess literals ─────────────────────────────

# Matches the exact subprocess argv shape: ["python", ...]   /   ('python',
# Will NOT match the executable-name lookup string `"python.exe" if ...
# else "python"` because there's no array bracket adjacent.
_BARE_PYTHON_ARGV = re.compile(r'''[\[\(]\s*["']python["']\s*,''')


def _project_py_files():
    for root in ("plugin", "training", "scripts", "finetune"):
        d = REPO / root
        if not d.exists():
            continue
        for p in d.rglob("*.py"):
            if "__pycache__" in p.parts:
                continue
            yield p


class TestNoBarePython:
    def test_no_bare_python_in_subprocess_argv(self):
        offenders = []
        for path in _project_py_files():
            text = path.read_text(encoding="utf-8", errors="ignore")
            for lineno, line in enumerate(text.splitlines(), 1):
                if _BARE_PYTHON_ARGV.search(line):
                    offenders.append(f"{path.relative_to(REPO)}:{lineno}: {line.strip()}")
        assert not offenders, (
            "bare-'python' subprocess invocation(s) found — these escape .venv "
            "when `python` resolves elsewhere on PATH. Use PYTHON or "
            "sys.executable instead.\n  " + "\n  ".join(offenders)
        )


# ── 3. vendor pipeline fail-fast contract ───────────────────────────────

class TestVendorFailFast:
    """pipeline.py run-batch must propagate failures, not return rc=0 silently.

    Even the simplest "no matching files" path must return non-zero;
    a regression of the swallowing try/except would otherwise return 0
    again. Real-audio-input failure modes (demucs decode failure, etc.)
    are exercised by the audio→MIDI pipeline itself in production runs
    and are too slow to test here.
    """

    def test_runbatch_no_matching_files_nonzero(self, tmp_path):
        pipe_dir = REPO / "vendor" / "all-in-one-ai-midi-pipeline"
        venv_py = REPO / ".venv" / "bin" / "python"
        if not pipe_dir.exists():
            pytest.skip("vendor submodule not initialized")
        if not venv_py.exists():
            pytest.skip(".venv not present — run `make setup` first")
        # A glob pattern that can't match anything.
        bogus_pattern = str(tmp_path / "nothing_matches_*.mp3")
        result = subprocess.run(
            [str(venv_py), "pipeline.py", "run-batch", bogus_pattern],
            cwd=pipe_dir, capture_output=True, text=True, timeout=120,
        )
        assert result.returncode != 0, (
            "pipeline.py run-batch returned 0 with no matching files — "
            "the cmd_run_batch swallow regressed.\n"
            f"stdout tail:\n{result.stdout[-500:]}\n"
            f"stderr tail:\n{result.stderr[-500:]}"
        )
