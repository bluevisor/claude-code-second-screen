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

    init(canvasSize: CGSize = MatrixTheme.canvasSize, stepHz: Double = 12) {
        self.canvasSize = canvasSize
        self.stepInterval = 1.0 / max(1, stepHz)
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
        let phosphor = MatrixTheme.phosphor.cgColor
        let font = MatrixTheme.font(11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
        ]
        for col in columns {
            for j in 0..<col.lengthRows {
                let row = col.headRow - j
                if row < 0 { continue }
                let y = CGFloat(row) * glyphHeight
                if y > canvasSize.height + glyphHeight { continue }
                // Head glyph is bright; trail fades.
                let alpha: CGFloat = j == 0 ? 0.9 : max(0.05, 0.5 - CGFloat(j) * 0.045)
                let color = phosphor.copy(alpha: alpha) ?? phosphor
                let glyph = col.glyphs[(row + Int(col.x.truncatingRemainder(dividingBy: 7))) % col.glyphs.count]
                let s = NSAttributedString(string: String(glyph),
                    attributes: attrs.merging([.foregroundColor: NSColor(cgColor: color) ?? .green]) { $1 })
                // CG y-axis is flipped here — caller is in canvas coords.
                drawString(s, at: CGPoint(x: col.x, y: y), in: ctx)
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
