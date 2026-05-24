// Glyph rain — falling katakana columns behind the panels.
//
// Cheaper than matrix_fx.py's version: we draw column strips at a fixed
// rate and let them scroll. State lives in `columns[]`. Each tick advances
// one row regardless of frame rate, so visual speed is decoupled from FPS.

import AppKit
import CoreGraphics

final class RainPainter {
    private struct Column {
        var x: CGFloat
        var headRow: Int
        var lengthRows: Int
        var glyphs: [Character]
    }

    private let canvasSize: CGSize
    private let glyphHeight: CGFloat = 14
    private let glyphWidth: CGFloat = 11
    private var columns: [Column] = []
    private var lastStep: TimeInterval = 0
    private let stepInterval: TimeInterval
    private let glyphAlphabet: [Character] = Array(
        "ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜｦﾝ" +
            "0123456789ABCDEFXYZ"
    )
    /// One CTLine per glyph, baked once at init. The line carries no
    /// foreground color attribute so `CTLineDraw` picks up whatever
    /// `ctx.setFillColor` set just before — letting us vary trail alpha
    /// per row without rebuilding ~1.7k attributed strings per frame.
    private let glyphLines: [Character: CTLine]
    /// Pre-baked trail-alpha colors keyed by row offset from the head.
    private let trailColors: [CGColor]

    init(canvasSize: CGSize = MatrixTheme.canvasSize, stepHz: Double = 12) {
        self.canvasSize = canvasSize
        self.stepInterval = 1.0 / max(1, stepHz)
        // Bake one CTLine per glyph using the rain font without any
        // foreground-color attribute, so CTLineDraw picks up the current
        // ctx fill color and we can vary alpha cheaply per row.
        let font = MatrixTheme.font(11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var lines: [Character: CTLine] = [:]
        for c in glyphAlphabet {
            let s = NSAttributedString(string: String(c), attributes: attrs)
            lines[c] = CTLineCreateWithAttributedString(s)
        }
        self.glyphLines = lines
        // 25 alpha levels covers any realistic trail length.
        self.trailColors = (0..<25).map { j -> CGColor in
            let alpha: CGFloat = j == 0 ? 0.9
                : max(0.05, 0.5 - CGFloat(j) * 0.045)
            return MatrixTheme.phosphor.withAlphaComponent(alpha).cgColor
        }
        let colCount = Int(canvasSize.width / glyphWidth)
        columns = (0..<colCount).map { i in
            Column(x: CGFloat(i) * glyphWidth,
                   headRow: Int.random(in: -40 ..< 0),
                   lengthRows: Int.random(in: 8 ... 22),
                   glyphs: (0..<60).map { _ in
                       self.glyphAlphabet.randomElement()!
                   })
        }
    }

    func draw(into ctx: CGContext, now: TimeInterval) {
        if now - lastStep >= stepInterval {
            step()
            lastStep = now
        }
        ctx.saveGState()
        ctx.textMatrix = .identity
        // Flip once for the whole pass: each glyph draws at (x, baseline)
        // in the flipped frame, then we translate per-glyph.
        let lastTrailIdx = trailColors.count - 1
        for col in columns {
            let xPhase = Int(col.x.truncatingRemainder(dividingBy: 7))
            for j in 0..<col.lengthRows {
                let row = col.headRow - j
                if row < 0 { continue }
                let y = CGFloat(row) * glyphHeight
                if y > canvasSize.height + glyphHeight { continue }
                let glyph = col.glyphs[(row + xPhase) % col.glyphs.count]
                guard let line = glyphLines[glyph] else { continue }
                ctx.setFillColor(trailColors[min(j, lastTrailIdx)])
                ctx.saveGState()
                ctx.translateBy(x: col.x, y: y + 11)
                ctx.scaleBy(x: 1, y: -1)
                ctx.textPosition = .zero
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
        }
        ctx.restoreGState()
    }

    private func step() {
        for i in 0..<columns.count {
            columns[i].headRow += 1
            if CGFloat(columns[i].headRow - columns[i].lengthRows) * glyphHeight > canvasSize.height {
                columns[i].headRow = Int.random(in: -20 ..< 0)
                columns[i].lengthRows = Int.random(in: 8 ... 22)
                columns[i].glyphs = (0..<60).map { _ in glyphAlphabet.randomElement()! }
            }
        }
    }

    private func drawString(_ s: NSAttributedString, at p: CGPoint, in ctx: CGContext) {
        let line = CTLineCreateWithAttributedString(s)
        // Move and flip vertically because Core Text draws from baseline up.
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: p.x, y: p.y + 11)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
