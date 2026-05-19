"""Smoke tests for plugin/server.py.

Uses FastAPI's TestClient (in-process — no live port, no subprocess for
the test harness itself). Endpoints that *internally* spawn subprocesses
(/process, /train, /generate) are only exercised on synchronous error
paths so individual tests stay sub-second.
"""
import time

import pytest
from fastapi.testclient import TestClient

import server  # via tests/conftest.py: plugin/ on sys.path


# ── fixtures ────────────────────────────────────────────────────────────

@pytest.fixture
def client():
    return TestClient(server.app)


@pytest.fixture(autouse=True)
def reset_server_state():
    """Force a clean module-global state between tests.

    /process etc. mutate `server._status` and acquire `server._job_lock`
    from a background thread; without this fixture a prior test's
    in-flight job can leak into the next.
    """
    # Drain any held lock (best-effort; non-fatal if it was never acquired).
    try:
        server._job_lock.release()
    except RuntimeError:
        pass
    server._set_status(
        stage="idle", message="", error=None, epoch=None,
        total_epochs=None, train_loss=None, val_loss=None,
        progress=None, batch_progress=None, events_dir=None,
        ckpt_path=None, daw_insert=None, midi_path=None,
    )
    yield


def _wait_for_terminal(client: TestClient, timeout: float = 8.0) -> dict:
    """Poll /status until stage ∈ {done, error}. Raises on timeout.

    Deliberately excludes 'idle' — the autouse reset fixture sets idle,
    so accepting it would return *before* the endpoint's background
    thread had a chance to set a real terminal state. Tests that exercise
    a 'cancelled → idle' transition should poll directly instead.
    """
    deadline = time.time() + timeout
    s = None
    while time.time() < deadline:
        s = client.get("/status").json()
        if s["stage"] in ("done", "error"):
            return s
        time.sleep(0.05)
    raise TimeoutError(f"/status never reached terminal state within {timeout}s; last={s}")


# ── /health, /status, /docs ─────────────────────────────────────────────

class TestHealth:
    def test_health_ok(self, client):
        r = client.get("/health")
        assert r.status_code == 200
        assert r.json() == {"ok": True}


class TestStatus:
    def test_status_shape(self, client):
        r = client.get("/status")
        assert r.status_code == 200
        body = r.json()
        for key in ("stage", "message", "epoch", "val_loss", "error", "progress"):
            assert key in body, f"missing key in /status: {key!r}"


class TestDocs:
    def test_swagger_available(self, client):
        r = client.get("/docs")
        assert r.status_code == 200
        assert "swagger" in r.text.lower() or "openapi" in r.text.lower()


# ── /process preconditions ──────────────────────────────────────────────

class TestProcessPreconditions:
    """Synchronous fast-fail paths in /process — no demucs/basic_pitch needed."""

    def test_no_audio_files_in_folder(self, client, tmp_path):
        """An empty folder produces a clear error, not a confusing
        downstream preprocess crash."""
        empty = tmp_path / "no_audio_here"
        empty.mkdir()
        r = client.post("/process", json={
            "audio_folder": str(empty),
            "project_name": "smoke_no_audio",
        })
        assert r.status_code == 200
        assert r.json() == {"started": True}

        final = _wait_for_terminal(client)
        assert final["stage"] == "error"
        assert "no audio" in (final["error"] or "").lower()

    def test_concurrent_jobs_rejected(self, client, tmp_path):
        """A second /process while one is in flight returns 409."""
        empty = tmp_path / "no_audio_here"
        empty.mkdir()
        # Grab the lock from "outside" to simulate an in-flight job.
        assert server._job_lock.acquire(blocking=False)
        try:
            r = client.post("/process", json={"audio_folder": str(empty)})
            assert r.status_code == 409
        finally:
            server._job_lock.release()


# ── /checkpoint_status (cheap, no subprocess) ───────────────────────────

class TestCheckpointStatus:
    def test_unknown_project_reports_missing(self, client):
        r = client.get("/checkpoint_status", params={"project_name": "definitely_not_a_real_project_xyz"})
        assert r.status_code == 200
        body = r.json()
        assert body["exists"] is False
        assert body["epoch"] is None


# ── /train preconditions (issue #10 fix) ────────────────────────────────

class TestTrainPreconditions:
    def test_no_events_for_project(self, client):
        """Train must fail fast with a clear message — not launch train.py
        and die deep inside load_vocab with FileNotFoundError."""
        r = client.post("/train", json={"project_name": "definitely_not_a_real_project_xyz"})
        assert r.status_code == 200
        assert r.json() == {"started": True}
        final = _wait_for_terminal(client)
        assert final["stage"] == "error"
        err = (final["error"] or "").lower()
        assert "no preprocessed events" in err
        assert "process audio first" in err


# ── /generate preconditions (issue #2 fix) ──────────────────────────────

class TestGeneratePreconditions:
    def test_missing_ckpt_400(self, client, tmp_path):
        """Generate with a non-existent checkpoint must 400 synchronously —
        not acquire the job lock and silently fail in a background thread."""
        bogus_ckpt = tmp_path / "nope.pt"
        r = client.post("/generate", json={
            "ckpt": str(bogus_ckpt),
            "vocab_json": str(tmp_path / "vocab.json"),
        })
        assert r.status_code == 400
        detail = r.json()["detail"].lower()
        assert "checkpoint not found" in detail


# ── /cancel must not kill the server (issue #1 fix) ────────────────────

class TestCancelDoesNotShutdown:
    def test_cancel_leaves_server_responsive(self, client):
        """Pre-fix, /cancel called os._exit(0) after responding, killing the
        process. With TestClient that would tear down the in-process app
        and any subsequent request would raise. Now /cancel is a clean
        no-op when no job is in flight."""
        r = client.post("/cancel")
        assert r.status_code == 200
        assert r.json() == {"cancelled": True}
        # The next request must still succeed against the same app/client.
        r2 = client.get("/health")
        assert r2.status_code == 200
        assert r2.json() == {"ok": True}
