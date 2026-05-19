# Mirror Mirror — Test Notes

Session: 2026-05-18 — testing updated plugin features (new project
organization + fine-tune flow). Driver: standalone app (newly added),
manually-launched server for log visibility.

## Status summary

End-to-end pipeline **Process → Train → Generate** validated on the
Emily Bezar / Vista album (18 mp3s, project `jos_emily_bezar`). See
*End-to-end validation result* at the bottom for the actual run.

All fixes below are **pending JOS's approval** — they're committed on
`jos` but the file itself remains tracked so a future squash-merge to
main keeps these notes available.

| # | Issue | Status | Commit (pending approval) |
|---|---|---|---|
| 1 | `/cancel` self-terminates the server | **Fixed (server)** | Wave 1 commit |
| 2 | Generate w/o project ckpt: no clear error, forces Cancel | **Fixed (server)** | Wave 1 commit |
| 3 | `daw_setup` startup warnings (Reaper / Ableton wiring broken) | **Fixed** | Wave 1 commit |
| 4 | Stale doc: `CLAUDE.md` says `.venv-ai-music/`, actual is `.venv/` | **Fixed** | Wave 1 commit |
| 5 | Standalone silently auto-spawns its own server (hides port ownership) | **Open (GUI)** | Wave 2 |
| 6 | Vendor pipeline: bare `python` for demucs + per-file swallow | **Fixed** | `367300b` (parent), `1eae52d` (submodule `jos-fail-fast`) |
| 7 | `_run_streaming` keeps only last 3 stdout lines on failure | **Fixed** | Wave 1 commit |
| 8 | `setup_venv.sh` doesn't install `torchcodec` → demucs save_audio fails | **Fixed** | `754c281` |
| 9 | "Clear" button label is wrong + silently triggers issue #1 | **Open (GUI; #1 part already fixed)** | Wave 2 |
| 10 | Train button clickable before Process has produced events; misleading error | **Fixed (server); GUI gating still pending** | Wave 1 commit |
| 11 | `plugin/server.py` launched `pipeline.py` with bare `python` | **Fixed** | `d9c404b` |
| 12 | Standalone ⌘-Tab activation doesn't bring main window forward | **Open (GUI)** | Wave 2 |
| 13 | `/generate` UnboundLocalError when `vocab_json` supplied explicitly | **Fixed** | `2f2ce95` |
| — | Test-environment additions: Standalone format, `make ps`/`pR`/`ps-stop`/`ps-log` | **Landed** | `de10fa4`, `1fe664d` |
| — | `make ps` foreground → SIGSTOP footgun (now backgrounded by default) | **Fixed** | `1fe664d` |
| — | `TEST_NOTES.md` tracked so squash-merge to main keeps it | **Landed** | `d38299a` |
| — | Unit tests: `tests/test_server.py` + `tests/test_setup.py` (19 tests, ~4s) | **Landed** | `93dce59` |

**Server-side / docs / setup fixes from Wave 1 (committed together as a single batch):**
- #1: removed `os._exit(0)` from `/cancel`. Endpoint now cancels the in-flight job and stays alive. Pinned by `TestCancelDoesNotShutdown`.
- #2: `/generate` returns HTTP 400 with a clear message when `ckpt` doesn't exist. Pinned by `TestGeneratePreconditions`.
- #3: `daw_setup.py` now uses `uv pip install --python sys.executable …` (works in uv-created venvs that have no `pip`), and the AbletonOSC URL switched from the 404'd `main` to the real default branch `master` (extracted dir name `AbletonOSC-master/` updated to match). Reaper/Ableton auto-insert should now work on a fresh setup.
- #4: `CLAUDE.md` updated — `.venv-ai-music/` → `.venv/` everywhere, and the dropped reference to a non-existent `setup.bash`.
- #7: `_run_streaming` tail buffer raised 20→100, error-display slice raised 3→10 (and 5→10 for `/generate`). The original 3-line tail showed only the subprocess startup banner; 10 lines reliably captures the actual traceback.
- #10: `/train` checks `event_vocab.json` exists before launching `train.py`, sets `stage=error` with a "no preprocessed events for project '<slug>' — run Process Audio first" message. Pinned by `TestTrainPreconditions`. *GUI-side button gating (so the user can't even click Train) is in Wave 2.*

