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
    /// Cached rendering of the current column state, reused between
    /// `step()` calls. Only populated when `useCache` is true.
    private var cachedFrame: CGImage?
    /// Whether the offscreen cache is worth keeping. It pays off when
    /// the rain steps meaningfully slower than the host renders — every
    /// "between-step" draw becomes a cheap image stamp. When `stepHz`
    /// matches the draw rate, every draw triggers a step → the cache
    /// invalidates every frame and the offscreen ctx alloc + makeImage
    /// becomes pure overhead vs. painting glyphs directly. The 20 Hz
    /// threshold assumes the host loop runs at 30 fps.
    private let useCache: Bool
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
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

    init(canvasSize: CGSize = MatrixTheme.canvasSize, stepHz: Double = 30) {
        self.canvasSize = canvasSize
        self.stepInterval = 1.0 / max(1, stepHz)
        self.useCache = stepHz < 20
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
            cachedFrame = nil
            lastStep = now
        }
        guard useCache else {
            // Step rate is at or near draw rate — the cache would
            // invalidate every frame anyway. Paint directly into ctx so
            // we avoid the offscreen alloc + makeImage round-trip.
            // P2's batched-by-color CTFontDrawGlyphs still applies.
            paintGlyphs(into: ctx)
            return
        }
        // Reuse the cache when the column state hasn't changed since the
        // last step — same pixels, no glyph drawing. ctx is y-flipped
        // (screen coords); the cache is rendered in the same flipped
        // frame, so we counter-flip locally to stamp it upright.
        if cachedFrame == nil { cachedFrame = renderCache() }
        guard let img = cachedFrame else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: canvasSize.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0,
                                 width: canvasSize.width,
                                 height: canvasSize.height))
        ctx.restoreGState()
    }

    /// Builds a fresh cache image of the current column state. The
    /// offscreen context applies the same y-flip the main render ctx
    /// has so the inner glyph-paint code keeps using screen coords.
    private func renderCache() -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: Int(canvasSize.width), height: Int(canvasSize.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.translateBy(x: 0, y: canvasSize.height)
        ctx.scaleBy(x: 1, y: -1)
        paintGlyphs(into: ctx)
        return ctx.makeImage()
    }

    /// Paint every visible glyph into a y-flipped context (screen
    /// coords). Glyphs are grouped by trail-color index so each color
    /// is drawn in one `CTFontDrawGlyphs` call instead of one call per
    /// glyph — eliminating ~2,600 `saveGState/restoreGState/translate/
    /// scale` cycles on a busy portrait canvas.
    ///
    /// Position math: the outer ctx is y-flipped (screen coords).
    /// `scaleBy(x: 1, y: -1)` once at the start converts the local
    /// frame to y-up so CTFontDrawGlyphs draws glyphs upright; a
    /// per-glyph baseline in screen-coord `(col.x, y + 11)` becomes
    /// `(col.x, -(y + 11))` in that y-up frame.
    private func paintGlyphs(into ctx: CGContext) {
        let lastTrailIdx = trailColors.count - 1
        // Pre-allocate per-color buckets; reused across runs would be
        // ideal but `paintGlyphs` runs at the step rate (~12 Hz) so
        // per-call allocation is fine.
        var glyphsByColor: [[CGGlyph]] = Array(repeating: [], count: trailColors.count)
        var posByColor: [[CGPoint]] = Array(repeating: [], count: trailColors.count)
        // Rough upper bound: every column contributes its full
        // lengthRows worth of glyphs. Hint capacity so the per-color
        // arrays don't repeatedly realloc as we append.
        let estimatedPerColor = max(8, columns.count * 2 / trailColors.count)
        for i in 0..<trailColors.count {
            glyphsByColor[i].reserveCapacity(estimatedPerColor)
            posByColor[i].reserveCapacity(estimatedPerColor)
        }

        for col in columns {
            for j in 0..<col.lengthRows {
                let row = col.headRow - j
                if row < 0 { continue }
                let y = CGFloat(row) * glyphHeight
                if y > canvasSize.height + glyphHeight { continue }
                let charKey = col.glyphs[j % col.glyphs.count]
                guard let gid = glyphIDs[charKey], gid != 0 else { continue }
                let idx = min(j, lastTrailIdx)
                glyphsByColor[idx].append(gid)
                posByColor[idx].append(CGPoint(x: col.x, y: -(y + 11)))
            }
        }

        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.scaleBy(x: 1, y: -1)
        for idx in 0..<trailColors.count where !glyphsByColor[idx].isEmpty {
            ctx.setFillColor(trailColors[idx])
            let glyphs = glyphsByColor[idx]
            let positions = posByColor[idx]
            glyphs.withUnsafeBufferPointer { gPtr in
                positions.withUnsafeBufferPointer { pPtr in
                    CTFontDrawGlyphs(font, gPtr.baseAddress!,
                                     pPtr.baseAddress!,
                                     glyphs.count, ctx)
                }
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
