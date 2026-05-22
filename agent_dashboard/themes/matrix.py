"""Matrix theme — CRT/terminal aesthetic. 1280×480 fixed canvas.

Recreates matrix.jsx with QPainter. All measurements come from the CSS in
index.html. Color palette and font choices live at the top so they're easy
to tweak.
"""

from __future__ import annotations

import math
from datetime import datetime, timezone

from PySide6.QtCore import QPointF, QRect, QRectF, Qt
from PySide6.QtGui import (
    QBrush,
    QColor,
    QFont,
    QFontMetrics,
    QLinearGradient,
    QPainter,
    QPaintEvent,
    QPen,
    QPolygonF,
    QRadialGradient,
)
from PySide6.QtWidgets import QWidget

from ..telemetry.types import Telemetry
from .matrix_fx import RainPainter, build_grid_mask, draw_glow_text

# ─── palette ──────────────────────────────────────────────────────────────
INK         = QColor(201, 255, 226)
INK_DIM     = QColor(201, 255, 226, int(255 * 0.55))
INK_FAINT   = QColor(201, 255, 226, int(255 * 0.30))
PHOSPHOR    = QColor(41, 255, 140)
PHOSPHOR_SOFT = QColor(41, 255, 140, int(255 * 0.22))
MAGENTA     = QColor(255, 42, 109)
AMBER       = QColor(255, 182, 39)
CYAN        = QColor(42, 240, 255)
PANEL_BORDER = QColor(41, 255, 140, int(255 * 0.22))
BG_TOP      = QColor(2, 16, 12)
BG_BOT      = QColor(1, 9, 10)

STATUS_VERBS = {
    "idle":     "STANDBY",
    "thinking": "THINKING",
    "tool":     "EXECUTING",
    "writing":  "WRITING",
    "error":    "ERROR",
}


def font(size: int, weight: int = QFont.Normal) -> QFont:
    f = QFont("JetBrains Mono", size)
    f.setWeight(weight)
    f.setStyleStrategy(QFont.PreferAntialias)
    return f


def fmt_tok(n: float) -> str:
    if n >= 1_000_000:
        return f"{n/1_000_000:.2f}M"
    if n >= 1000:
        return f"{n/1000:.0f}K"
    return f"{int(round(n))}"


def fmt_dur(secs: float) -> str:
    secs = int(secs)
    d, h = divmod(secs, 86400)[0], (secs % 86400) // 3600
    m, s = (secs % 3600) // 60, secs % 60
    if secs >= 86400:
        return f"{secs // 86400}d{(secs % 86400) // 3600}h"
    if secs >= 3600:
        return f"{secs // 3600}h{(secs % 3600) // 60:02d}m"
    return f"{secs // 60}m{secs % 60:02d}s"


def pct_class_color(headroom_pct: float) -> QColor:
    """headroom_pct = 100 - usage_pct. Mirrors pctClass() in helpers.jsx."""
    if headroom_pct < 10:
        return MAGENTA
    if headroom_pct < 25:
        return AMBER
    return PHOSPHOR