**Still open after Wave 1 (all in the JUCE GUI, deferred to Wave 2):**
- #5: standalone auto-spawn — needs `MIRROR_MIRROR_NO_SPAWN=1` honored.
- #9: rename "Clear" → "Cancel" and only show during an active job.
- #2 / #10 — server side fails fast cleanly now; GUI should *also* disable those buttons when preconditions aren't met (mirror of `/checkpoint_status` for events).
- #12: ⌘-Tab activation handler in the JUCE Standalone wrapper.

## Test environment additions

Small toolchain changes made during this session to make GUI testing
practical:

- **`make plugin-server` / `ps`** — runs `plugin/server.py` against the
  repo root with `ARGS=` passthrough for `--port` / `--host` overrides.
- **`Standalone` added to plugin `FORMATS`** in
  `plugin/AIMusicPlugin/CMakeLists.txt:25` — builds
  `…/build/AIMusicPlugin_artefacts/<Config>/Standalone/Mirror Mirror.app`
  alongside the AU + VST3 artefacts.
- **`make plugin-run` / `pR`** — launches the Standalone app
  (`PLUGIN_CONFIG=Debug|Release`, default Release).

## What works

- Server endpoints up: `/health` returns `{"ok": true}`; `/status`
  responds; FastAPI Swagger UI at `/docs` is a clean way to poke
  endpoints interactively from the browser.
- Standalone plugin builds, signs (ad-hoc), installs alongside AU/VST3.
- Standalone connects to the externally-launched server when one is
  reachable on 127.0.0.1:7437 — confirmed by request logs appearing in
  the `make ps` terminal (`PluginProcessor.cpp:220`,
  `if (client.isServerReachable()) return;`).

## Issues observed

### 1. `/cancel` self-terminates the server

`plugin/server.py:302-317` — the `/cancel` handler calls `os._exit(0)`
0.4 s after responding, with the comment *"Shut down the server after
the response is sent so it relaunches fresh (with any updated code) on
the next plugin action."*

Consequence: any time the user presses Cancel in the GUI, the
externally-launched `make ps` server dies and the plugin spawns its own
background server on the next action — at which point log visibility is
lost.

Suggested fix: split into two endpoints — `/reset` (clear in-flight job
state, do **not** exit) and `/restart` (full re-exec for code refresh).
Use Cancel-button → `/reset`; reserve restart for an explicit "reload
server" affordance.

### 2. Generate without a project checkpoint: no clear error, forces
Cancel

Workflow that exposed (1): user picks a project and clicks Generate
*before* training. The new per-project checkpoint path
(`runs/{project}/checkpoints/model.pt`) doesn't exist; there's no
automatic fallback to the legacy global checkpoint at
`runs/checkpoints/es_model.pt` (which **does** exist on this machine).
The GUI gave no clear "no checkpoint — train first" message, leaving
Cancel as the only out.

Suggested fix: in the GUI, gate the Generate button on
`GET /checkpoint_status?project_name=…` (already exists at
`plugin/server.py:229`); disable + tooltip "no checkpoint — train
first" when `exists: false`.

### 3. `daw_setup` startup warnings (non-blocking)

On server start:

```
[daw_setup] pip install failed: …/.venv/bin/python: No module named pip
[daw_setup] python-reapy not yet importable — retry after pip step
[daw_setup] AbletonOSC download failed: HTTP Error 404: Not Found
```

- `pip` is missing because `uv`-created venvs don't include it. Either
  `uv pip install --python .venv/bin/python pip`, or change
  `daw_setup.py` to shell out to `uv pip install` instead of importing
  `pip`.
- AbletonOSC URL in `daw_setup.py` is stale (returns 404).

