// © 2026 Zsolt Hoffmann – zsolthoffmann.com. Licensed under the GNU GPL v3 (see LICENSE).
// CraftDora – cell images and PDF export

import AppKit

/// Image of one cell (background colour + symbol).
func cellTile(_ c: V3, symbol sym: String?, colored: Bool, size: Int) -> CGImage? {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let t = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    t.setFillColor(colored ? cgColor(c) : CGColor(gray: 1, alpha: 1))
    t.fill(CGRect(x: 0, y: 0, width: size, height: size))
    if let sym {
        let fg: NSColor = (colored && luminance(c) < 0.5) ? .white : .black
        let font = NSFont.systemFont(ofSize: CGFloat(size) * 0.64, weight: .bold)
        let a = NSAttributedString(string: sym, attributes: [.font: font, .foregroundColor: fg])
        let sz = a.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: t, flipped: false)
        a.draw(in: CGRect(x: (CGFloat(size) - sz.width) / 2, y: (CGFloat(size) - sz.height) / 2,
                          width: sz.width + 1, height: sz.height))
        NSGraphicsContext.restoreGraphicsState()
    }
    return t.makeImage()
}

/// Grid only (no header, numbers or key) – for the Progress view and the PDF overview.
func renderCells(_ p: Pattern, cell: Int, colored: Bool, symbols: Bool, grid: Bool) -> CGImage? {
    let w = p.width * cell, h = p.height * cell
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let H = CGFloat(h)
    let tiles: [CGImage?] = p.palette.indices.map {
        cellTile(p.palette[$0], symbol: symbols ? symbol($0) : nil, colored: colored, size: cell)
    }
    for y in 0..<p.height {
        for x in 0..<p.width {
            let l = p.labels[y * p.width + x]
            if l >= 0, let t = tiles[l] {
                ctx.draw(t, in: CGRect(x: CGFloat(x * cell), y: H - CGFloat((y + 1) * cell),
                                       width: CGFloat(cell), height: CGFloat(cell)))
            }
        }
    }
    if grid {
        ctx.setLineWidth(1)
        ctx.setStrokeColor(CGColor(gray: 0.6, alpha: 1))
        for i in 0...p.width where i % 10 != 0 {
            let xx = CGFloat(i * cell)
            ctx.move(to: CGPoint(x: xx, y: 0)); ctx.addLine(to: CGPoint(x: xx, y: H))
        }
        for j in 0...p.height where j % 10 != 0 {
            let yy = H - CGFloat(j * cell)
            ctx.move(to: CGPoint(x: 0, y: yy)); ctx.addLine(to: CGPoint(x: CGFloat(w), y: yy))
        }
        ctx.strokePath()
        ctx.setLineWidth(2)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        for i in stride(from: 0, through: p.width, by: 10) {
            let xx = CGFloat(i * cell)
            ctx.move(to: CGPoint(x: xx, y: 0)); ctx.addLine(to: CGPoint(x: xx, y: H))
        }
        for j in stride(from: 0, through: p.height, by: 10) {
            let yy = H - CGFloat(j * cell)
            ctx.move(to: CGPoint(x: 0, y: yy)); ctx.addLine(to: CGPoint(x: CGFloat(w), y: yy))
        }
        ctx.strokePath()
        ctx.stroke(CGRect(x: 0, y: 0, width: w, height: h))
    }
    return ctx.makeImage()
}

