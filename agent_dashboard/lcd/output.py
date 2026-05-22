"""Opens the Trofeo Vision USB LCD and pushes JPEG frames to it.

Selects a transport backend by platform:
  - Linux: TRCC's PyUsbTransport (libusb via pyusb)
  - macOS: a local hidapi-based transport (TRCC's HidApiTransport has a
    constructor API mismatch with the real `hid` package, so we ship our
    own). On macOS the kernel claims HID interfaces with IOHIDFamily and
    won't let libusb detach them — hidapi via IOHIDManager is the only
    path without entitlements.

TRCC's HidDeviceType2 supplies the wire protocol (handshake + frame
framing) regardless of transport.
"""

from __future__ import annotations

import logging
import sys
from typing import TYPE_CHECKING

from trcc.adapters.device.hid import (
    DEFAULT_TIMEOUT_MS,
    HidDeviceType2,
    TYPE2_PID,
    TYPE2_VID,
    UsbTransport,
)

if TYPE_CHECKING:
    from trcc.core.models import HidHandshakeInfo

log = logging.getLogger(__name__)


class _MacHidTransport(UsbTransport):
    """hidapi-based UsbTransport for macOS.

    Why not TRCC's HidApiTransport? It calls ``hid.device(vid=..., pid=...)``
    but the real `hid` package's constructor takes no args — you must call
    ``hid.device()`` then ``.open(vid, pid)``. Until that's fixed upstream
    we ship our own thin wrapper.

    hidapi `write()` prepends a 1-byte report ID. Frames are bulk-style on
    Linux but the same payload sent as one HID output report works on macOS
    because IOHIDManager chunks transparently. `read()` takes a millisecond
    timeout positional arg, which we forward.
    """

    def __init__(self, vid: int, pid: int):
        self._vid = vid
        self._pid = pid
        self._dev = None
        self._is_open = False

    def open(self) -> None:
        import hid

        d = hid.device()
        d.open(self._vid, self._pid)
        d.set_nonblocking(0)
        self._dev = d
        self._is_open = True
        try:
            log.info(
                "LCD opened via hidapi — product=%r serial=%r",
                d.get_product_string(),
                d.get_serial_number_string(),
            )
        except OSError as e:
            log.debug("get_product_string raised %s", e)

    def close(self) -> None:
        if self._dev is not None:
            try:
                self._dev.close()
            except OSError as e:
                log.debug("hid close raised %s", e)
            self._dev = None
        self._is_open = False

    # Device's report descriptor declares one 512-byte vendor output report.
    # Linux libusb sends a frame as one bulk transfer that the USB controller
    # fragments into 512-byte packets; on macOS we drive the same wire pattern
    # by sending N back-to-back 512-byte HID output reports. The device's
    # firmware reassembles them via the length field in TRCC's frame header.
    _OUTPUT_REPORT_SIZE = 512

    def write(self, endpoint: int, data: bytes, timeout: int = DEFAULT_TIMEOUT_MS) -> int:
        if self._dev is None:
            raise RuntimeError("transport not open")
        chunk_size = self._OUTPUT_REPORT_SIZE
        sent = 0
        for offset in range(0, len(data), chunk_size):
            chunk = data[offset:offset + chunk_size]
            if len(chunk) < chunk_size:
                chunk = chunk + b"\x00" * (chunk_size - len(chunk))
            n = self._dev.write(b"\x00" + chunk)
            if n <= 0:
                log.warning(
                    "hid.write chunk %d/%d returned %d — device may have stalled",
                    offset // chunk_size + 1,
                    (len(data) + chunk_size - 1) // chunk_size,
                    n,
                )
                return sent
            sent += chunk_size
        return min(sent, len(data))

    def read(self, endpoint: int, length: int, timeout: int = DEFAULT_TIMEOUT_MS) -> bytes:
        if self._dev is None:
            raise RuntimeError("transport not open")
        data = self._dev.read(length, timeout_ms=timeout)
        return bytes(data) if data else b""

    @property
    def is_open(self) -> bool:
        return self._is_open


def _make_transport() -> UsbTransport:
    if sys.platform == "darwin":
        return _MacHidTransport(TYPE2_VID, TYPE2_PID)
    from trcc.adapters.device.hid import PyUsbTransport
    return PyUsbTransport(TYPE2_VID, TYPE2_PID)


class LcdOutput:
    """Opens the Trofeo Vision and pushes JPEG frames to it.

    Usage:
        lcd = LcdOutput()
        lcd.open()           # handshake
        lcd.send(jpeg_bytes) # one frame
        lcd.close()
    """

    def __init__(self) -> None:
        self.transport: UsbTransport | None = None
        self.device: HidDeviceType2 | None = None
        self.resolution: tuple[int, int] | None = None

    def open(self) -> tuple[int, int]:
        self.transport = _make_transport()
        self.transport.open()
        self.device = HidDeviceType2(self.transport)
        info: HidHandshakeInfo = self.device.handshake()
        self.resolution = info.resolution or (1280, 480)
        log.info(
            "LCD ready — resolution %s, model %s, fbl %s",
            self.resolution,
            info.model_id,
            info.fbl,
        )
        return self.resolution

    def send(self, jpeg_bytes: bytes) -> bool:
        if self.device is None:
            raise RuntimeError("LcdOutput.open() not called")
        return self.device.send_frame(jpeg_bytes)

    def close(self) -> None:
        self.device = None
        if self.transport is not None:
            self.transport.close()
            self.transport = None
