"""Thin wrapper around TRCC's HID Type 2 protocol — opens the Trofeo Vision
USB display and pushes JPEG frames to it.

TRCC is imported from the pipx install rather than re-installed, since the
HID protocol module has no external state and we only need the classes.
"""

from __future__ import annotations

import io
import logging
import sys
from pathlib import Path

_TRCC_SITE = Path.home() / ".local/share/pipx/venvs/trcc-linux/lib/python3.13/site-packages"
if _TRCC_SITE.is_dir() and str(_TRCC_SITE) not in sys.path:
    sys.path.insert(0, str(_TRCC_SITE))

from trcc.adapters.device.hid import (  # noqa: E402
    HidDeviceType2,
    PyUsbTransport,
    TYPE2_PID,
    TYPE2_VID,
)

log = logging.getLogger(__name__)


class LcdOutput:
    """Opens the Trofeo Vision and pushes JPEG frames to it.

    Usage:
        lcd = LcdOutput()
        lcd.open()           # handshake
        lcd.send(jpeg_bytes) # one frame
        lcd.close()
    """

    def __init__(self) -> None:
        self.transport: PyUsbTransport | None = None
        self.device: HidDeviceType2 | None = None
        self.resolution: tuple[int, int] | None = None

    def open(self) -> tuple[int, int]:
        self.transport = PyUsbTransport(TYPE2_VID, TYPE2_PID)
        self.transport.open()
        self.device = HidDeviceType2(self.transport)
        info = self.device.handshake()
        self.resolution = info.resolution or (1280, 480)
        log.info("LCD ready — resolution %s, model %s, fbl %s", self.resolution, info.model_id, info.fbl)
        return self.resolution

    def send(self, jpeg_bytes: bytes) -> bool:
        if self.device is None:
            raise RuntimeError("LcdOutput.open() not called")
        return self.device.send_frame(jpeg_bytes)

    def close(self) -> None:
        if self.device is not None:
            self.device.close()
            self.device = None
        if self.transport is not None:
            self.transport.close()
            self.transport = None
