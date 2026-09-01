"""
config.py — Small helpers to locate cpp_inspector.pl and sensible defaults.

The GUI is meant to live in <repo_root>/gui/, right next to
<repo_root>/cpp_inspector.pl. We look for the script in a few likely
spots so the app also works if it's copied elsewhere or run from a
different working directory.
"""
from __future__ import annotations

import shutil
from pathlib import Path

GUI_DIR = Path(__file__).resolve().parent.parent
REPO_ROOT_GUESS = GUI_DIR.parent

SCRIPT_NAME = "cpp_inspector.pl"

CANDIDATE_SCRIPT_PATHS = [
    REPO_ROOT_GUESS / SCRIPT_NAME,
    GUI_DIR / SCRIPT_NAME,
    Path.cwd() / SCRIPT_NAME,
    Path.cwd().parent / SCRIPT_NAME,
]

REQUIRED_TOOLS = ("perl", "ctags", "cscope", "cqmakedb")

KIND_LABELS = {
    "f": "Functions",
    "p": "Prototypes",
    "m": "Members",
    "c": "Classes",
}
ALL_KINDS = "fpmc"


def find_inspector_script() -> Path | None:
    """Return the first existing candidate path for cpp_inspector.pl, or None."""
    for candidate in CANDIDATE_SCRIPT_PATHS:
        if candidate.is_file():
            return candidate.resolve()
    return None


def find_perl_binary() -> str | None:
    return shutil.which("perl")


def missing_tools() -> list[str]:
    """Return the subset of REQUIRED_TOOLS not found on PATH."""
    return [tool for tool in REQUIRED_TOOLS if shutil.which(tool) is None]
