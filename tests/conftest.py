"""Pytest-wide sys.path setup so tests can import top-level + plugin/ modules."""
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
for p in (REPO, REPO / "plugin"):
    sp = str(p)
    if sp not in sys.path:
        sys.path.insert(0, sp)
