"""
Central logging configuration for QueMory.

Creates a timestamped log file in the repo-level ``logging/`` folder on
every application run and configures both a file handler and a console
handler on the root logger.

Usage
-----
At application start (in ``server.py``)::

    from logging_setup import setup_logging
    setup_logging()

Anywhere else in the codebase::

    import logging
    log = logging.getLogger(__name__)
    log.info("something happened")

Design notes
------------
* The file path is decided once per process and exposed as
  ``LOG_FILE_PATH``.  This makes it easy for users / developers to find
  the file they need to inspect.
* ``setup_logging`` is idempotent — calling it twice will not duplicate
  handlers.  This matters because ``uvicorn --reload`` re-imports
  ``server`` on every code change.
* Console output is colour-free and trimmed; the file handler records
  the full picture (timestamp, level, logger name, file:line, message).
* Third-party libraries that talk too much (urllib3, PIL, matplotlib,
  uvicorn.access) are dialled down to WARNING so the log stays
  signal-heavy.
* ``log.exception(...)`` is the recommended call inside an ``except``
  block — it automatically attaches the full stack trace.
"""

from __future__ import annotations

import logging
import logging.handlers
import os
import sys
from datetime import datetime
from pathlib import Path

# Resolve the repo root: this file lives in <repo>/backend/.
_REPO_ROOT = Path(__file__).resolve().parent.parent
LOG_DIR = _REPO_ROOT / "logging"

# Populated by ``setup_logging`` so callers can print the path on startup.
LOG_FILE_PATH: Path | None = None

_FILE_FORMAT = (
    "%(asctime)s.%(msecs)03d | %(levelname)-8s | %(name)s | "
    "%(filename)s:%(lineno)d | %(message)s"
)
_CONSOLE_FORMAT = "%(asctime)s | %(levelname)-8s | %(name)s | %(message)s"
_DATEFMT = "%Y-%m-%d %H:%M:%S"

_INITIALIZED = False


def _build_log_filename() -> str:
    """Return a clear timestamp-based file name like ``run_2026-05-16_14-30-22.log``."""
    return datetime.now().strftime("run_%Y-%m-%d_%H-%M-%S.log")


def setup_logging(
    file_level: int = logging.DEBUG,
    console_level: int = logging.INFO,
) -> Path:
    """Configure root logging and return the path to the log file.

    Parameters
    ----------
    file_level:
        Minimum level written to the log file.  Default ``DEBUG`` so the
        file contains the maximum amount of diagnostic information.
    console_level:
        Minimum level written to ``stderr``.  Default ``INFO`` to avoid
        flooding the terminal.
    """
    global _INITIALIZED, LOG_FILE_PATH

    if _INITIALIZED:
        return LOG_FILE_PATH  # type: ignore[return-value]

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    LOG_FILE_PATH = LOG_DIR / _build_log_filename()

    file_handler = logging.FileHandler(LOG_FILE_PATH, encoding="utf-8")
    file_handler.setLevel(file_level)
    file_handler.setFormatter(logging.Formatter(_FILE_FORMAT, datefmt=_DATEFMT))

    console_handler = logging.StreamHandler(stream=sys.stderr)
    console_handler.setLevel(console_level)
    console_handler.setFormatter(logging.Formatter(_CONSOLE_FORMAT, datefmt=_DATEFMT))

    root = logging.getLogger()
    root.setLevel(logging.DEBUG)
    # Wipe any handlers that uvicorn / pytest / IDE may have attached so
    # we end up with exactly the two we want.
    for h in list(root.handlers):
        root.removeHandler(h)
    root.addHandler(file_handler)
    root.addHandler(console_handler)

    # Tame noisy third-party loggers.
    for noisy in (
        "PIL",
        "urllib3",
        "matplotlib",
        "asyncio",
        "uvicorn.access",
        "watchfiles",
    ):
        logging.getLogger(noisy).setLevel(logging.WARNING)

    root.info("=" * 72)
    root.info("QueMory logging initialised")
    root.info("Log file: %s", LOG_FILE_PATH)
    root.info("Python:   %s", sys.version.split()[0])
    root.info("PID:      %s", os.getpid())
    root.info("CWD:      %s", os.getcwd())
    root.info("=" * 72)

    _INITIALIZED = True
    return LOG_FILE_PATH


def get_log_file_path() -> Path | None:
    """Return the absolute path of the active log file, or ``None`` if uninitialised."""
    return LOG_FILE_PATH