/// Printable PDF: page 1 overview + key, then the pattern in A4-sized pieces.
func writePDF(_ p: Pattern, to url: URL, colored: Bool, title: String) -> Bool {
    let W: CGFloat = 595.28, H: CGFloat = 841.89, m: CGFloat = 36
    var box = CGRect(x: 0, y: 0, width: W, height: H)
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

    func R(_ x: CGFloat, _ yTop: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: H - yTop - h, width: w, height: h)
    }
    func text(_ s: String, _ font: NSFont, x: CGFloat, yTop: CGFloat, align: Int = 0, color: NSColor = .black) {
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        let sz = a.size()
        var px = x
        if align == 1 { px -= sz.width / 2 } else if align == 2 { px -= sz.width }
        a.draw(in: CGRect(x: px, y: H - yTop - ceil(sz.height), width: ceil(sz.width) + 2, height: ceil(sz.height)))
    }
    func centered(_ a: NSAttributedString, _ sz: CGSize, in r: CGRect) {
        a.draw(in: CGRect(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2, width: sz.width + 1, height: sz.height))
    }

    let cell: CGFloat = 11
    let colsPer = 40, rowsPer = 60
    let pagesX = (p.width + colsPer - 1) / colsPer
    let pagesY = (p.height + rowsPer - 1) / rowsPer
    let totalPages = 1 + pagesX * pagesY
    let accent = NSColor(srgbRed: 0.85, green: 0.1, blue: 0.35, alpha: 1)
    let colorWord = p.threads == nil ? L("szín", "colours") : L("DMC fonalszín", "DMC thread colours")
    let info = "\(p.width) × \(p.height) " + L("öltés", "stitches") + "  ·  \(p.palette.count) \(colorWord)  ·  "
        + String(format: L("14-es aidán kb. %.1f × %.1f cm", "≈ %.1f × %.1f cm on 14-count Aida"),
                 Double(p.width) / 14 * 2.54, Double(p.height) / 14 * 2.54)

    // ---- Page 1: overview + key
    ctx.beginPDFPage(nil)
    text(L("Hímzésminta – \(title)", "Cross-stitch pattern – \(title)"), .boldSystemFont(ofSize: 18), x: m, yTop: m)
    text(info, .systemFont(ofSize: 10), x: m, yTop: m + 26, color: .darkGray)

    let legendRows = max(1, (p.palette.count + 1) / 2)
    let legendRowH: CGFloat = 15
    let legendH = 24 + CGFloat(legendRows) * legendRowH
    let ovTop = m + 50
    let ovMaxW = W - 2 * m
    let ovMaxH = H - m - legendH - ovTop - 24
    let ovCell = max(1, min(8, 2000 / max(p.width, p.height)))
    if ovMaxH > 60, let ov = renderCells(p, cell: ovCell, colored: true, symbols: false, grid: false) {
        let s = min(ovMaxW / CGFloat(ov.width), ovMaxH / CGFloat(ov.height))
        let ow = CGFloat(ov.width) * s, oh = CGFloat(ov.height) * s
        let ox = m + (ovMaxW - ow) / 2
        ctx.interpolationQuality = .none
        ctx.draw(ov, in: R(ox, ovTop, ow, oh))
        ctx.setLineWidth(0.5)
        ctx.setStrokeColor(CGColor(gray: 0.3, alpha: 1))
        ctx.stroke(R(ox, ovTop, ow, oh))
        if pagesX * pagesY > 1 {
            let cs = ow / CGFloat(p.width)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1)
            var n = 2
            for py in 0..<pagesY {
                for px in 0..<pagesX {
                    let c0 = px * colsPer, r0 = py * rowsPer
                    let cw = min(colsPer, p.width - c0), rh = min(rowsPer, p.height - r0)
                    let r = R(ox + CGFloat(c0) * cs, ovTop + CGFloat(r0) * cs, CGFloat(cw) * cs, CGFloat(rh) * cs)
                    ctx.stroke(r)
                    text("\(n)", .boldSystemFont(ofSize: 10), x: r.minX + 3, yTop: H - r.maxY + 2, color: accent)
                    n += 1
                }
            }
        }
    }

    let lgTop = H - m - legendH
    text(L("Jelmagyarázat", "Key"), .boldSystemFont(ofSize: 12), x: m, yTop: lgTop)
    let colWidth = (W - 2 * m) / 2
    let lf = NSFont.systemFont(ofSize: 9)
    let swFont = NSFont.systemFont(ofSize: 8, weight: .bold)
    for i in p.palette.indices {
        let col = i / legendRows, row = i % legendRows
        let x = m + CGFloat(col) * colWidth
        let y = lgTop + 20 + CGFloat(row) * legendRowH
        let r = R(x, y, 12, 12)
        ctx.setFillColor(cgColor(p.palette[i]))
        ctx.fill(r)
        ctx.setStrokeColor(CGColor(gray: 0.3, alpha: 1))
        ctx.setLineWidth(0.5)
        ctx.stroke(r)
        let fg: NSColor = luminance(p.palette[i]) < 0.5 ? .white : .black
        let a = NSAttributedString(string: symbol(i), attributes: [.font: swFont, .foregroundColor: fg])
        centered(a, a.size(), in: r)
        let label: String
        if let t = p.threads?[i] {
            let name = t.name.count > 26 ? String(t.name.prefix(25)) + "…" : t.name
            label = "DMC \(t.code)  \(name)  ·  \(p.counts[i]) " + L("öltés", "stitches")
        } else {
            label = "\(hex(p.palette[i]))  ·  \(p.counts[i]) " + L("öltés", "stitches")
        }
        text(label, lf, x: x + 18, yTop: y + 1)
    }
    text("1 / \(totalPages)", .systemFont(ofSize: 8), x: W - m, yTop: H - m + 14, align: 2, color: .gray)
    ctx.endPDFPage()

    // ---- Pattern pages
    let symFont = NSFont.systemFont(ofSize: cell * 0.68, weight: .bold)
    var symStr: [NSAttributedString] = []
    var symSize: [CGSize] = []
    for i in p.palette.indices {
        let fg: NSColor = (colored && luminance(p.palette[i]) < 0.5) ? .white : .black
        let a = NSAttributedString(string: symbol(i), attributes: [.font: symFont, .foregroundColor: fg])
        symStr.append(a)
        symSize.append(a.size())
    }
    let nf = NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .regular)
    var pageNo = 2
    for py in 0..<pagesY {
        for px in 0..<pagesX {
            let c0 = px * colsPer, r0 = py * rowsPer
            let c1 = min(p.width, c0 + colsPer), r1 = min(p.height, r0 + rowsPer)
            ctx.beginPDFPage(nil)
            text(L("\(title) – \(pageNo). oldal", "\(title) – page \(pageNo)"), .boldSystemFont(ofSize: 12), x: m, yTop: m)
            text(L("Oszlopok \(c0 + 1)–\(c1), sorok \(r0 + 1)–\(r1)", "Columns \(c0 + 1)–\(c1), rows \(r0 + 1)–\(r1)"), .systemFont(ofSize: 9),
                 x: m, yTop: m + 16, color: .darkGray)
            let gx = m + 24, gy = m + 50
            for r in r0..<r1 {
                for c in c0..<c1 {
                    let l = p.labels[r * p.width + c]
                    if l < 0 { continue }
                    let rect = R(gx + CGFloat(c - c0) * cell, gy + CGFloat(r - r0) * cell, cell, cell)
                    if colored {
                        ctx.setFillColor(cgColor(p.palette[l]))
                        ctx.fill(rect)
                    }
                    centered(symStr[l], symSize[l], in: rect)
                }
            }
            let gw = CGFloat(c1 - c0) * cell, gh = CGFloat(r1 - r0) * cell
            let top = H - gy, bottom = H - gy - gh
            ctx.setStrokeColor(CGColor(gray: 0.6, alpha: 1))
            ctx.setLineWidth(0.4)
            for c in c0...c1 where c % 10 != 0 {
                let xx = gx + CGFloat(c - c0) * cell
                ctx.move(to: CGPoint(x: xx, y: bottom)); ctx.addLine(to: CGPoint(x: xx, y: top))
            }
            for r in r0...r1 where r % 10 != 0 {
                let yy = top - CGFloat(r - r0) * cell
                ctx.move(to: CGPoint(x: gx, y: yy)); ctx.addLine(to: CGPoint(x: gx + gw, y: yy))
            }
            ctx.strokePath()
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
            ctx.setLineWidth(1.2)
            for c in c0...c1 where c % 10 == 0 {
                let xx = gx + CGFloat(c - c0) * cell
                ctx.move(to: CGPoint(x: xx, y: bottom)); ctx.addLine(to: CGPoint(x: xx, y: top))
            }
            for r in r0...r1 where r % 10 == 0 {
                let yy = top - CGFloat(r - r0) * cell
                ctx.move(to: CGPoint(x: gx, y: yy)); ctx.addLine(to: CGPoint(x: gx + gw, y: yy))
            }
            ctx.strokePath()
            ctx.stroke(CGRect(x: gx, y: bottom, width: gw, height: gh))

            let firstC = c0 == 0 ? 10 : ((c0 + 9) / 10) * 10
            if firstC <= c1 {
                for c in stride(from: firstC, through: c1, by: 10) {
                    text("\(c)", nf, x: gx + CGFloat(c - c0) * cell, yTop: gy - 11, align: 1, color: .darkGray)
                }
            }
            let firstR = r0 == 0 ? 10 : ((r0 + 9) / 10) * 10
            if firstR <= r1 {
                for r in stride(from: firstR, through: r1, by: 10) {
                    text("\(r)", nf, x: gx - 4, yTop: gy + CGFloat(r - r0) * cell - 4, align: 2, color: .darkGray)
                }
            }
            text("\(pageNo) / \(totalPages)", .systemFont(ofSize: 8), x: W - m, yTop: H - m + 14,
                 align: 2, color: .gray)
            ctx.endPDFPage()
            pageNo += 1
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    ctx.closePDF()
    return true
}

// MARK: - Stitched preview

/// Image of one cross stitch (X) on a transparent background, with shaded thread.
func stitchTile(_ c: V3, size: Int) -> CGImage? {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let t = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let s = CGFloat(size)
    let inset = s * 0.1
    let lw = s * 0.42
    let dark = c * 0.68
    let light = c + (V3(1, 1, 1) - c) * 0.4
    t.setLineCap(.round)
    func thread(_ a: CGPoint, _ b: CGPoint) {
        for (col, width) in [(dark, lw), (c, lw * 0.7), (light, lw * 0.18)] {
            t.setStrokeColor(cgColor(col))
            t.setLineWidth(width)
            t.move(to: a)
            t.addLine(to: b)
            t.strokePath()
        }
    }
    thread(CGPoint(x: inset, y: inset), CGPoint(x: s - inset, y: s - inset))       // bottom thread: /
    thread(CGPoint(x: inset, y: s - inset), CGPoint(x: s - inset, y: inset))       // top thread: \
    return t.makeImage()
}

/// Roughly how it will look stitched: cross stitches on Aida fabric (in a hoop for circles).
func renderStitched(_ p: Pattern, cell: Int) -> CGImage? {
    let pad = cell * 3
    let gw = p.width * cell, gh = p.height * cell
    let w = gw + pad * 2, h = gh + pad * 2
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let H = CGFloat(h)
    let c = CGFloat(cell)
    let fabric = V3(0.965, 0.95, 0.915)
    let circle = p.shape == .circle
    let center = CGPoint(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
    let radius = CGFloat(gw) / 2 + c * 1.2
    let hoopRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

    // Fabric
    ctx.saveGState()
    if circle {
        ctx.addEllipse(in: hoopRect)
        ctx.clip()
    }
    ctx.setFillColor(cgColor(fabric))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    // Aida holes at the cell corners
    let holes = CGMutablePath()
    let hr = max(0.6, c * 0.09)
    var yy = CGFloat(pad).truncatingRemainder(dividingBy: c)
    while yy <= H {
        var xx = CGFloat(pad).truncatingRemainder(dividingBy: c)
        while xx <= CGFloat(w) {
            holes.addEllipse(in: CGRect(x: xx - hr, y: yy - hr, width: hr * 2, height: hr * 2))
            xx += c
        }
        yy += c
    }
    ctx.addPath(holes)
    ctx.setFillColor(cgColor(fabric * 0.8))
    ctx.fillPath()

    // Stitches
    let tiles = p.palette.map { stitchTile($0, size: cell) }
    for y in 0..<p.height {
        for x in 0..<p.width {
            let l = p.labels[y * p.width + x]
            if l < 0 { continue }
            if let t = tiles[l] {
                ctx.draw(t, in: CGRect(x: CGFloat(pad + x * cell), y: H - CGFloat(pad + (y + 1) * cell),
                                       width: c, height: c))
            }
        }
    }
    ctx.restoreGState()

    // Embroidery hoop
    if circle {
        let wood = V3(0.78, 0.6, 0.4)
        ctx.setStrokeColor(cgColor(wood * 0.75))
        ctx.setLineWidth(c * 1.6)
        ctx.strokeEllipse(in: hoopRect.insetBy(dx: -c * 0.6, dy: -c * 0.6))
        ctx.setStrokeColor(cgColor(wood))
        ctx.setLineWidth(c * 1.1)
        ctx.strokeEllipse(in: hoopRect.insetBy(dx: -c * 0.6, dy: -c * 0.6))
    }
    return ctx.makeImage()
}