Neither blocks the audio→MIDI→train→generate pipeline. Only matters if
DAW auto-insert (Reaper / Ableton) is in scope.

### 4. Stale doc: venv directory name

`CLAUDE.md` documents the venv as `.venv-ai-music/` but the actual
directory (and the Makefile's `VENV_DIR`) is `.venv/`. Cosmetic, but
misleads first-time onboarding.

### 5. Standalone silently auto-spawns a server, hiding port ownership

`PluginProcessor.cpp:216` (`launchServer()`) is called whenever the
plugin needs the server and `isServerReachable()` returns false on
127.0.0.1:7437. Combined with issue #1 (cancel kills the server), this
produces a confusing loop during dev testing:

1. `make ps` server dies on /cancel.
2. Standalone's next request finds nothing on 7437 → spawns its own
   background server (log-invisible).
3. User tries `make ps` again → port collision (`Errno 48 address
   already in use`).

The standalone gives no signal that it now owns 7437, and the only way
to take the port back is to quit the app first. Sequence that works:
quit standalone → `lsof -ti :7437 | xargs -r kill` → `make ps` →
`make pR`.

Suggested fix: honor an env var (e.g. `MIRROR_MIRROR_NO_SPAWN=1`) or a
GUI toggle that disables `launchServer()`. In that mode a missing
server should surface as a clear "server not running — start with
`make ps`" status instead of silently self-spawning. Useful any time
the dev wants log visibility.

### 6. Demucs invocation escaped the venv; vendor pipeline swallowed the failure — FIXED

Symptom: GUI showed `Status: error` at `step 3/3: preprocessing` with
an opaque message; `runs/{project}/midis/` was empty and
`event_vocab.json` was missing, so a subsequent Train crashed in
`training/train.py:166` `load_vocab` with `FileNotFoundError`.

Three stacked bugs (all in `vendor/all-in-one-ai-midi-pipeline`, all
violating "FAIL FAST"):

1. `steps/separate.py:69` shelled out to bare `"python" -m
   demucs.separate"`, which resolved to whatever `python` is first on
   `PATH` (here: `/Users/jos/miniforge3/bin/python`, no demucs) instead
   of `.venv/bin/python` (where demucs 4.0.1 is installed).
2. `pipeline.py cmd_run_batch` wrapped each file in `try/except
   Exception` and always returned `rc=0`, so the server saw every
   track as a successful run.
3. `plugin/server.py` step-2 only checked that per-track folders
   *existed* (mtime-based) before launching preprocess, not that they
   *contained* any `.mid` file. Vendor pipeline creates the per-song
   folder before the demucs step runs, so an empty folder counted as
   success.

Fixed in three commits on `jos`:
- `367300b` — bumps submodule to `jos-fail-fast` (`1eae52d`): use
  `sys.executable`; remove the swallow in `cmd_run_batch`.
- `362166a` — server step-2 requires `≥1 .mid` per candidate track;
  reports the names of any empty tracks; accurate MIDI-file count.
- `de10fa4` — `Standalone` plugin format + `make ps`/`make pR`
  (test-tooling enablers, not a fix but co-required for visibility).

### 7. `_run_streaming` error tail is too short to diagnose subprocess failures

When a child like `pipeline.py` or `pre.py` fails, the server reports
"…failed: " + the last 3 stdout lines. In practice those last 3 lines
are usually the subprocess's *startup banner* (instrument config, etc.)
because the actual exception trace landed dozens of lines earlier and
fell off the buffer. The original "preprocessing failed" message we
saw is a textbook case — it told us nothing.

Suggested fix: keep a much longer tail (~50 lines), and/or mirror
subprocess stdout to a per-job log file at
`runs/{project}/logs/<stage>-<timestamp>.log` so the full trace
survives. The status message can keep a short hint and a pointer to
the log path.

### 8. `setup_venv.sh` doesn't install `torchcodec`; demucs blows up on save — FIXED

`scripts/setup_venv.sh:60-95` always upgrades to latest
`torch`/`torchaudio` (here: torch 2.12.0, torchaudio 2.11.0).
torchaudio ≥2.10 routes `save_audio` through `torchcodec` (see
`torchaudio/_torchcodec.py:248`), but the script doesn't install it.
Result: demucs computes the separation, then dies on its first stem
write with `ModuleNotFoundError: No module named 'torchcodec'` — and
because pre-fix #6, the failure was invisible. Post-fix #6 the error
surfaces clearly: *"vendor pipeline failed (… mp3): … subprocess
CalledProcessError"*.

Worked around live with `uv pip install --python .venv/bin/python
torchcodec` (got `torchcodec==0.12.0`); manual demucs run on a 4:35
song then completes in ~63s and writes all 6 stems.

Proper fix landed in `754c281` on `jos`: `scripts/setup_venv.sh` now
installs `torchcodec` automatically on every branch except the
macOS 13 / Apple Silicon torchaudio 2.2.x pin (which still uses the
legacy ffmpeg save path). Sanity-check block also prints `torchaudio`
and `torchcodec` versions so a broken install surfaces immediately.
`make setup` and `make setup-force` both go through this script, so
both targets are covered.

### 9. "Clear" button label is wrong (and silently triggers issue #1)

The bottom-right button is labelled **Clear** but its tooltip says
*"Cancel the currently running job."*. Two problems:
- The verb mismatch implies "reset UI / clear the error message",
  which is what a user looking at a Status: error screen would
  reasonably want — but the actual action is `/cancel`.
- Because `/cancel` self-terminates the server (issue #1), clicking
  "Clear" to dismiss an error state kills the user's running `make
  ps` server. The label gives no warning of either consequence.

Suggested fix: split into two buttons / two endpoints:
- **Clear**: client-side only, blank the status/error display.
- **Cancel** (only visible when a job is actually running): hits
  `/cancel`, and per issue #1 should call the proposed `/reset`
  instead of the server-killing path.

### 10. Train can be clicked before Process has produced events; error is misleading

The Train button is enabled regardless of whether
`runs/{project}/events/event_vocab.json` exists. Clicking it when it
doesn't (e.g. because the user skipped Process, or Process failed
partway) sets the status to `error: training failed: …
FileNotFoundError: …/events/event_vocab.json` — which looks like a
training bug but is really "preprocess never ran for this project."

Suggested fixes:
- **Server**: `/train` should fail-fast on `not events_dir.exists()`
  with a clear "no events for project '{slug}' — run Process Audio
  first" error, before launching `training/train.py`.
- **GUI**: poll a new `GET /events_status?project_name=…` (mirror of
  the existing `/checkpoint_status`) and disable the Train button
  with a tooltip when no events exist for the current project.

Same pattern as issue #2 (Generate without a checkpoint): GUI lets
you press the wrong button, server reports a confusing low-level
error instead of the actual precondition violation.

### 11. `plugin/server.py` launched `pipeline.py` with bare `python` — FIXED

Same class of bug as #6 (demucs/sys.executable), one layer up. Every
subprocess call in `plugin/server.py` uses the resolved `PYTHON`
(=`.venv/bin/python`) — except line 414, which passed bare `"python"`
to launch `vendor/.../pipeline.py run-batch` per audio file. On
machines where `which python` resolves elsewhere (here:
`/Users/jos/miniforge3/bin/python`), `pipeline.py` ran outside the
venv and any of its imports (e.g. `basic_pitch` in
`steps/transcribe_melodic.py`) failed with `ModuleNotFoundError`
despite the package being correctly installed in `.venv`.

Surfaced only after fixing #6 + #8 — those fixes let demucs progress
to the next pipeline stage, where this bug had been masked. Fixed in
`d9c404b` on `jos`: one-character change, `"python"` → `PYTHON`.
Swept the rest of the codebase (`plugin/`, `training/`, `scripts/`,
`finetune/`) — no other bare-`python` subprocess sites.

### 12. Standalone app: ⌘-Tab activation doesn't bring main window forward

Observed twice: app appears in ⌘-Tab and Dock, but selecting it does
not show its window. Workaround: right-click the Dock icon → Show
All Windows. Suggests the JUCE Standalone wrapper isn't
re-fronting/un-minimizing the main editor window on application
activation when the window is hidden, off-screen, or on another
Space.

Note: on one occurrence, iTerm2's Settings panel was open at the
same time. Possible that modal-in-another-app interaction contributed,
but a properly behaved Cocoa app should still activate cleanly on
⌘-Tab — worth not relying on this being the trigger.

Likely fix: in the JUCE app delegate, on
`applicationShouldHandleReopen:hasVisibleWindows:` (or the JUCE
equivalent) call `makeKeyAndOrderFront` on the main window. Could
also be a saved-off-screen window-position bug — JUCE persists
state to `~/Library/Application Support/Mirror Mirror.settings`.
Deleting that file would force-reset window position if the issue
recurs after window dragging.

### 13. `/generate` UnboundLocalError when `vocab_json` supplied explicitly — FIXED

`plugin/server.py:719` referenced `torch.cuda.is_available()` to
choose the device for `generate_v2.py`, but `torch` was only imported
inside the `if vocab_path is None` auto-detection branch above (line
664). When a caller (curl, or any client) supplies `vocab_json`
explicitly, the auto-detection branch is skipped and the local
`torch` is never bound — the endpoint dies with `UnboundLocalError:
local variable 'torch' referenced before assignment` before
`generate_v2.py` is even launched.

Side observation while fixing: the device line was
`"cuda" if torch.cuda.is_available() else "cpu"` — silently dropping
MPS on Apple Silicon (5-10x slowdown for nothing).

Fixed in `2f2ce95` on `jos`: local `import torch as _torch` directly
above the cmd list, and the device selection now prefers MPS over CPU
when CUDA isn't available.

## End-to-end validation result

Driven entirely via `curl` against the manually-launched `make ps`
server, with the standalone quit so it couldn't compete for the port
and re-spawn its own (per issue #5). Project name `jos_emily_bezar`,
audio folder `/Users/jos/Music/Emily Bezar - Vista` (18 mp3s).

| Stage | Duration | Output |
|---|---|---|
| **Process** | ~30 min total (~1.5 min/track for step 1) | `runs/jos_emily_bezar/midis/*.mid` (18), `events_train.pkl` 28 MB, `events_val.pkl` 695 KB, `event_vocab.json` |
| **Train** | ~68 min (39 epochs; early-stopped, patience=10) | `runs/jos_emily_bezar/checkpoints/model.pt` 18 MB; best val_loss **1.500** at epoch 29 |
| **Generate** | ~5 s | `runs/generated/plugin/4b2a1477/generated.{mid,events.json,wav}` — 13.5 s of MIDI, 6 instruments (5 melodic + drums), real note counts (32/45/5/4 for the larger tracks) |

All three stages produced their expected artefacts. The blues6
instrument set (voxlead, voxharm, guitar, other, bass, drums) is
represented in the generated MIDI. FluidSynth was already installed,
so the WAV preview was also rendered automatically.

## Open / not yet tested

- **Fine-tune flow** (`finetune/` LoRA pipeline) — not exercised in
  this session.
- **GUI-driven** Process → Train → Generate as a full sequence — the
  end-to-end above was driven from `curl`, not the standalone, after
  the standalone was killed to keep port 7437 stable (per #1, #5).
  Worth running through the GUI once the gating fixes (#2, #10) land.
- **Project switching from the GUI** — does the GUI cleanly re-bind
  to a different `runs/{project}/` and pick up its existing checkpoint?
- **Watchdog stall-detection in `/train`** — code path is in
  `server.py:563-592` but didn't trigger during this run (no stalls).
- **Reaper / Ableton auto-insert** — both blocked by issue #3 (broken
  `daw_setup.py`), so they were never reached.
