"""Matrix theme visual FX — glyph rain, grid mask cache, glow text helper."""

from __future__ import annotations

import math
import random
import time
from dataclasses import dataclass

from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import (
    QColor,
    QFont,
    QFontMetrics,
    QImage,
    QPainter,
    QRadialGradient,
)


# ─── glyph rain ───────────────────────────────────────────────────────────

_GLYPHS = list(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%&*+=<>/\\|{}[]"
    "ｦｧｨｩｪｫｬｭｮｯｰｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎ"
)


@dataclass
class _Drop:
    y: float
    speed: float
    length: int


class RainPainter:
    """Stateful matrix-style glyph rain. Update + paint once per frame.

    Faint by design — alpha falls off toward screen center so the rain lives
    in the gutter behind the panels, never competing with them.
    """

    FONT_SIZE = 14
    W = 1280
    H = 480

    def __init__(self, max_step_hz: int = 12) -> None:
        self.cols = self.W // self.FONT_SIZE
        self.max_step_hz = max_step_hz
        self._last_step = 0.0
        self.drops = [
            _Drop(
                y=-random.random() * 40,
                speed=0.4 + random.random() * 0.9,
                length=6 + random.randint(0, 15),
            )
            for _ in range(self.cols)
        ]
        # offscreen buffer that we fade each frame to get the trail effect
        self._buf = QImage(self.W, self.H, QImage.Format_ARGB32_Premultiplied)
        self._buf.fill(0)

    def _col_alpha(self, c: int) -> float:
        x = c * self.FONT_SIZE + self.FONT_SIZE / 2
        dx = min(x, self.W - x) / self.W   # 0 at edge, 0.5 at center
        return 0.06 + max(0.0, 0.16 - dx) * 1.6

    def _step(self, font: QFont, accent: QColor, frame_scale: float) -> None:
        # 1. fade the buffer slightly to leave trails behind
        bp = QPainter(self._buf)
        bp.setCompositionMode(QPainter.CompositionMode_DestinationIn)
        bp.fillRect(self._buf.rect(), QColor(0, 0, 0, 200))  # ~78% retain
        bp.setCompositionMode(QPainter.CompositionMode_SourceOver)
        bp.setFont(font)
        bp.setRenderHint(QPainter.TextAntialiasing, True)

        # 2. step drops and draw new glyphs on the buffer
        for c, d in enumerate(self.drops):
            base_a = self._col_alpha(c)
            if base_a < 0.02:
                d.y += d.speed
                continue
            x = c * self.FONT_SIZE
            # head — bright accent
            head = QColor(accent)
            head.setAlpha(int(255 * 0.85))
            bp.setPen(head)
            bp.drawText(x, int(d.y * self.FONT_SIZE), random.choice(_GLYPHS))
            # trail — fading off-white phosphor
            for i in range(1, d.length):
                a = max(0.0, base_a * (1 - i / d.length))
                trail = QColor(180, 255, 220, int(255 * a))
                bp.setPen(trail)
                bp.drawText(x, int((d.y - i) * self.FONT_SIZE), random.choice(_GLYPHS))
            d.y += d.speed * frame_scale
            if d.y * self.FONT_SIZE > self.H + d.length * self.FONT_SIZE:
                d.y = -random.random() * 20
                d.speed = 0.4 + random.random() * 0.9
                d.length = 6 + random.randint(0, 15)
        bp.end()

    def step_and_paint(self, p: QPainter, font: QFont, accent: QColor) -> None:
        now = time.monotonic()
        step_interval = 1 / self.max_step_hz if self.max_step_hz > 0 else 0
        should_step = self._last_step == 0.0 or step_interval == 0 or (now - self._last_step) >= step_interval
        if should_step:
            elapsed = (now - self._last_step) if self._last_step else (1 / 15)
            frame_scale = max(0.5, min(3.0, elapsed * 15))
            self._step(font, accent, frame_scale)
            self._last_step = now

        # 3. composite onto target painter at 'screen' blend (additive-ish)
        p.save()
        p.setCompositionMode(QPainter.CompositionMode_Screen)
        p.setOpacity(0.42)
        p.drawImage(0, 0, self._buf)
        p.restore()


# ─── grid mask cache ──────────────────────────────────────────────────────


def build_grid_mask(width: int = 1280, height: int = 480, step: int = 32, color: QColor | None = None) -> QImage:
    """Pre-render the 32×32 hairline grid into an alpha-masked QImage.

    Returns an ARGB image with the grid drawn at low alpha and faded toward
    the edges via a radial mask — same effect as the CSS mask-image radial.
    """
    color = color or QColor(41, 255, 140, int(255 * 0.085))
    img = QImage(width, height, QImage.Format_ARGB32_Premultiplied)
    img.fill(0)
    p = QPainter(img)
    p.setRenderHint(QPainter.Antialiasing, False)
    pen = p.pen()
    pen.setColor(color)
    pen.setWidthF(1.0)
    p.setPen(pen)
    for x in range(0, width, step):
        p.drawLine(x, 0, x, height)
    for y in range(0, height, step):
        p.drawLine(0, y, width, y)

    # radial alpha mask — visible at center, fades to transparent at edges
    rg = QRadialGradient(QPointF(width / 2, height * 0.6), width * 0.65)
    rg.setColorAt(0.0, QColor(0, 0, 0, 255))
    rg.setColorAt(0.65, QColor(0, 0, 0, 180))
    rg.setColorAt(1.0, QColor(0, 0, 0, 0))
    p.setCompositionMode(QPainter.CompositionMode_DestinationIn)
    p.fillRect(img.rect(), rg)
    p.end()
    return img


# ─── glow text ────────────────────────────────────────────────────────────


def draw_glow_text(
    p: QPainter,
    x: int,
    y: int,
    text: str,
    font: QFont,
    color: QColor,
    glow_color: QColor,
    *,
    glow_alpha: int = 90,
    glow_radius: int = 4,
) -> int:
    """Draw sharp text. The glow passes were removed because they blurred
    badly on the LCD; signature is preserved so call sites don't churn.
    """
    del glow_color, glow_alpha, glow_radius  # intentionally unused
    fm = QFontMetrics(font)
    adv = fm.horizontalAdvance(text)
    baseline = y + fm.ascent()
    p.save()
    p.setFont(font)
    p.setRenderHint(QPainter.TextAntialiasing, True)
    p.setPen(color)
    p.drawText(x, baseline, text)
    p.restore()
    return adv
