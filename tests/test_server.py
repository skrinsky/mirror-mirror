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
    """Poll /status until stage ∈ {done, error, idle}. Raises on timeout."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        s = client.get("/status").json()
        if s["stage"] in ("done", "error", "idle"):
            return s
        time.sleep(0.1)
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