class MatrixThemeWidget(QWidget):
    def __init__(self, tel: Telemetry, parent: QWidget | None = None):
        super().__init__(parent)
        self.tel = tel
        self.setFixedSize(1280, 480)
        self.setAttribute(Qt.WA_OpaquePaintEvent, True)
        # blink phase advanced by the app on each render — drives caret, scan, rotation
        self.blink = 0.0
        self.rain = RainPainter()
        self.show_rain = True
        # pre-rendered, radial-masked grid (built once)
        self._grid = build_grid_mask()
        # cached scratch for status verb's glow (rebuilt on demand)
        self._verb_glow: QImage | None = None

    def update_tel(self, tel: Telemetry) -> None:
        self.tel = tel
        self.update()

    # ── helpers ──────────────────────────────────────────────────────────

    def _paint_bg(self, p: QPainter) -> None:
        # main linear gradient
        grad = QLinearGradient(0, 0, 0, 480)
        grad.setColorAt(0, BG_TOP)
        grad.setColorAt(1, BG_BOT)
        p.fillRect(self.rect(), grad)

        # bottom-center phosphor glow
        rg = QRadialGradient(QPointF(640, 530), 700)
        rg.setColorAt(0, QColor(41, 255, 140, int(255 * 0.10)))
        rg.setColorAt(0.6, QColor(41, 255, 140, 0))
        p.fillRect(self.rect(), rg)

        # top-right magenta tint
        rg2 = QRadialGradient(QPointF(1280, 0), 800)
        rg2.setColorAt(0, QColor(255, 42, 109, int(255 * 0.07)))
        rg2.setColorAt(0.7, QColor(255, 42, 109, 0))
        p.fillRect(self.rect(), rg2)

        # radial-masked hairline grid (pre-rendered, just blit)
        p.drawImage(0, 0, self._grid)

        # glyph rain — Screen blend underneath the panels
        if self.show_rain:
            self.rain.step_and_paint(p, font(11, QFont.Medium), PHOSPHOR)

    def _draw_scanlines(self, p: QPainter, opacity: float = 0.55) -> None:
        col = QColor(0, 0, 0, int(255 * 0.16 * opacity))
        p.setPen(Qt.NoPen)
        p.setBrush(col)
        for y in range(0, 480, 3):
            p.drawRect(0, y + 2, 1280, 1)
        # vignette
        rg = QRadialGradient(QPointF(640, 240), 720)
        rg.setColorAt(0.6, QColor(0, 0, 0, 0))
        rg.setColorAt(1.0, QColor(0, 0, 0, int(255 * 0.85)))
        p.fillRect(self.rect(), rg)

    def _draw_panel(self, p: QPainter, r: QRect) -> None:
        # background gradient — mostly opaque so the rain doesn't bleed through
        bg = QLinearGradient(0, r.top(), 0, r.bottom())
        bg.setColorAt(0, QColor(8, 22, 18, int(255 * 0.97)))
        bg.setColorAt(1, QColor(4, 12, 10, int(255 * 0.94)))
        p.fillRect(r, bg)
        # subtle inner phosphor sheen (top-left → bottom-right)
        sheen = QLinearGradient(r.left(), r.top(), r.right(), r.bottom())
        sheen.setColorAt(0, QColor(41, 255, 140, 12))
        sheen.setColorAt(1, QColor(0, 0, 0, 0))
        p.fillRect(r, sheen)

        # border
        p.setPen(QPen(PANEL_BORDER, 1))
        p.setBrush(Qt.NoBrush)
        p.drawRect(r.adjusted(0, 0, -1, -1))

        # corner brackets — 10px L-shapes on all 4 corners
        bp = QPen(PHOSPHOR, 1)
        bp.setCapStyle(Qt.SquareCap)
        p.setPen(bp)
        L = 10
        # TL
        p.drawLine(r.left(), r.top(), r.left() + L, r.top())
        p.drawLine(r.left(), r.top(), r.left(), r.top() + L)
        # TR
        p.drawLine(r.right() - L, r.top(), r.right(), r.top())
        p.drawLine(r.right(), r.top(), r.right(), r.top() + L)
        # BL
        p.drawLine(r.left(), r.bottom() - L, r.left(), r.bottom())
        p.drawLine(r.left(), r.bottom(), r.left() + L, r.bottom())
        # BR
        p.drawLine(r.right() - L, r.bottom(), r.right(), r.bottom())
        p.drawLine(r.right(), r.bottom() - L, r.right(), r.bottom())

    def _draw_track(self, p: QPainter, r: QRectF, fill_pct: float, color: QColor, glow: bool = True, scan: bool = False) -> None:
        # background track
        p.setPen(QPen(PANEL_BORDER, 1))
        p.setBrush(QColor(41, 255, 140, int(255 * 0.08)))
        p.drawRect(r.adjusted(0, 0, -1, -1))
        # fill
        if fill_pct > 0:
            fw = r.width() * max(0, min(100, fill_pct)) / 100
            fr = QRectF(r.left() + 1, r.top() + 1, fw - 2, r.height() - 2)
            if fw > 2:
                if glow and color == PHOSPHOR:
                    grad = QLinearGradient(fr.left(), 0, fr.right(), 0)
                    grad.setColorAt(0, PHOSPHOR)
                    grad.setColorAt(1, CYAN)
                    p.setBrush(grad)
                else:
                    p.setBrush(color)
                p.setPen(Qt.NoPen)
                p.drawRect(fr)
                # phosphor halo above/below the fill (cheap glow)
                if glow:
                    halo = QColor(color)
                    halo.setAlpha(60)
                    p.setBrush(halo)
                    p.drawRect(QRectF(fr.left(), fr.top() - 2, fr.width(), 2))
                    p.drawRect(QRectF(fr.left(), fr.bottom(), fr.width(), 2))
        # animated scan highlight — sweeps across the full track width
        if scan:
            sweep_x = ((self.blink * 0.5) % 1.0) * (r.width() + 30) - 30
            band = QRectF(r.left() + sweep_x, r.top() + 1, 30, r.height() - 2)
            grad = QLinearGradient(band.left(), 0, band.right(), 0)
            grad.setColorAt(0, QColor(255, 255, 255, 0))
            grad.setColorAt(0.5, QColor(255, 255, 255, 90))
            grad.setColorAt(1, QColor(255, 255, 255, 0))
            p.setPen(Qt.NoPen)
            p.setBrush(grad)
            # clip to track interior
            p.save()
            p.setClipRect(r.adjusted(1, 1, -1, -1))
            p.drawRect(band)
            p.restore()

    def _text(self, p: QPainter, x: int, y: int, s: str, f: QFont, c: QColor, align: int = Qt.AlignLeft | Qt.AlignTop, w: int = 0) -> int:
        """Draw text and return its drawn width."""
        p.setFont(f)
        p.setPen(c)
        fm = QFontMetrics(f)
        adv = fm.horizontalAdvance(s)
        if align & Qt.AlignRight and w:
            x = x + w - adv
        elif align & Qt.AlignHCenter and w:
            x = x + (w - adv) // 2
        # Qt baseline: y is top here, shift down by ascent
        p.drawText(x, y + fm.ascent(), s)
        return adv

    def _elide(self, s: str, f: QFont, max_w: int) -> str:
        fm = QFontMetrics(f)
        if fm.horizontalAdvance(s) <= max_w:
            return s
        # ellipsize
        e = "…"
        while s and fm.horizontalAdvance(s + e) > max_w:
            s = s[:-1]
        return s + e

    # ── top rail ─────────────────────────────────────────────────────────

    def _draw_rail(self, p: QPainter, r: QRect) -> None:
        a = self.tel.agent
        m = self.tel.model
        src = self.tel.source
        cx = r.left()
        cy = r.top() + (r.height() - 12) // 2  # baseline-ish

        # LED
        led_color = MAGENTA if a.status == "error" else (AMBER if a.status == "idle" else PHOSPHOR)
        p.setPen(Qt.NoPen)
        p.setBrush(QColor(led_color.red(), led_color.green(), led_color.blue(), 90))
        p.drawEllipse(QRectF(cx - 4, cy - 4, 18, 18))
        p.setBrush(led_color)
        p.drawEllipse(QRectF(cx, cy, 10, 10))
        cx += 22

        # agent label (bold, 14px)
        f = font(13, QFont.Bold)
        from .matrix import AGENT_LABEL_MAP as _  # noqa: F401 — placeholder to silence

        agent_label = (a.kind or "agent").upper().replace("-", " ")
        adv = self._text(p, cx, r.top() + 9, agent_label, f, INK)
        cx += adv + 12

        # chip: cwd
        cx += self._draw_chip(p, cx, r.top() + 6, a.cwd) + 8
        # chip: branch
        branch_text = f"⎇ {a.git_branch}" + ("●" if a.git_dirty else "")
        cx += self._draw_chip(p, cx, r.top() + 6, branch_text) + 8
        # session id
        sess = f"SESS {a.session_id}"
        ff = font(11, QFont.Normal)
        cx += self._text(p, cx, r.top() + 9, sess, ff, INK_FAINT) + 12

        # right side: src badge + date + provider chip
        # date YYYY.MM.DD
        d = datetime.now()
        date_str = f"{d.year:04d}.{d.month:02d}.{d.day:02d}"
        # provider chip on far right
        prov_text = m.provider.upper()
        prov_w = self._chip_width(prov_text)
        right_x = r.right() - prov_w
        self._draw_chip(p, right_x, r.top() + 6, prov_text)

        # date to the left of provider
        date_f = font(11, QFont.Normal)
        date_w = QFontMetrics(date_f).horizontalAdvance(date_str)
        right_x -= date_w + 12
        self._text(p, right_x, r.top() + 9, date_str, date_f, INK_DIM)

        # source badge before date
        src_label = src
        src_color = PHOSPHOR if src == "LIVE" else (AMBER if src == "STALE" else INK_FAINT)
        src_w = self._chip_width(src_label, font_=font(11, QFont.Bold))
        # include leading dot ~14px
        right_x -= (src_w + 14 + 8)
        # pulsing dot
        pulse = 0.55 + 0.45 * (math.sin(self.blink * math.pi * 1.6) * 0.5 + 0.5)
        halo = QColor(src_color)
        halo.setAlpha(int(160 * pulse) if src == "LIVE" else 0)
        if halo.alpha() > 0:
            p.save()
            p.setCompositionMode(QPainter.CompositionMode_Plus)
            p.setPen(Qt.NoPen)
            p.setBrush(halo)
            p.drawEllipse(QRectF(right_x + 1, r.top() + 7, 17, 17))
            p.restore()
        p.setPen(Qt.NoPen)
        p.setBrush(src_color)
        p.drawEllipse(QRectF(right_x + 6, r.top() + 12, 7, 7))
        # chip box
        self._draw_chip(p, right_x + 17, r.top() + 6, src_label, color=src_color, font_=font(11, QFont.Bold))

        # separator — gradient line between left cluster and right cluster
        sep_left = cx + 4
        sep_right = right_x - 8
        if sep_right > sep_left:
            sep_grad = QLinearGradient(sep_left, 0, sep_right, 0)
            sep_grad.setColorAt(0.0, QColor(41, 255, 140, 0))
            sep_grad.setColorAt(0.5, QColor(41, 255, 140, int(255 * 0.30)))
            sep_grad.setColorAt(1.0, QColor(41, 255, 140, 0))
            p.setPen(Qt.NoPen)
            p.setBrush(sep_grad)
            p.drawRect(QRectF(sep_left, r.top() + 17, sep_right - sep_left, 1))

    def _chip_width(self, text: str, font_: QFont | None = None) -> int:
        f = font_ or font(11, QFont.Normal)
        fm = QFontMetrics(f)
        return fm.horizontalAdvance(text) + 18  # 9px padding each side

    def _draw_chip(self, p: QPainter, x: int, y: int, text: str, color: QColor = None, font_: QFont | None = None) -> int:
        f = font_ or font(11, QFont.Normal)
        fm = QFontMetrics(f)
        w = fm.horizontalAdvance(text) + 16
        h = 22
        p.setPen(QPen(PANEL_BORDER, 1))
        p.setBrush(Qt.NoBrush)
        p.drawRect(x, y, w, h)
        self._text(p, x + 8, y + 5, text, f, color or INK_DIM)
        return w

    # ── agent panel (left) ───────────────────────────────────────────────

    def _draw_agent_panel(self, p: QPainter, r: QRect) -> None:
        self._draw_panel(p, r)
        a = self.tel.agent
        cx = r.left() + 16
        cy = r.top() + 14

        # title row
        title_text = "▸ AGENT  ·  SESSION"
        tf = font(12, QFont.Bold)
        title_w = self._text(p, cx, cy, title_text, tf, PHOSPHOR)
        # meta to the right; clamp so it never crosses the title
        started_ts = datetime.fromisoformat(a.started_at.replace("Z", "+00:00")).timestamp()
        dur = max(0, int(datetime.now(timezone.utc).timestamp() - started_ts))
        meta = f"TURN {a.turn} · {fmt_dur(dur)} · {a.files_read}R/{a.files_edited}W"
        f = font(10)
        fm = QFontMetrics(f)
        max_meta_w = (r.right() - 16) - (cx + title_w + 12)
        meta = self._elide(meta, f, max_meta_w)
        self._text(p, r.right() - 16 - fm.horizontalAdvance(meta), cy + 2, meta, f, INK_FAINT)

        cy += 24

        # status verb (big, with phosphor glow)
        verb = STATUS_VERBS.get(a.status, a.status.upper())
        vf = font(34, QFont.ExtraBold)
        adv = draw_glow_text(p, cx, cy, verb, vf, PHOSPHOR, PHOSPHOR_SOFT, glow_alpha=70, glow_radius=5)
        # blinking caret (skip when idle)
        if a.status != "idle":
            blink_on = (self.blink % 1.0) < 0.5
            if blink_on:
                caret = QRectF(cx + adv + 6, cy + 6, 13, 28)
                p.fillRect(caret, PHOSPHOR)
                # faint outer halo
                p.save()
                p.setCompositionMode(QPainter.CompositionMode_Plus)
                p.setPen(Qt.NoPen)
                p.setBrush(QColor(41, 255, 140, 30))
                p.drawRect(caret.adjusted(-3, -2, 3, 2))
                p.restore()
        cy += 42

        # current task
        task_text = a.current_task
        max_w = r.width() - 32 - 14
        elided = self._elide(task_text, font(14), max_w)
        self._text(p, cx, cy, "▸", font(14, QFont.Bold), PHOSPHOR)
        self._text(p, cx + 14, cy, elided, font(14), INK)
        cy += 22
        # detail line
        detail_parts = []
        if a.current_tool:
            detail_parts.append(f"{a.current_tool}( … )")
        detail_parts.append(a.detail)
        detail = "  ".join(detail_parts)
        self._text(p, cx + 14, cy, self._elide(detail, font(11), max_w - 14), font(11), INK_FAINT)
        cy += 22

        # progress bar with sweeping scan highlight
        bar_rect = QRectF(cx, cy, r.width() - 32, 6)
        self._draw_track(p, bar_rect, a.progress, PHOSPHOR, scan=True)
        cy += 18

        # log rows (newest at top — column-reverse means index 0 is at bottom in JSX,
        # but our painter draws top-down; index 0 is most recent and at the top.)
        log_area_top = cy
        log_area_bot = r.bottom() - 12
        row_h = 17
        max_rows = max(0, (log_area_bot - log_area_top) // row_h)
        for i, row in enumerate(self.tel.agent.log[:max_rows]):
            ry = log_area_top + i * row_h
            self._text(p, cx, ry, row.ts, font(11), INK_FAINT)
            tag_color = {"ok": PHOSPHOR, "warn": AMBER, "err": MAGENTA, "info": CYAN}.get(row.tag, INK_DIM)
            tag_glyph = {"ok": "✓", "warn": "!", "err": "✗", "info": "·"}.get(row.tag, "·")
            self._text(p, cx + 75, ry, tag_glyph, font(11, QFont.Bold), tag_color)
            msg = self._elide(row.msg, font(11), r.width() - 32 - 96)
            self._text(p, cx + 96, ry, msg, font(11), INK)

    # ── model panel (middle) ─────────────────────────────────────────────

    def _draw_model_panel(self, p: QPainter, r: QRect) -> None:
        self._draw_panel(p, r)
        m = self.tel.model
        cx = r.left() + 16
        cy = r.top() + 14

        # title + model id (truncated)
        self._text(p, cx, cy, "▸ MODEL  ·  ACTIVE", font(12, QFont.Bold), PHOSPHOR)
        f = font(11)
        fm = QFontMetrics(f)
        id_text = self._elide(m.id, f, int(r.width() * 0.45))
        self._text(p, r.right() - 16 - fm.horizontalAdvance(id_text), cy, id_text, f, INK_FAINT)

        cy += 22

        # modhead: name + sub on left, badge on right. Left column shares row
        # with the 62×62 badge, so it must clip to (width - 62 - 14).
        modhead_top = cy
        badge_x = r.right() - 16 - 62
        self._draw_model_badge(p, QRectF(badge_x, modhead_top, 62, 62))
        left_w = r.width() - 32 - 62 - 14

        name_f = font(22, QFont.ExtraBold)
        # Compose name + v-pill within left_w. Elide name if needed.
        v_text = f"v{m.version}"
        vf = font(10, QFont.Bold)
        vfm = QFontMetrics(vf)
        v_w_pill = vfm.horizontalAdvance(v_text) + 14
        name_max = left_w - v_w_pill - 8
        name_disp = self._elide(m.name, name_f, name_max)
        nw = draw_glow_text(p, cx, cy, name_disp, name_f, INK, PHOSPHOR_SOFT, glow_alpha=55, glow_radius=4)
        p.setPen(Qt.NoPen)
        p.setBrush(PHOSPHOR)
        p.drawRect(cx + nw + 8, cy + 8, v_w_pill, 18)
        self._text(p, cx + nw + 8 + 7, cy + 11, v_text, vf, QColor(2, 24, 15))
        cy += 32

        # sub-line below the name, still inside left column
        sub = f"{m.provider.upper()}  ·  P50 {int(m.p50_ms)}MS  ·  P95 {int(m.p95_ms)}MS  ·  LAST {int(m.last_request_ms)}MS"
        self._text(p, cx, cy, self._elide(sub, font(11), left_w), font(11), INK_DIM)
        # advance past badge bottom
        cy = modhead_top + 62 + 14

        # specs grid 2×2
        spec_w = (r.width() - 32 - 12) // 2
        spec_h = 42
        specs = [
            ("CONTEXT WINDOW", f"{int(m.context_max/1000)}K", "tok"),
            ("TOKENS IN · OUT", f"{fmt_tok(m.input_tokens)} / {fmt_tok(m.output_tokens)}", ""),
            ("CACHE READ", f"{m.cache_read_tokens/1e6:.2f}M", "tok"),
            ("CACHE HIT", f"{(m.cache_read_tokens / max(m.cache_read_tokens + m.input_tokens, 1)) * 100:.1f}", "%"),
        ]
        for i, (k, v, u) in enumerate(specs):
            col = i % 2
            row = i // 2
            sx = cx + col * (spec_w + 12)
            sy = cy + row * (spec_h + 7)
            # background + border
            p.setPen(QPen(PANEL_BORDER, 1))
            p.setBrush(QColor(2, 16, 12, int(255 * 0.45)))
            p.drawRect(sx, sy, spec_w, spec_h)
            self._text(p, sx + 9, sy + 7, k, font(10, QFont.Bold), INK_FAINT)
            vf = font(16, QFont.Bold)
            uf = font(11)
            vw = self._text(p, sx + 9, sy + 22, v, vf, INK)
            if u:
                self._text(p, sx + 9 + vw + 3, sy + 27, u, uf, INK_DIM)
        cy += 2 * (spec_h + 7) + 4

        # context bar
        ctx_pct = max(0.0, min(100.0, (m.context_used / max(m.context_max, 1)) * 100))
        ctx_color = MAGENTA if ctx_pct > 90 else AMBER if ctx_pct > 75 else PHOSPHOR
        self._text(p, cx, cy, "CONTEXT", font(11), INK_DIM)
        right_text = f"{fmt_tok(m.context_used)} / {fmt_tok(m.context_max)} · {ctx_pct:.1f}%"
        rf = font(11)
        rfm = QFontMetrics(rf)
        self._text(p, r.right() - 16 - rfm.horizontalAdvance(right_text), cy, right_text, rf, INK)
        cy += 16
        self._draw_track(p, QRectF(cx, cy, r.width() - 32, 7), ctx_pct, ctx_color)

    def _draw_model_badge(self, p: QPainter, r: QRectF) -> None:
        # outer border
        p.setPen(QPen(PANEL_BORDER, 1))
        p.setBrush(Qt.NoBrush)
        p.drawRect(r)
        # radial soft glow
        cx, cy = r.center().x(), r.center().y()
        rg = QRadialGradient(QPointF(cx, cy), r.width() / 2)
        rg.setColorAt(0, PHOSPHOR_SOFT)
        rg.setColorAt(1, QColor(0, 0, 0, 0))
        p.fillRect(r, rg)
        # dashed inner circle, rotated by blink
        angle = (self.blink * 45) % 360
        p.save()
        p.translate(cx, cy)
        p.rotate(angle)
        dash = QPen(QColor(41, 255, 140, int(255 * 0.6)), 1, Qt.DashLine)
        p.setPen(dash)
        p.setBrush(Qt.NoBrush)
        p.drawEllipse(QPointF(0, 0), r.width() / 2 - 8, r.height() / 2 - 8)
        p.restore()
        # central glyph
        gf = font(20, QFont.ExtraBold)
        p.setFont(gf)
        p.setPen(PHOSPHOR)
        fm = QFontMetrics(gf)
        s = "Σ"
        p.drawText(QPointF(cx - fm.horizontalAdvance(s) / 2, cy + fm.ascent() / 2 - 2), s)

    # ── quota panel (right) ──────────────────────────────────────────────

    def _draw_quota_panel(self, p: QPainter, r: QRect) -> None:
        self._draw_panel(p, r)
        q = self.tel.quota
        s = self.tel.server
        cx = r.left() + 16
        cy = r.top() + 14

        self._text(p, cx, cy, "▸ QUOTA", font(12, QFont.Bold), PHOSPHOR)
        # plan pill on right
        plan_f = font(10, QFont.Bold)
        pfm = QFontMetrics(plan_f)
        pw = pfm.horizontalAdvance(q.plan) + 16
        ph = 18
        p.setPen(Qt.NoPen)
        p.setBrush(PHOSPHOR)
        p.drawRect(r.right() - 16 - pw, cy, pw, ph)
        self._text(p, r.right() - 16 - pw + 8, cy + 4, q.plan, plan_f, QColor(2, 20, 13))
        cy += 24

        # quota windows
        for w in q.windows:
            pct = max(0.0, min(100.0, (w.used / max(w.cap, 1)) * 100))
            color = pct_class_color(100 - pct)
            self._text(p, cx, cy + 2, f"{w.label} WINDOW", font(10, QFont.Bold), INK_FAINT)
            vals = f"{fmt_tok(w.used)} / {fmt_tok(w.cap)}"
            vf = font(11, QFont.Bold)
            vfm = QFontMetrics(vf)
            pct_text = f"  {int(pct)}%"
            pfm2 = QFontMetrics(font(11, QFont.Bold))
            total_w = vfm.horizontalAdvance(vals) + pfm2.horizontalAdvance(pct_text)
            self._text(p, r.right() - 16 - total_w, cy, vals, vf, INK)
            self._text(p, r.right() - 16 - pfm2.horizontalAdvance(pct_text), cy, pct_text, font(11, QFont.Bold), color)
            cy += 18
            self._draw_track(p, QRectF(cx, cy, r.width() - 32, 7), pct, color)
            cy += 11
            # foot: resets + cost
            self._text(p, cx, cy, f"resets {fmt_dur(w.reset_in_sec)}", font(10), INK_FAINT)
            cost_text = f"${w.cost_usd:.2f} spent"
            cfm = QFontMetrics(font(10))
            self._text(p, r.right() - 16 - cfm.horizontalAdvance(cost_text), cy, cost_text, font(10), INK_FAINT)
            cy += 16

        # server load section
        cy += 4
        # dashed top border
        pen = QPen(QColor(41, 255, 140, int(255 * 0.18)), 1, Qt.DashLine)
        p.setPen(pen)
        p.drawLine(cx, cy, r.right() - 16, cy)
        cy += 6

        # SERVER LOAD header + status pill
        self._text(p, cx, cy, "SERVER LOAD", font(11, QFont.Bold), INK_FAINT)
        srv_color = PHOSPHOR if s.status == "operational" else (AMBER if s.status == "degraded" else MAGENTA)
        srv_text = f"{s.provider_label} · {s.status.upper()}"
        sf = font(10, QFont.Bold)
        sfm = QFontMetrics(sf)
        # dot + text
        text_w = sfm.horizontalAdvance(srv_text)
        sx = r.right() - 16 - text_w
        p.setPen(Qt.NoPen)
        p.setBrush(srv_color)
        p.drawEllipse(QRectF(sx - 12, cy + 4, 7, 7))
        self._text(p, sx, cy, srv_text, sf, srv_color)
        cy += 18

        # tok/min and req/min meters
        tok_used = s.tokens_limit_min - s.tokens_remaining_min
        req_used = s.requests_limit_min - s.requests_remaining_min
        tok_pct = max(0.0, min(100.0, tok_used / max(s.tokens_limit_min, 1) * 100))
        req_pct = max(0.0, min(100.0, req_used / max(s.requests_limit_min, 1) * 100))

        for label, used, total, pct in [("TOK/MIN", tok_used, s.tokens_limit_min, tok_pct), ("REQ/MIN", req_used, s.requests_limit_min, req_pct)]:
            color = pct_class_color(100 - pct)
            self._text(p, cx, cy, label, font(10, QFont.Bold), INK_FAINT)
            track_x = cx + 64
            track_w = r.width() - 32 - 64 - 90
            self._draw_track(p, QRectF(track_x, cy + 2, track_w, 7), pct, color)
            val_text = f"{fmt_tok(used)} / {fmt_tok(total)}"
            vfm = QFontMetrics(font(11, QFont.Bold))
            self._text(p, r.right() - 16 - vfm.horizontalAdvance(val_text), cy, val_text, font(11, QFont.Bold), INK)
            cy += 14

        # foot row
        cy += 4
        retries_color = AMBER if s.retries_hour > 0 else INK
        errors_color = MAGENTA if s.errors_hour > 0 else INK
        foot_text = f"resets {fmt_dur(s.reset_in_sec)}    retries/hr {s.retries_hour}    errors/hr {s.errors_hour}    inflight {s.queued_requests}"
        self._text(p, cx, cy, self._elide(foot_text, font(10), r.width() - 32), font(10), INK_FAINT)

    # ── footer ───────────────────────────────────────────────────────────

    def _draw_footer(self, p: QPainter, r: QRect) -> None:
        now = datetime.now()
        m = self.tel.model
        q = self.tel.quota
        # left stats
        left_text_parts = [
            (f"{int(m.last_request_ms)}", "ms last"),
            ("P95 ", f"{int(m.p95_ms)}ms"),
            ("CACHE ", f"{int((m.cache_read_tokens / max(m.cache_read_tokens + m.input_tokens, 1)) * 100)}%"),
        ]
        lx = r.left() + 16
        ly = r.center().y() - 8
        for a_text, b_text in left_text_parts:
            adv = self._text(p, lx, ly, a_text, font(13, QFont.Bold), PHOSPHOR)
            lx += adv + 3
            adv = self._text(p, lx, ly, b_text, font(13), INK_DIM)
            lx += adv + 18

        # clock (center)
        hh = f"{now.hour:02d}"
        mm = f"{now.minute:02d}"
        ss = f"{now.second:02d}"
        clock_f = font(36, QFont.ExtraBold)
        cfm = QFontMetrics(clock_f)
        # build manually to color the seconds in phosphor
        col_blink = ":" if (self.blink % 1.0) < 0.5 else " "
        # measure widths
        h_w = cfm.horizontalAdvance(hh)
        c_w = cfm.horizontalAdvance(col_blink)
        m_w = cfm.horizontalAdvance(mm)
        c2_w = cfm.horizontalAdvance(col_blink)
        s_w = cfm.horizontalAdvance(ss)
        total = h_w + c_w + m_w + c2_w + s_w
        x = r.center().x() - total // 2
        y = r.center().y() - cfm.height() // 2
        draw_glow_text(p, x, y, hh, clock_f, INK, PHOSPHOR_SOFT, glow_alpha=60, glow_radius=4); x += h_w
        draw_glow_text(p, x, y, col_blink, clock_f, INK, PHOSPHOR_SOFT, glow_alpha=60, glow_radius=4); x += c_w
        draw_glow_text(p, x, y, mm, clock_f, INK, PHOSPHOR_SOFT, glow_alpha=60, glow_radius=4); x += m_w
        draw_glow_text(p, x, y, col_blink, clock_f, INK, PHOSPHOR_SOFT, glow_alpha=60, glow_radius=4); x += c2_w
        draw_glow_text(p, x, y, ss, clock_f, PHOSPHOR, PHOSPHOR_SOFT, glow_alpha=80, glow_radius=5)

        # right stats
        day = now.strftime("%A").upper()
        off = -datetime.now().astimezone().utcoffset().total_seconds() / 60
        sign = "+" if off >= 0 else "-"
        absm = int(abs(off))
        tz = f"UTC{sign}{absm // 60:02d}:{absm % 60:02d}"
        # 5H cost
        cost = q.windows[0].cost_usd if q.windows else 0.0
        cost_text = f"5H  ${cost:.2f}"
        rf = font(13)
        rfm = QFontMetrics(rf)
        # right-align
        rx = r.right() - 16
        # cost first (rightmost)
        cw = rfm.horizontalAdvance(cost_text)
        self._text(p, rx - cw, ly, cost_text, font(13, QFont.Bold), PHOSPHOR)
        rx -= cw + 16
        tw = rfm.horizontalAdvance(tz)
        self._text(p, rx - tw, ly, tz, rf, INK_DIM)
        rx -= tw + 16
        dw = rfm.horizontalAdvance(day)
        self._text(p, rx - dw, ly, day, rf, INK_DIM)

    # ── main paint ───────────────────────────────────────────────────────

    def paintEvent(self, ev: QPaintEvent) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing, True)
        p.setRenderHint(QPainter.TextAntialiasing, True)

        self._paint_bg(p)

        # frame padding 14 vertical, 18 horizontal
        pad_x, pad_y = 18, 14
        frame_w = 1280 - 2 * pad_x
        frame_h = 480 - 2 * pad_y
        # rail 34, gap 10, main flex, gap 10, footer 64
        rail_h = 34
        footer_h = 64
        main_h = frame_h - rail_h - footer_h - 20  # two 10px gaps

        rail_rect = QRect(pad_x, pad_y, frame_w, rail_h)
        main_top = pad_y + rail_h + 10
        main_rect = QRect(pad_x, main_top, frame_w, main_h)
        footer_rect = QRect(pad_x, main_top + main_h + 10, frame_w, footer_h)

        self._draw_rail(p, rail_rect)

        # 3-col grid: 400 / mid / 400, gaps 14
        gap = 14
        col_l_w = 400
        col_r_w = 400
        col_m_w = frame_w - col_l_w - col_r_w - 2 * gap
        agent_rect = QRect(main_rect.left(), main_rect.top(), col_l_w, main_rect.height())
        model_rect = QRect(main_rect.left() + col_l_w + gap, main_rect.top(), col_m_w, main_rect.height())
        quota_rect = QRect(main_rect.right() - col_r_w + 1, main_rect.top(), col_r_w, main_rect.height())

        self._draw_agent_panel(p, agent_rect)
        self._draw_model_panel(p, model_rect)
        self._draw_quota_panel(p, quota_rect)

        self._draw_footer(p, footer_rect)

        # scanlines on top
        self._draw_scanlines(p, opacity=0.55)


# placeholder map referenced above (kept so the import doesn't fail if we
# later split agent label resolution out)
AGENT_LABEL_MAP: dict[str, str] = {}
