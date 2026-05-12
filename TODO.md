# TODO

Cleanup and refinement items for Mirror Mirror.

**Done summary** (latest pass): `.venv-ai-music` → `.venv` rename across the
repo (9 files), CPM-based JUCE fetch, `setup.bash` removed, `clean`/`distclean`
split, duplicate `export-midi` call removed, Makefile `.PHONY` refactored to
per-rule declarations.

---

## ✅ Done

### ✅ Venv rename `.venv-ai-music` → `.venv`
Updated: `Makefile`, `scripts/setup_venv.sh`, `scripts/runpod_setup.sh`,
`plugin/server.py`, `plugin/AIMusicPlugin/Source/PluginProcessor.cpp`,
`install.ps1`, `README.md` (3 occurrences), `finetune/requirements.txt`,
`finetune/check_instruments.py`. No on-disk `.venv-ai-music/` existed.

### ✅ JUCE dependency via CPM
- Vendored `plugin/AIMusicPlugin/cmake/CPM.cmake` (latest release, 1366 lines)
- Replaced `add_subdirectory($ENV{HOME}/JUCE ...)` with `CPMAddPackage(NAME JUCE GITHUB_REPOSITORY juce-framework/JUCE GIT_TAG 8.0.3)`
- CMakeLists defaults `CPM_SOURCE_CACHE` to `~/.cache/CPM` (macOS/Linux) or
  `$LOCALAPPDATA/CPM` (Windows) if the env var isn't set
- Removed manual JUCE download from `install-dev.sh` (eliminated `JUCE_VERSION`/`JUCE_DIR` vars and the curl/unzip block)
- Updated README: removed "Step 3 — Install JUCE", renumbered build step,
  updated Requirements table
- **Verified end-to-end:** clean configure + `cmake --build build -j 8` succeeds
  (exit 0); both `Mirror Mirror.vst3` and `Mirror Mirror.component` install to
  `~/Library/Audio/Plug-Ins/`. JUCE cached at `~/.cache/CPM/juce/c27a/` — other
  projects pinning JUCE 8.0.3 will reuse this clone.
- *Note:* one harmless `CMP0175` policy warning surfaces from JUCE's own
  `JUCEUtils.cmake` — pre-existing JUCE-internal issue, not caused by CPM.

### ✅ Remove stale `setup.bash`
Deleted. `scripts/setup_venv.sh` (called by `make setup`) is now the single
venv-creation path. No remaining references in the repo.

### ✅ Split `make clean` / `make distclean`
- `make clean` now only removes plugin `build/` and Python `__pycache__/` /
  `.pytest_cache` (excludes `vendor/` and `.venv/`)
- `make distclean` does what `clean` used to do (also removes `.venv` and `runs/`)
- Added `distclean` to `.PHONY`

### ✅ Dedupe `export-midi` in `run_end_to_end.sh`
The `export-midi` call inside the first `pushd` block is gone; the labeled
`=== [2/4] Export MIDIs ===` step that runs it once is the only call now.

---

### ✅ Makefile `.PHONY` per-rule declarations
- Replaced the single ~80-target `.PHONY:` line with 59 per-rule declarations
  adjacent to each rule (multi-name rules like `blues-generate bg` get one
  joint `.PHONY: blues-generate bg` line)
- **Bug fix:** `blues-retrain` was missing from the original `.PHONY` list and
  was silently relying on no file by that name existing; now properly declared
- File targets (`data/blues_midi/.fetched`, `$(BLUES_EVENTS)/events_train.pkl`,
  `$(FT_DATA_DIR)/train_ids.npy`, etc.) correctly stay non-phony
- **Verified:** `make help` produces all 59 targets in the same order; dry-runs
  of `distclean`, `bg`, `pd` resolve recipes correctly

---

### ✅ Plugin build defaults to Release
- `plugin-build` / `pb` now defaults to `PLUGIN_CONFIG=Release` (was Debug)
- `plugin-reconfigure` / `pcfg` now defaults to Release
- `plugin-rebuild` / `prb` now does `plugin-clean plugin-release` (was `plugin-debug`)
- `plugin-debug` / `pd` and `plugin-release` / `pr` aliases unchanged — explicit
  Debug still available
- `install-dev.sh` and `scripts/package_release.sh` already used Release explicitly
  (no change needed there)
- **Verified:** `make -n pb` shows `${PLUGIN_CONFIG:-Release}`; `make -n prb`
  cascades to `plugin-build PLUGIN_CONFIG=Release`
- Also updated `CLAUDE.md` to document the new defaults

### ✅ `CLAUDE.md` no longer gitignored
Removed the `CLAUDE.md` line from `.gitignore` so the `/init`-generated guide
is committed alongside the codebase. `planning/` is still ignored.

### ✅ Wired `finetune/check_instruments.py` into Makefile
Added `ft-check` target in the finetuning section. Defaults to
`--data_dir $(FT_DATA_DIR)` (inspects converted finetune data); override with
`ARGS="--midi_dir summer_midi"` for raw-MIDI mode. Verified it appears in
`make help`.

---

## Pending — lower priority / fragile

### Pending — Hardcoded `.venv` lookup in plugin code
`plugin/server.py` and `plugin/AIMusicPlugin/Source/PluginProcessor.cpp` both
look up `.venv/bin/activate` by literal path. Fine for now; only worth
revisiting if non-default venv locations need support.

### Pending — Vendored torch-pin stripping is fragile
`scripts/setup_venv.sh` uses `grep -vE '^torch([=<>!~ ]|$)'` to filter
`vendor/all-in-one-ai-midi-pipeline/requirements.txt`. Breaks silently if
upstream adds extras like `torch[opt]==...`. Better: drop the pin upstream in
the submodule, or use a proper requirements parser.
