"""Render loop — drives the matrix widget, captures frames, pushes to the LCD."""

from __future__ import annotations

import logging
import sys
from io import BytesIO

from PySide6.QtCore import QBuffer, QByteArray, QIODevice, QTimer, Qt
from PySide6.QtGui import QImage
from PySide6.QtWidgets import QApplication

from .fonts import register_fonts
from .lcd.output import LcdOutput
from .telemetry.claude_code import ClaudeCodeSource
from .telemetry.demo import DemoSimulator
from .themes.matrix import MatrixThemeWidget

log = logging.getLogger(__name__)


def encode_jpeg(image: QImage, quality: int = 85) -> bytes:
    ba = QByteArray()
    buf = QBuffer(ba)
    buf.open(QIODevice.WriteOnly)
    ok = image.save(buf, "JPEG", quality)
    buf.close()
    if not ok:
        raise RuntimeError("QImage.save JPEG failed")
    return bytes(ba)


def run(*, source: str, mirror: bool, no_lcd: bool, fps: int = 15, sim_ms: int = 380, jpeg_quality: int = 85) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    app = QApplication.instance() or QApplication(sys.argv)
    register_fonts()

    sim: DemoSimulator | None = None
    cc: ClaudeCodeSource | None = None
    if source == "claude-code":
        cc = ClaudeCodeSource()
        initial = cc.tick()
    else:
        sim = DemoSimulator(agent_kind="claude-code", model_key="sonnet45")
        initial = sim.tel

    widget = MatrixThemeWidget(initial)
    widget.ensurePolished()
    if mirror:
        widget.show()

    lcd: LcdOutput | None = None
    if not no_lcd:
        lcd = LcdOutput()
        res = lcd.open()
        log.info("LCD resolution reported: %s", res)

    # telemetry tick — advance demo OR re-read jsonl for claude-code
    def tel_tick():
        if cc is not None:
            widget.update_tel(cc.tick())
        elif sim is not None:
            sim.tick()
            widget.update_tel(sim.tel)

    tel_timer = QTimer()
    tel_timer.timeout.connect(tel_tick)
    # claude-code source benefits from a slower tick (1Hz) since the file
    # only grows at turn boundaries; demo needs the snappier 380ms cadence.
    tel_timer.start(1000 if cc is not None else sim_ms)

    # render + push frame at fps
    blink_phase = [0.0]
    def render_tick():
        blink_phase[0] += 1.0 / fps
        widget.blink = blink_phase[0]
        # force a synchronous repaint into an offscreen image
        img = QImage(1280, 480, QImage.Format_RGB888)
        img.fill(0)
        widget.render(img)  # paints widget contents into img
        if lcd is not None:
            jpeg = encode_jpeg(img, jpeg_quality)
            try:
                ok = lcd.send(jpeg)
                if not ok:
                    log.warning("send_frame returned False")
            except Exception as e:
                log.error("LCD send failed: %s", e)

    render_timer = QTimer()
    render_timer.timeout.connect(render_tick)
    render_timer.start(int(1000 / fps))

    try:
        return app.exec()
    finally:
        if lcd is not None:
            try:
                lcd.close()
            except Exception:
                pass
