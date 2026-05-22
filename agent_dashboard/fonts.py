"""Load bundled JetBrains Mono into Qt's font database so the matrix theme
renders identically regardless of system font availability."""

from __future__ import annotations

import logging
from pathlib import Path

from PySide6.QtGui import QFontDatabase

log = logging.getLogger(__name__)

_FONT_DIR = Path(__file__).resolve().parent.parent / "assets" / "fonts"


def register_fonts() -> None:
    if not _FONT_DIR.is_dir():
        log.warning("font dir missing: %s", _FONT_DIR)
        return
    for ttf in sorted(_FONT_DIR.glob("*.ttf")):
        fid = QFontDatabase.addApplicationFont(str(ttf))
        if fid < 0:
            log.warning("failed to register %s", ttf.name)
