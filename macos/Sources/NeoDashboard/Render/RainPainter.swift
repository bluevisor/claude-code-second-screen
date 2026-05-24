// Glyph rain — falling katakana columns behind the panels.
//
// Cheaper than matrix_fx.py's version: we draw column strips at a fixed
// rate and let them scroll. State lives in `columns[]`. Each tick advances
// one row regardless of frame rate, so visual speed is decoupled from FPS.

import AppKit
import CoreGraphics
import CoreText

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
    /// Half-width katakana (U+FF61–U+FF9F block) rather than full-width
    /// kana. Full-width katakana render roughly twice as wide as the ASCII
    /// digits, so columns mixing the two no longer lined up on the fixed
    /// `glyphWidth` grid — the half-width forms share the digits' advance.
    /// Matches the character widths used by the Matrix-Rain_Terminal
    /// reference project.
    private static let baseAlphabet: [Character] = Array(
        "ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉ" +
            "ﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜｦﾝ0123456789"
    )
    private let glyphAlphabet: [Character]
    private let glitchProbability: Double = 0.01
    /// Font + CGGlyph IDs baked once at init. We draw via
    /// `CTFontDrawGlyphs`, which (unlike `CTLineDraw` with no colour
    /// attribute) actually honours the context's current fill colour —
    /// letting us vary trail alpha per row without rebuilding ~1.7k
    /// attributed strings per frame.
    private let font: CTFont
    private let glyphIDs: [Character: CGGlyph]
    /// Pre-baked trail-alpha colors keyed by row offset from the head.
    private let trailColors: [CGColor]

    init(canvasSize: CGSize = MatrixTheme.canvasSize, stepHz: Double = 12) {
        self.canvasSize = canvasSize
        self.stepInterval = 1.0 / max(1, stepHz)
        let baseFont = Self.rainFont(
            size: MatrixTheme.font(11, weight: .medium).pointSize
        ) as CTFont
        self.font = baseFont
        var ids: [Character: CGGlyph] = [:]
        var usableAlphabet: [Character] = []
        for c in Self.baseAlphabet {
            let utf16 = Array(String(c).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
            CTFontGetGlyphsForCharacters(baseFont, utf16,
                                         &glyphs, utf16.count)
            let glyph = glyphs.first ?? 0
            if glyph != 0 {
                ids[c] = glyph
                usableAlphabet.append(c)
            }
        }
        self.glyphIDs = ids
        self.glyphAlphabet = usableAlphabet.isEmpty ? Array("0123456789") : usableAlphabet
        // 25 alpha levels covers any realistic trail length. The leading
        // glyph (j == 0) is bright near-white so a freshly spawned
        // character pops the instant it appears — like the white head of
        // the Matrix-Rain_Terminal reference. j == 1 is full-strength
        // phosphor, then the tail fades out behind it.
        self.trailColors = (0..<25).map { j -> CGColor in
            switch j {
            case 0:
                return MatrixTheme.ink.cgColor
            case 1:
                return MatrixTheme.phosphor.cgColor
            default:
                let alpha = max(0.05, 0.5 - CGFloat(j) * 0.045)
                return MatrixTheme.phosphor.withAlphaComponent(alpha).cgColor
            }
        }
        let colCount = Int(canvasSize.width / glyphWidth)
        // Stagger initial headRow across the whole lifecycle of a column
        // (from one canvas-height above the top down to the bottom of
        // the canvas) so columns aren't all clustered near the top edge
        // when the rain starts up. Previously this used a narrow
        // `-40 ..< 0` window which barely covered the landscape canvas
        // and was minuscule on the portrait one.
        let canvasRows = max(1, Int(canvasSize.height / glyphHeight))
        columns = (0..<colCount).map { i in
            Column(x: CGFloat(i) * glyphWidth,
                   headRow: Int.random(in: -canvasRows ..< canvasRows),
                   lengthRows: Int.random(in: 8 ... 22),
                   glyphs: self.randomGlyphs(count: 28))
        }
    }

    func draw(into ctx: CGContext, now: TimeInterval) {
        if now - lastStep >= stepInterval {
            step()
            lastStep = now
        }
        ctx.saveGState()
        ctx.textMatrix = .identity
        let lastTrailIdx = trailColors.count - 1
        var glyph: CGGlyph = 0
        let origin = CGPoint.zero
        for col in columns {
            for j in 0..<col.lengthRows {
                let row = col.headRow - j
                if row < 0 { continue }
                let y = CGFloat(row) * glyphHeight
                if y > canvasSize.height + glyphHeight { continue }
                let charKey = col.glyphs[j % col.glyphs.count]
                guard let gid = glyphIDs[charKey], gid != 0 else { continue }
                ctx.setFillColor(trailColors[min(j, lastTrailIdx)])
                ctx.saveGState()
                ctx.translateBy(x: col.x, y: y + 11)
                ctx.scaleBy(x: 1, y: -1)
                glyph = gid
                withUnsafePointer(to: origin) { ptr in
                    CTFontDrawGlyphs(font, &glyph, ptr, 1, ctx)
                }
                ctx.restoreGState()
            }
        }
        ctx.restoreGState()
    }

    private func step() {
        for i in 0..<columns.count {
            columns[i].headRow += 1
            columns[i].glyphs.insert(randomGlyph(), at: 0)
            columns[i].glyphs.removeLast()
            if Double.random(in: 0..<1) < glitchProbability,
               columns[i].glyphs.count > 2 {
                let index = Int.random(in: 2..<columns[i].glyphs.count)
                columns[i].glyphs[index] = randomGlyph()
            }
            if CGFloat(columns[i].headRow - columns[i].lengthRows) * glyphHeight > canvasSize.height {
                // Spread the respawn position across roughly a canvas
                // height worth of rows above the top — otherwise every
                // column that finishes falling re-enters the visible
                // area within a few rows of every other column and the
                // rain re-syncs into uniform vertical bands.
                let canvasRows = max(20, Int(canvasSize.height / glyphHeight))
                columns[i].headRow = Int.random(in: -canvasRows ..< 0)
                columns[i].lengthRows = Int.random(in: 8 ... 22)
                columns[i].glyphs = randomGlyphs(count: 28)
            }
        }
    }

    private func randomGlyphs(count: Int) -> [Character] {
        (0..<count).map { _ in randomGlyph() }
    }

    private func randomGlyph() -> Character {
        glyphAlphabet.randomElement() ?? "0"
    }

    private static func rainFont(size: CGFloat) -> NSFont {
        for name in [
            "HiraginoSans-W3",
            "HiraginoSans-W6",
            "Hiragino Sans W3",
            "Hiragino Sans"
        ] {
            if let font = NSFont(name: name, size: size) {
                return font
            }
        }
        return NSFont.systemFont(ofSize: size, weight: .medium)
    }
}
