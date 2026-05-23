"""Render loop — drives the matrix widget, captures frames, pushes to the LCD."""

from __future__ import annotations

import logging
import sys
import time

from PySide6.QtCore import QBuffer, QByteArray, QIODevice, QTimer, Qt
from PySide6.QtGui import QImage
from PySide6.QtWidgets import QApplication

from .fonts import register_fonts
from .lcd.output import LcdOutput
from .telemetry.claude_code import ClaudeCodeSource
from .telemetry.codex import CodexSource
from .telemetry.demo import DemoSimulator
from .themes.matrix import MatrixThemeWidget

log = logging.getLogger(__name__)


class JpegEncoder:
    """Reusable Qt JPEG encoder to avoid per-frame QBuffer allocations."""

    def __init__(self, quality: int = 85) -> None:
        self.quality = quality
        self._ba = QByteArray()
        self._buf = QBuffer(self._ba)

    def encode(self, image: QImage) -> bytes:
        self._ba.clear()
        self._buf.open(QIODevice.WriteOnly)
        ok = image.save(self._buf, "JPEG", self.quality)
        self._buf.close()
        if not ok:
            raise RuntimeError("QImage.save JPEG failed")
        return bytes(self._ba)


def encode_jpeg(image: QImage, quality: int = 85) -> bytes:
    return JpegEncoder(quality).encode(image)


def run(
    *,
    source: str,
    mirror: bool,
    no_lcd: bool,
    fps: int = 15,
    sim_ms: int = 380,
    jpeg_quality: int = 85,
    demo_agent: str = "claude-code",
    demo_model: str = "sonnet45",
    show_rain: bool = True,
    rain_fps: int = 12,
    stats: bool = False,
    plan: str | None = None,
) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    app = QApplication.instance() or QApplication(sys.argv)
    register_fonts()

    sim: DemoSimulator | None = None
    live: ClaudeCodeSource | CodexSource | None = None
    if source == "claude-code":
        live = ClaudeCodeSource(plan=plan or "MAX 20×")
        initial = live.tick()
    elif source == "codex":
        live = CodexSource(plan=plan or "API USAGE")
        initial = live.tick()
    else:
        sim = DemoSimulator(agent_kind=demo_agent, model_key=demo_model)
        initial = sim.tel

    widget = MatrixThemeWidget(initial, show_rain=show_rain, rain_fps=rain_fps)
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
        if live is not None:
            widget.update_tel(live.tick())
        elif sim is not None:
            sim.tick()
            widget.update_tel(sim.tel)

    tel_timer = QTimer()
    tel_timer.setTimerType(Qt.CoarseTimer)
    tel_timer.timeout.connect(tel_tick)
    # Live sources only grow at turn/tool boundaries; demo needs a snappier cadence.
    tel_timer.start(1000 if live is not None else sim_ms)

    # render + push frame at fps
    fps = max(1, fps)
    frame_interval_ms = max(1, round(1000 / fps))
    frame = QImage(1280, 480, QImage.Format_RGB32)
    encoder = JpegEncoder(jpeg_quality)
    blink_phase = [0.0]
    stat = {
        "start": time.perf_counter(),
        "frames": 0,
        "render_ms": 0.0,
        "encode_ms": 0.0,
        "send_ms": 0.0,
        "jpeg_bytes": 0,
    }

    def render_tick():
        blink_phase[0] += 1.0 / fps
        widget.blink = blink_phase[0]
        # force a synchronous repaint into a reused offscreen image
        t0 = time.perf_counter()
        frame.fill(0)
        widget.render(frame)  # paints widget contents into the image
        t1 = time.perf_counter()
        if lcd is not None:
            jpeg = encoder.encode(frame)
            t2 = time.perf_counter()
            try:
                ok = lcd.send(jpeg)
                if not ok:
                    log.warning("send_frame returned False")
            except Exception as e:
                log.error("LCD send failed: %s", e)
            t3 = time.perf_counter()
            stat["encode_ms"] += (t2 - t1) * 1000
            stat["send_ms"] += (t3 - t2) * 1000
            stat["jpeg_bytes"] += len(jpeg)
        else:
            t3 = time.perf_counter()
        stat["render_ms"] += (t1 - t0) * 1000
        stat["frames"] += 1

        if stats and t3 - stat["start"] >= 5:
            frames = max(1, int(stat["frames"]))
            elapsed = t3 - stat["start"]
            avg_jpeg_kb = (stat["jpeg_bytes"] / frames / 1024) if stat["jpeg_bytes"] else 0.0
            log.info(
                "fps %.1f target %d | render %.1fms jpeg %.1fms send %.1fms | jpeg %.0fKB",
                frames / elapsed,
                fps,
                stat["render_ms"] / frames,
                stat["encode_ms"] / frames,
                stat["send_ms"] / frames,
                avg_jpeg_kb,
            )
            stat.update({
                "start": t3,
                "frames": 0,
                "render_ms": 0.0,
                "encode_ms": 0.0,
                "send_ms": 0.0,
                "jpeg_bytes": 0,
            })

    render_timer = QTimer()
    render_timer.setTimerType(Qt.PreciseTimer)
    render_timer.timeout.connect(render_tick)
    render_timer.start(frame_interval_ms)

    try:
        return app.exec()
    finally:
        if lcd is not None:
            try:
                lcd.close()
            except Exception:
                pass
