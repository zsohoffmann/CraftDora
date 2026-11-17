// © 2026 Zsolt Hoffmann – zsolthoffmann.com. Licensed under the GNU GPL v3 (see LICENSE).
// CraftDora – native macOS cross-stitch pattern maker (SwiftUI)
// Build: ./build.sh   (requires the Xcode Command Line Tools)

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO

typealias V3 = SIMD3<Double>

// MARK: - Symbols

/// Clearly distinguishable symbols; \u{FE0E} forces text (non-emoji) presentation.
let symbolList: [String] = [
    "●", "■", "▲", "◆", "★", "✚", "✖\u{FE0E}", "♥\u{FE0E}", "♠\u{FE0E}", "♣\u{FE0E}",
    "♦\u{FE0E}", "○", "□", "△", "◇", "☆", "▼", "◀\u{FE0E}", "▶\u{FE0E}", "✿",
    "♪", "✦", "❖", "⊕", "⊗", "⊞", "◐", "◑",
    "A", "B", "C", "D", "E", "F", "G", "H", "K", "M",
    "N", "P", "R", "S", "T", "U", "V", "X", "Y", "Z",
]

// MARK: - Language

/// "system" (follows macOS), "hu" or "en" – chosen in the sidebar, stored in UserDefaults.
let appLanguageKey = "appLanguage"

func isEnglish() -> Bool {
    switch UserDefaults.standard.string(forKey: appLanguageKey) ?? "system" {
    case "hu": return false
    case "en": return true
    default: return !(Locale.preferredLanguages.first ?? "en").hasPrefix("hu")
    }
}

/// Picks the Hungarian or English text.
func L(_ hu: String, _ en: String) -> String { isEnglish() ? en : hu }

func symbol(_ i: Int) -> String { i < symbolList.count ? symbolList[i] : "\(i + 1)" }

// MARK: - Data model

struct DMCColor: Sendable {
    let code: String
    let name: String
    let rgb: V3
    let lab: V3
}

let dmcColors: [DMCColor] = dmcRaw.map { item in
    let rgb = V3(Double(item.2), Double(item.3), Double(item.4)) / 255
    return DMCColor(code: item.0, name: item.1, rgb: rgb, lab: rgbToLab(rgb))
}

struct Pattern: Sendable {
    let width: Int
    let height: Int
    let labels: [Int]      // width*height, row by row from the top (-1 = empty cell)
    let palette: [V3]      // sRGB 0...1
    let counts: [Int]      // stitch count per colour
    let threads: [DMCColor]? // DMC thread per colour (when enabled)
    let shape: PatternShape

    /// Number of real stitches (excluding the empty cells around a circle)
    var stitchCount: Int { counts.reduce(0, +) }
}

// MARK: - Colour handling

@inline(__always) func d2(_ a: V3, _ b: V3) -> Double { let d = a - b; return (d * d).sum() }

func luminance(_ c: V3) -> Double { 0.299 * c.x + 0.587 * c.y + 0.114 * c.z }

func cgColor(_ c: V3) -> CGColor { CGColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1) }

func hex(_ c: V3) -> String {
    func b(_ v: Double) -> Int { min(255, max(0, Int((v * 255).rounded()))) }
    return String(format: "#%02X%02X%02X", b(c.x), b(c.y), b(c.z))
}

func rgbToLab(_ c: V3) -> V3 {
    func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    let r = lin(c.x), g = lin(c.y), b = lin(c.z)
    let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
    func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : (7.787 * t + 16.0 / 116.0) }
    let fx = f(x), fy = f(y), fz = f(z)
    return V3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
}

func labToRgb(_ lab: V3) -> V3 {
    let fy = (lab.x + 16) / 116
    let fx = fy + lab.y / 500
    let fz = fy - lab.z / 200
    func finv(_ t: Double) -> Double { let t3 = t * t * t; return t3 > 0.008856 ? t3 : (t - 16.0 / 116.0) / 7.787 }
    let x = finv(fx) * 0.95047, y = finv(fy), z = finv(fz) * 1.08883
    let r = 3.2406 * x - 1.5372 * y - 0.4986 * z
    let g = -0.9689 * x + 1.8758 * y + 0.0415 * z
    let b = 0.0557 * x - 0.2040 * y + 1.0570 * z
    func gam(_ v: Double) -> Double {
        let c = min(1, max(0, v))
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
    return V3(gam(r), gam(g), gam(b))
}

/// Adjusts saturation and contrast in Lab space (hue is preserved).
/// Contrast: pushes lightness away from / towards mid grey (L = 50).
/// Highlights / shadows: -1…+1, only moves the light / dark tones, with a soft falloff.
func adjustColors(_ pixels: inout [V3], saturation amount: Double, contrast: Double,
                  highlights: Double = 0, shadows: Double = 0) {
    guard abs(amount - 1) > 0.001 || abs(contrast - 1) > 0.001
            || abs(highlights) > 0.001 || abs(shadows) > 0.001 else { return }
    func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
    var cache: [UInt32: V3] = [:]
    for i in pixels.indices {
        let c = pixels[i]
        let r = UInt32(min(255, max(0, (c.x * 255).rounded())))
        let g = UInt32(min(255, max(0, (c.y * 255).rounded())))
        let b = UInt32(min(255, max(0, (c.z * 255).rounded())))
        let key = (r << 16) | (g << 8) | b
        if let v = cache[key] { pixels[i] = v; continue }
        var lab = rgbToLab(c)
        var L = 50 + (lab.x - 50) * contrast
        let t = min(1, max(0, L / 100))
        L += shadows * (1 - smoothstep(0, 0.55, t)) * 30      // dark tones
        L += highlights * smoothstep(0.45, 1, t) * 30         // light tones
        lab.x = min(100, max(0, L))
        lab.y *= amount
        lab.z *= amount
        let v = labToRgb(lab)
        cache[key] = v
        pixels[i] = v
    }
}

/// CIEDE2000 colour difference – the best approximation of how different two colours look.
func deltaE2000(_ c1: V3, _ c2: V3) -> Double {
    let rad = Double.pi / 180
    let L1 = c1.x, a1 = c1.y, b1 = c1.z
    let L2 = c2.x, a2 = c2.y, b2 = c2.z
    let p25 = 6_103_515_625.0 // 25^7
    let cBar = (sqrt(a1 * a1 + b1 * b1) + sqrt(a2 * a2 + b2 * b2)) / 2
    let cBar7 = pow(cBar, 7)
    let g = 0.5 * (1 - sqrt(cBar7 / (cBar7 + p25)))
    let a1p = (1 + g) * a1, a2p = (1 + g) * a2
    let c1p = sqrt(a1p * a1p + b1 * b1), c2p = sqrt(a2p * a2p + b2 * b2)
    func hue(_ b: Double, _ a: Double) -> Double {
        if a == 0 && b == 0 { return 0 }
        let h = atan2(b, a) / rad
        return h < 0 ? h + 360 : h
    }
    let h1p = hue(b1, a1p), h2p = hue(b2, a2p)
    let dLp = L2 - L1, dCp = c2p - c1p
    var dhp = 0.0
    if c1p * c2p != 0 {
        dhp = h2p - h1p
        if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
    }
    let dHp = 2 * sqrt(c1p * c2p) * sin(dhp * rad / 2)
    let lBarP = (L1 + L2) / 2, cBarP = (c1p + c2p) / 2
    var hBarP = h1p + h2p
    if c1p * c2p != 0 {
        if abs(h1p - h2p) > 180 {
            hBarP = (h1p + h2p + (h1p + h2p < 360 ? 360 : -360)) / 2
        } else {
            hBarP = (h1p + h2p) / 2
        }
    }
    let t = 1 - 0.17 * cos((hBarP - 30) * rad) + 0.24 * cos(2 * hBarP * rad)
        + 0.32 * cos((3 * hBarP + 6) * rad) - 0.20 * cos((4 * hBarP - 63) * rad)
    let dTheta = 30 * exp(-pow((hBarP - 275) / 25, 2))
    let cBarP7 = pow(cBarP, 7)
    let rc = 2 * sqrt(cBarP7 / (cBarP7 + p25))
    let l50 = (lBarP - 50) * (lBarP - 50)
    let sl = 1 + 0.015 * l50 / sqrt(20 + l50)
    let sc = 1 + 0.045 * cBarP
    let sh = 1 + 0.015 * cBarP * t
    let rt = -sin(2 * dTheta * rad) * rc
    let x = dLp / sl, y = dCp / sc, z = dHp / sh
    return sqrt(max(0, x * x + y * y + z * z + rt * y * z))
}

func nearestDMC(_ lab: V3, among candidates: [Int]? = nil) -> Int {
    var best = 0
    var bd = Double.infinity
    for i in candidates ?? Array(dmcColors.indices) {
        let d = deltaE2000(lab, dmcColors[i].lab)
        if d < bd { bd = d; best = i }
    }
    return best
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Image processing

/// Downscales to the target stitch count (supersampling + box average for a clean result).
func sampleImage(_ cg: CGImage, width: Int, height forcedH: Int? = nil) -> (pixels: [V3], w: Int, h: Int) {
    let w = max(1, width)
    let h = forcedH ?? max(1, Int((Double(cg.height) * Double(w) / Double(cg.width)).rounded()))
    let f = max(1, min(6, cg.width / w))
    let bw = w * f, bh = h * f
    var buf = [UInt8](repeating: 255, count: bw * bh * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    buf.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: bw, height: bh, bitsPerComponent: 8,
                                  bytesPerRow: bw * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)) // transparent → white
        ctx.fill(CGRect(x: 0, y: 0, width: bw, height: bh))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: bw, height: bh))
    }
    var px = [V3](repeating: .zero, count: w * h)
    let inv = 1.0 / Double(f * f * 255)
    for y in 0..<h {
        for x in 0..<w {
            var s = V3.zero
            for dy in 0..<f {
                let row = (y * f + dy) * bw * 4
                for dx in 0..<f {
                    let i = row + (x * f + dx) * 4
                    s += V3(Double(buf[i]), Double(buf[i + 1]), Double(buf[i + 2]))
                }
            }
            px[y * w + x] = s * inv
        }
    }
    return (px, w, h)
}

/// Colour reduction with k-means in Lab space (matches human perception).
func quantize(_ rgb: [V3], k requested: Int) -> (labels: [Int], palette: [V3]) {
    var uniq: [V3] = []
    var weight: [Double] = []
    var map = [Int](repeating: 0, count: rgb.count)
    var dict: [UInt32: Int] = [:]
    for (i, c) in rgb.enumerated() {
        let r = UInt32(min(255, max(0, (c.x * 255).rounded())))
        let g = UInt32(min(255, max(0, (c.y * 255).rounded())))
        let b = UInt32(min(255, max(0, (c.z * 255).rounded())))
        let key = (r << 16) | (g << 8) | b
        if let j = dict[key] {
            weight[j] += 1
            map[i] = j
        } else {
            dict[key] = uniq.count
            map[i] = uniq.count
            uniq.append(c)
            weight.append(1)
        }
    }
    let lab = uniq.map(rgbToLab)
    let n = lab.count
    let k = max(1, min(requested, n))

    // k-means++ seeding (fixed seed → same settings always give the same result)
    var rng = SplitMix64(state: 42)
    let first = weight.indices.max(by: { weight[$0] < weight[$1] }) ?? 0
    var centers: [V3] = [lab[first]]
    var dist = lab.map { d2($0, lab[first]) }
    while centers.count < k {
        var total = 0.0
        for i in 0..<n { total += dist[i] * weight[i] }
        if total <= 0 { break }
        var r = Double.random(in: 0..<total, using: &rng)
        var pick = n - 1
        for i in 0..<n {
            r -= dist[i] * weight[i]
            if r <= 0 { pick = i; break }
        }
        centers.append(lab[pick])
        for i in 0..<n { dist[i] = min(dist[i], d2(lab[i], lab[pick])) }
    }

    var assign = [Int](repeating: -1, count: n)
    for _ in 0..<25 {
        var changed = false
        for i in 0..<n {
            var best = 0
            var bd = Double.infinity
            for j in 0..<centers.count {
                let d = d2(lab[i], centers[j])
                if d < bd { bd = d; best = j }
            }
            if assign[i] != best { assign[i] = best; changed = true }
        }
        if !changed { break }
        var sums = [V3](repeating: .zero, count: centers.count)
        var ws = [Double](repeating: 0, count: centers.count)
        for i in 0..<n {
            sums[assign[i]] += lab[i] * weight[i]
            ws[assign[i]] += weight[i]
        }
        for j in centers.indices where ws[j] > 0 { centers[j] = sums[j] / ws[j] }
    }

    // For display: the cluster's real average colour in sRGB
    var rs = [V3](repeating: .zero, count: centers.count)
    var cnt = [Double](repeating: 0, count: centers.count)
    for i in 0..<n {
        rs[assign[i]] += uniq[i] * weight[i]
        cnt[assign[i]] += weight[i]
    }
    var remap = [Int](repeating: 0, count: centers.count)
    var palette: [V3] = []
    for j in centers.indices where cnt[j] > 0 {
        remap[j] = palette.count
        palette.append(rs[j] / cnt[j])
    }
    let labels = map.map { remap[assign[$0]] }
    return (labels, palette)
}

/// Merges lone stitches (no same-coloured neighbour) into their surroundings. (-1 = empty cell, untouched)
func removeConfetti(_ labels: inout [Int], w: Int, h: Int, k: Int) {
    let src = labels
    var counts = [Int](repeating: 0, count: k)
    for y in 0..<h {
        for x in 0..<w {
            let me = src[y * w + x]
            if me < 0 { continue }
            var same = false
            for j in 0..<k { counts[j] = 0 }
            for dy in -1...1 {
                for dx in -1...1 where !(dx == 0 && dy == 0) {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let l = src[ny * w + nx]
                    if l < 0 { continue }
                    if l == me { same = true }
                    counts[l] += 1
                }
            }
            if !same, let best = counts.indices.max(by: { counts[$0] < counts[$1] }), counts[best] > 0 {
                labels[y * w + x] = best
            }
        }
    }
}

// MARK: - Shape and crop

enum PatternShape: String, Hashable, CaseIterable, Sendable {
    case original, square, circle
}

/// The square to crop from the source image (top-left origin, in pixels). No crop for the original shape.
/// - cx, cy: crop centre in 0…1; zoom: 1 = the largest possible square.
func cropRect(width w: Int, height h: Int, shape: PatternShape, cx: Double, cy: Double, zoom: Double) -> CGRect? {
    guard shape != .original else { return nil }
    let side = Double(min(w, h)) / max(1, zoom)
    let half = side / 2
    let x = min(max(cx * Double(w), half), Double(w) - half) - half
    let y = min(max(cy * Double(h), half), Double(h) - half) - half
    return CGRect(x: x, y: y, width: side, height: side)
}

func makePattern(_ cg: CGImage, width: Int, colors: Int, cleanup: Bool, useDMC: Bool,
                 shape: PatternShape, crop: CGRect?, vivid: Double, contrast: Double,
                 highlights: Double, shadows: Double) -> Pattern {
    let src = crop.flatMap { cg.cropping(to: $0.integral) } ?? cg
    var s = sampleImage(src, width: width, height: shape == .original ? nil : width)
    adjustColors(&s.pixels, saturation: vivid, contrast: contrast, highlights: highlights, shadows: shadows)

    // Which cells get a stitch (for a circle, only those inside it)
    var included: [Int] = []
    included.reserveCapacity(s.pixels.count)
    let r = Double(s.w) / 2
    for y in 0..<s.h {
        for x in 0..<s.w {
            if shape == .circle {
                let dx = Double(x) + 0.5 - r, dy = Double(y) + 0.5 - Double(s.h) / 2
                if dx * dx + dy * dy > r * r { continue }
            }
            included.append(y * s.w + x)
        }
    }
    if included.isEmpty { included = Array(s.pixels.indices) }

    let q = quantize(included.map { s.pixels[$0] }, k: colors)
    var labels = [Int](repeating: -1, count: s.pixels.count)
    for (n, i) in included.enumerated() { labels[i] = q.labels[n] }
    var palette = q.palette
    var threads: [DMCColor]? = nil

    if useDMC {
        // 1) the closest DMC thread for every colour cluster (duplicates merge)
        var chosen: [Int] = []
        for c in q.palette {
            let d = nearestDMC(rgbToLab(c))
            if !chosen.contains(d) { chosen.append(d) }
        }
        // 2) every stitch gets the closest of the chosen threads
        var cache: [UInt32: Int] = [:]
        for i in included {
            let c = s.pixels[i]
            let rr = UInt32(min(255, max(0, (c.x * 255).rounded())))
            let gg = UInt32(min(255, max(0, (c.y * 255).rounded())))
            let bb = UInt32(min(255, max(0, (c.z * 255).rounded())))
            let key = (rr << 16) | (gg << 8) | bb
            if let v = cache[key] {
                labels[i] = v
            } else {
                let d = nearestDMC(rgbToLab(c), among: chosen)
                let v = chosen.firstIndex(of: d) ?? 0
                cache[key] = v
                labels[i] = v
            }
        }
        palette = chosen.map { dmcColors[$0].rgb }
        threads = chosen.map { dmcColors[$0] }
    }

    if cleanup && palette.count > 1 {
        removeConfetti(&labels, w: s.w, h: s.h, k: palette.count)
    }
    var counts = [Int](repeating: 0, count: palette.count)
    for l in labels where l >= 0 { counts[l] += 1 }
    // Sorted by frequency: the most common colour gets the simplest symbol
    let order = palette.indices.filter { counts[$0] > 0 }.sorted { counts[$0] > counts[$1] }
    var remap = [Int](repeating: 0, count: palette.count)
    for (newI, oldI) in order.enumerated() { remap[oldI] = newI }
    return Pattern(width: s.w, height: s.h,
                   labels: labels.map { $0 < 0 ? -1 : remap[$0] },
                   palette: order.map { palette[$0] },
                   counts: order.map { counts[$0] },
                   threads: threads.map { t in order.map { t[$0] } },
                   shape: shape)
}

/// Shopping / thread list as text (for the clipboard).
func threadListText(_ p: Pattern) -> String {
    var lines = [L("Hímzésminta – \(p.width) × \(p.height) öltés, \(p.palette.count) szín",
                   "Cross-stitch pattern – \(p.width) × \(p.height) stitches, \(p.palette.count) colours"), ""]
    for i in p.palette.indices {
        let id = p.threads.map { "DMC \($0[i].code) – \($0[i].name)" } ?? hex(p.palette[i])
        lines.append("\(symbol(i))  \(id)  –  \(p.counts[i]) " + L("öltés", "stitches"))
    }
    return lines.joined(separator: "\n")
}

// MARK: - Rendering the output image

func renderPattern(_ p: Pattern, cell requestedCell: Int, colored: Bool, title: String) -> CGImage? {
    // Keep the image manageable (grid max. ~9000 px)
    let cell = max(6, min(requestedCell, 9000 / max(p.width, p.height)))
    let margin = max(48, cell * 2)
    let headerH = 76
    let gridW = p.width * cell, gridH = p.height * cell
    let colW = p.threads == nil ? 300 : 440
    let contentW = max(gridW, colW * 2)
    let totalW = contentW + margin * 2
    let cols = max(1, contentW / colW)
    let rowH = 34
    let rows = (p.palette.count + cols - 1) / cols
    let ox = margin, oy = headerH + margin
    let legendTop = oy + gridH + 44
    let totalH = legendTop + 36 + rows * rowH + margin / 2

    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(data: nil, width: totalW, height: totalH, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs, bitmapInfo: bitmapInfo) else { return nil }
    let H = CGFloat(totalH)
    // Top-based coordinates → CG (bottom-based) rectangle
    func R(_ x: Int, _ yTop: Int, _ w: Int, _ h: Int) -> CGRect {
        CGRect(x: CGFloat(x), y: H - CGFloat(yTop + h), width: CGFloat(w), height: CGFloat(h))
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    defer { NSGraphicsContext.restoreGraphicsState() }

    func text(_ s: String, _ font: NSFont, x: CGFloat, yTop: CGFloat, align: Int = 0, color: NSColor = .black) {
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        let sz = a.size()
        var px = x
        if align == 1 { px -= sz.width / 2 } else if align == 2 { px -= sz.width }
        a.draw(in: CGRect(x: px, y: H - yTop - ceil(sz.height), width: ceil(sz.width) + 2, height: ceil(sz.height)))
    }

    func tile(_ i: Int, colored col: Bool, size: Int) -> CGImage? {
        guard let t = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                bytesPerRow: 0, space: cs, bitmapInfo: bitmapInfo) else { return nil }
        let c = p.palette[i]
        t.setFillColor(col ? cgColor(c) : CGColor(gray: 1, alpha: 1))
        t.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let fg: NSColor = (col && luminance(c) < 0.5) ? .white : .black
        let font = NSFont.systemFont(ofSize: CGFloat(size) * 0.64, weight: .bold)
        let a = NSAttributedString(string: symbol(i), attributes: [.font: font, .foregroundColor: fg])
        let sz = a.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: t, flipped: false)
        a.draw(in: CGRect(x: (CGFloat(size) - sz.width) / 2, y: (CGFloat(size) - sz.height) / 2,
                          width: sz.width + 1, height: sz.height))
        NSGraphicsContext.restoreGraphicsState()
        return t.makeImage()
    }

    // Background
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: totalW, height: totalH))

    // Header
    let cmW = Double(p.width) / 14 * 2.54, cmH = Double(p.height) / 14 * 2.54
    text(L("Hímzésminta – \(title)", "Cross-stitch pattern – \(title)"), .boldSystemFont(ofSize: 22), x: CGFloat(margin), yTop: 18)
    let colorWord = p.threads == nil ? L("szín", "colours") : L("DMC fonalszín", "DMC thread colours")
    text("\(p.width) × \(p.height) " + L("öltés", "stitches") + "  ·  \(p.palette.count) \(colorWord)  ·  "
         + String(format: L("14-es aidán kb. %.1f × %.1f cm", "≈ %.1f × %.1f cm on 14-count Aida"), cmW, cmH),
         .systemFont(ofSize: 14), x: CGFloat(margin), yTop: 50, color: .darkGray)

    // Cells
    let tiles = (0..<p.palette.count).map { tile($0, colored: colored, size: cell) }
    for y in 0..<p.height {
        for x in 0..<p.width {
            let l = p.labels[y * p.width + x]
            if l >= 0, let t = tiles[l] {
                ctx.draw(t, in: R(ox + x * cell, oy + y * cell, cell, cell))
            }
        }
    }

    // Grid lines
    let gx0 = CGFloat(ox), gx1 = CGFloat(ox + gridW)
    let gyTop = H - CGFloat(oy), gyBot = H - CGFloat(oy + gridH)
    ctx.setLineWidth(1)
    ctx.setStrokeColor(CGColor(gray: 0.55, alpha: 1))
    for i in 0...p.width where i % 10 != 0 {
        let xx = CGFloat(ox + i * cell)
        ctx.move(to: CGPoint(x: xx, y: gyBot)); ctx.addLine(to: CGPoint(x: xx, y: gyTop))
    }
    for j in 0...p.height where j % 10 != 0 {
        let yy = H - CGFloat(oy + j * cell)
        ctx.move(to: CGPoint(x: gx0, y: yy)); ctx.addLine(to: CGPoint(x: gx1, y: yy))
    }
    ctx.strokePath()
    ctx.setLineWidth(2)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
    for i in stride(from: 0, through: p.width, by: 10) {
        let xx = CGFloat(ox + i * cell)
        ctx.move(to: CGPoint(x: xx, y: gyBot)); ctx.addLine(to: CGPoint(x: xx, y: gyTop))
    }
    for j in stride(from: 0, through: p.height, by: 10) {
        let yy = H - CGFloat(oy + j * cell)
        ctx.move(to: CGPoint(x: gx0, y: yy)); ctx.addLine(to: CGPoint(x: gx1, y: yy))
    }
    ctx.strokePath()
    ctx.stroke(CGRect(x: gx0, y: gyBot, width: CGFloat(gridW), height: CGFloat(gridH)))
    if p.shape == .circle {
        ctx.setStrokeColor(CGColor(srgbRed: 0.85, green: 0.12, blue: 0.35, alpha: 0.8))
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: gx0, y: gyBot, width: CGFloat(gridW), height: CGFloat(gridH)))
    }

    // Numbers every ten
    let numFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    for i in stride(from: 10, through: p.width, by: 10) {
        text("\(i)", numFont, x: CGFloat(ox + i * cell), yTop: CGFloat(oy - 30), align: 1, color: .darkGray)
    }
    for j in stride(from: 10, through: p.height, by: 10) {
        text("\(j)", numFont, x: CGFloat(ox - 16), yTop: CGFloat(oy + j * cell) - 7, align: 2, color: .darkGray)
    }

    // Red centre markers
    ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.12, blue: 0.12, alpha: 1))
    let cx = gx0 + CGFloat(gridW) / 2
    let cy = H - CGFloat(oy) - CGFloat(gridH) / 2
    ctx.move(to: CGPoint(x: cx - 6, y: gyTop + 13)); ctx.addLine(to: CGPoint(x: cx + 6, y: gyTop + 13))
    ctx.addLine(to: CGPoint(x: cx, y: gyTop + 3)); ctx.closePath()
    ctx.move(to: CGPoint(x: gx0 - 13, y: cy + 6)); ctx.addLine(to: CGPoint(x: gx0 - 13, y: cy - 6))
    ctx.addLine(to: CGPoint(x: gx0 - 3, y: cy)); ctx.closePath()
    ctx.fillPath()

    // Key
    text(L("Jelmagyarázat", "Key"), .boldSystemFont(ofSize: 16), x: CGFloat(margin), yTop: CGFloat(legendTop))
    let sw = rowH - 8
    let legendFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    for i in 0..<p.palette.count {
        let col = i % cols, row = i / cols
        let x = margin + col * colW
        let y = legendTop + 32 + row * rowH
        if let t = tile(i, colored: true, size: sw) { ctx.draw(t, in: R(x, y, sw, sw)) }
        ctx.setLineWidth(1)
        ctx.setStrokeColor(CGColor(gray: 0.3, alpha: 1))
        ctx.stroke(R(x, y, sw, sw))
        let label: String
        if let t = p.threads?[i] {
            let name = t.name.count > 30 ? String(t.name.prefix(29)) + "…" : t.name
            label = "DMC \(t.code)  \(name)  ·  \(p.counts[i]) " + L("öltés", "stitches")
        } else {
            label = "\(i + 1).  \(hex(p.palette[i]))   \(p.counts[i]) " + L("öltés", "stitches")
        }
        text(label, legendFont, x: CGFloat(x + sw + 10), yTop: CGFloat(y + (sw - 16) / 2))
    }

    return ctx.makeImage()
}

func writePNG(_ img: CGImage, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(dest, img, nil)
    return CGImageDestinationFinalize(dest)
}

// MARK: - View model

enum ViewMode: Hashable { case preview, stitched, progress }
enum MarkMode: Hashable { case single, region }

struct UndoEntry {
    let indices: [Int]
    let value: Bool   // the new state applied to these cells
}

struct Params: Hashable {
    var sourceID: UUID?
    var width: Int
    var colors: Int
    var cleanup: Bool
    var useDMC: Bool
    var cell: Int
    var colored: Bool
    var shape: PatternShape
    var cropX: Double
    var cropY: Double
    var cropZoom: Double
    var vivid: Double
    var contrast: Double
    var highlights: Double
    var shadows: Double
    var english: Bool
}

@MainActor
final class Model: ObservableObject {
    @Published var source: CGImage?
    @Published var sourceID: UUID?
    @Published var sourceName = "minta"
    @Published var width: Double = 80
    @Published var colors: Double = 12
    @Published var cleanup = true
    @Published var useDMC = true
    @Published var cell: Double = 20
    @Published var colored = true
    @Published var shape: PatternShape = .original
    @Published var cropX = 0.5
    @Published var cropY = 0.5
    @Published var cropZoom = 1.0
    @Published var vivid = 1.25
    @Published var contrast = 1.0
    @Published var highlights = 0.0
    @Published var shadows = 0.0
    @Published var stitchedImage: CGImage?
    @Published var pattern: Pattern?
    @Published var output: CGImage?
    @Published var busy = false
    @Published var errorText: String?

    // Progress view
    @Published var mode: ViewMode = .preview
    @Published var markMode: MarkMode = .single
    @Published var progressImage: CGImage?
    @Published var done: [Bool] = []
    @Published var doneCounts: [Int] = []
    @Published var highlight: Int?
    @Published private(set) var undoStack: [UndoEntry] = []

    private var cacheKey = ""
    private var cachedPattern: Pattern?
    private var progressKey = ""
    private var stroke: [Int] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var totalDone: Int { doneCounts.reduce(0, +) }

    var params: Params {
        Params(sourceID: sourceID, width: Int(width), colors: Int(colors),
               cleanup: cleanup, useDMC: useDMC, cell: Int(cell), colored: colored,
               shape: shape, cropX: cropX, cropY: cropY, cropZoom: cropZoom,
               vivid: (vivid * 20).rounded() / 20,
               contrast: (contrast * 20).rounded() / 20,
               highlights: (highlights * 20).rounded() / 20,
               shadows: (shadows * 20).rounded() / 20,
               english: isEnglish())
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    func load(_ url: URL) {
        guard let ns = NSImage(contentsOf: url),
              let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            errorText = L("Nem sikerült megnyitni: ", "Couldn’t open: ") + url.lastPathComponent
            return
        }
        errorText = nil
        source = cg
        sourceName = url.deletingPathExtension().lastPathComponent
        cachedPattern = nil
        cropX = 0.5
        cropY = 0.5
        cropZoom = 1.0
        sourceID = UUID()
    }

    func regenerate(_ p: Params) async {
        guard let src = source, let id = p.sourceID else {
            output = nil; pattern = nil; progressImage = nil; stitchedImage = nil
            return
        }
        try? await Task.sleep(nanoseconds: 150_000_000)   // debounce while a slider is being dragged
        if Task.isCancelled { return }
        busy = true
        let crop = cropRect(width: src.width, height: src.height, shape: p.shape,
                            cx: p.cropX, cy: p.cropY, zoom: p.cropZoom)
        let cropKey = crop.map { "\(Int($0.minX))-\(Int($0.minY))-\(Int($0.width))" } ?? "full"
        let key = "\(id)-\(p.width)-\(p.colors)-\(p.cleanup)-\(p.useDMC)-\(p.shape.rawValue)-\(cropKey)-\(p.vivid)-\(p.contrast)-\(p.highlights)-\(p.shadows)"
        let cached = key == cacheKey ? cachedPattern : nil
        let name = sourceName
        let result = await Task.detached(priority: .userInitiated) { () -> (Pattern, CGImage?, CGImage?, CGImage?) in
            let pat = cached ?? makePattern(src, width: p.width, colors: p.colors,
                                            cleanup: p.cleanup, useDMC: p.useDMC,
                                            shape: p.shape, crop: crop, vivid: p.vivid,
                                            contrast: p.contrast,
                                            highlights: p.highlights, shadows: p.shadows)
            let full = renderPattern(pat, cell: p.cell, colored: p.colored, title: name)
            let pcell = max(8, min(24, 4800 / max(pat.width, pat.height)))
            let prog = renderCells(pat, cell: pcell, colored: p.colored, symbols: true, grid: true)
            let scell = max(6, min(16, 4000 / max(pat.width, pat.height)))
            let stitched = renderStitched(pat, cell: scell)
            return (pat, full, prog, stitched)
        }.value
        busy = false
        if Task.isCancelled { return }
        cacheKey = key
        cachedPattern = result.0
        pattern = result.0
        output = result.1
        progressImage = result.2
        stitchedImage = result.3
        loadProgress()
    }

    // MARK: Saving

    func save() {
        let stitched = mode == .stitched
        guard let img = stitched ? stitchedImage : output else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(sourceName)_" + (stitched ? L("elonezet", "preview") : L("minta", "pattern")) + ".png"
        if panel.runModal() == .OK, let url = panel.url {
            if !writePNG(img, to: url) { errorText = L("Nem sikerült menteni.", "Couldn’t save the file.") }
        }
    }

    func savePDF() {
        guard let p = pattern else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(sourceName)_" + L("minta", "pattern") + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let colored = self.colored
        let name = sourceName
        busy = true
        Task {
            let ok = await Task.detached(priority: .userInitiated) {
                writePDF(p, to: url, colored: colored, title: name)
            }.value
            busy = false
            if !ok { errorText = L("Nem sikerült a PDF mentése.", "Couldn’t save the PDF.") }
        }
    }

    func copyThreadList() {
        guard let p = pattern else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(threadListText(p), forType: .string)
    }

    // MARK: Progress

    private func progressURL(_ key: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CraftDora/Progress/\(key).bin")
    }

    /// When the pattern changes, loads the progress saved for it earlier.
    func loadProgress() {
        guard let p = pattern else { done = []; doneCounts = []; progressKey = ""; return }
        let key = stableKey(p)
        if key == progressKey && done.count == p.labels.count { return }
        progressKey = key
        undoStack = []
        highlight = nil
        var d = [Bool](repeating: false, count: p.labels.count)
        if let data = try? Data(contentsOf: progressURL(key)), data.count == d.count {
            for (i, b) in data.enumerated() { d[i] = b != 0 }
        }
        done = d
        recount()
    }

    private func persist() {
        guard !progressKey.isEmpty else { return }
        let url = progressURL(progressKey)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data(done.map { $0 ? UInt8(1) : UInt8(0) }).write(to: url, options: .atomic)
    }

    private func recount() {
        guard let p = pattern, done.count == p.labels.count else { doneCounts = []; return }
        var c = [Int](repeating: 0, count: p.palette.count)
        for i in done.indices where done[i] && p.labels[i] >= 0 { c[p.labels[i]] += 1 }
        doneCounts = c
    }

    /// Sets one cell while dragging (the whole drag becomes one undoable step).
    func setCell(_ i: Int, _ value: Bool) {
        guard let p = pattern, i >= 0, i < done.count, done[i] != value,
              p.labels[i] >= 0, p.labels[i] < doneCounts.count else { return }
        done[i] = value
        doneCounts[p.labels[i]] += value ? 1 : -1
        stroke.append(i)
    }

    func endStroke(value: Bool) {
        if !stroke.isEmpty {
            undoStack.append(UndoEntry(indices: stroke, value: value))
            persist()
        }
        stroke = []
    }

    private func apply(_ indices: [Int], _ value: Bool) {
        var d = done
        var changed: [Int] = []
        for i in indices where d[i] != value {
            d[i] = value
            changed.append(i)
        }
        guard !changed.isEmpty else { return }
        done = d
        recount()
        undoStack.append(UndoEntry(indices: changed, value: value))
        persist()
    }

    /// Marks / unmarks the connected patch of the same colour.
    func toggleRegion(_ start: Int) {
        guard let p = pattern, start >= 0, start < done.count, p.labels[start] >= 0 else { return }
        let target = p.labels[start]
        var visited = [Bool](repeating: false, count: p.labels.count)
        var stack = [start]
        visited[start] = true
        var region: [Int] = []
        while let i = stack.popLast() {
            region.append(i)
            let x = i % p.width, y = i / p.width
            let neighbours = [x > 0 ? i - 1 : -1,
                              x < p.width - 1 ? i + 1 : -1,
                              y > 0 ? i - p.width : -1,
                              y < p.height - 1 ? i + p.width : -1]
            for j in neighbours where j >= 0 && !visited[j] && p.labels[j] == target {
                visited[j] = true
                stack.append(j)
            }
        }
        apply(region, !done[start])
    }

    func markColor(_ label: Int, _ value: Bool) {
        guard let p = pattern, done.count == p.labels.count else { return }
        apply(p.labels.indices.filter { p.labels[$0] == label }, value)
    }

    func clearAll() {
        apply(Array(done.indices), false)   // empty cells are never marked, so this is safe
    }

    func undo() {
        guard let e = undoStack.popLast() else { return }
        var d = done
        for i in e.indices where i < d.count { d[i] = !e.value }
        done = d
        recount()
        persist()
    }
}

// MARK: - User interface

struct ContentView: View {
    @StateObject private var model = Model()
    @State private var fit = true
    @State private var zoom = 1.0
    @State private var progressZoom = 16.0
    @State private var confirmClear = false
    @AppStorage("showDoneStitches") private var showDone = false
    @AppStorage(appLanguageKey) private var appLanguage = "system"

    private var maxProgressZoom: Double {
        guard let p = model.pattern else { return 40 }
        return max(4, min(40, 6000 / Double(max(p.width, p.height))))
    }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 280, idealWidth: 300, maxWidth: 360)
            preview.frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("CraftDora")
        .task(id: model.params) { await model.regenerate(model.params) }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let pr = providers.first else { return false }
            _ = pr.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.load(url) } }
            }
            return true
        }
        .confirmationDialog(L("Törlöd az összes jelölést ennél a mintánál?", "Clear all marks for this pattern?"), isPresented: $confirmClear) {
            Button(L("Összes jelölés törlése", "Clear all marks"), role: .destructive) { model.clearAll() }
            Button(L("Mégse", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("A Visszavonás gombbal utána is visszahozhatod.", "You can bring them back with Undo afterwards."))
        }
    }

    /// Rounds slider values to `step` without the dense tick marks a stepped Slider draws on macOS.
    private func snapped(_ value: Binding<Double>, _ step: Double) -> Binding<Double> {
        Binding(get: { value.wrappedValue },
                set: { value.wrappedValue = ($0 / step).rounded() * step })
    }

    /// -100%…+100% slider, 0 is the default.
    private func adjustRow(_ title: String, _ value: Binding<Double>) -> some View {
        let pct = Int((value.wrappedValue * 100).rounded())
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(pct > 0 ? "+\(pct)%" : "\(pct)%").monospacedDigit().foregroundColor(.secondary)
                Button(L("Alap", "Reset")) { value.wrappedValue = 0 }
                    .controlSize(.small)
                    .disabled(abs(value.wrappedValue) < 0.01)
            }
            Slider(value: snapped(value, 0.05), in: -1...1)
        }
    }

    private func sliderRow(_ title: String, _ value: Binding<Double>,
                           _ range: ClosedRange<Double>, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) \(unit)").monospacedDigit().foregroundColor(.secondary)
                Stepper("", value: value, in: range, step: 1).labelsHidden()
            }
            Slider(value: snapped(value, 1), in: range)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button { model.open() } label: {
                    Label(L("Kép megnyitása…", "Open Image…"), systemImage: "photo").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut("o")

                if let src = model.source {
                    CropEditor(model: model, image: src)
                    Text(model.sourceName).font(.caption).foregroundColor(.secondary).lineLimit(1)
                } else {
                    Text(L("…vagy húzz egy képet az ablakba.", "…or drop an image onto the window.")).font(.callout).foregroundColor(.secondary)
                }

                if model.mode == .progress, let p = model.pattern {
                    progressSummary(p)
                } else {
                    settings
                }

                if let p = model.pattern {
                    Divider()
                    HStack {
                        Text(p.threads == nil ? L("Színek", "Colours") : L("Fonalak", "Threads")).font(.headline)
                        Spacer()
                        Button { model.copyThreadList() } label: { Label(L("Másolás", "Copy"), systemImage: "doc.on.doc") }
                            .controlSize(.small)
                            .help(L("Fonallista másolása a vágólapra", "Copy thread list to the clipboard"))
                    }
                    if model.mode == .progress {
                        Text(L("Kattints egy színre a kiemeléséhez. Jobb klikkel az egész szín késznek jelölhető.", "Click a colour to highlight it. Right-click to mark the whole colour as done."))
                            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(spacing: 2) {
                        ForEach(p.palette.indices, id: \.self) { i in colorRow(p, i) }
                    }
                }

                Divider()
                HStack {
                    Button { model.save() } label: {
                        Label("PNG…", systemImage: "photo").frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut("s")
                    .help(L("Mentés PNG képként (⌘S). Az Előnézet nézetben a hímzett előnézetet menti.", "Save as PNG (⌘S). In Preview it saves the stitched preview."))
                    Button { model.savePDF() } label: {
                        Label("PDF…", systemImage: "doc.richtext").frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut("e")
                    .help(L("Nyomtatható PDF A4-es oldalakra bontva (⌘E)", "Printable PDF split into A4 pages (⌘E)"))
                }
                .controlSize(.large)
                .disabled(model.output == nil)

                if let e = model.errorText { Text(e).foregroundColor(.red).font(.callout) }

                Divider()
                Picker(L("Nyelv", "Language"), selection: $appLanguage) {
                    Text(L("Rendszer szerint", "System")).tag("system")
                    Text("Magyar").tag("hu")
                    Text("English").tag("en")
                }
                .pickerStyle(.menu)
                Text("© 2026 Zsolt Hoffmann · zsolthoffmann.com")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding()
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            Text(L("Minta", "Pattern")).font(.headline)
            Picker(L("Forma", "Shape"), selection: $model.shape) {
                Text(L("Eredeti", "Original")).tag(PatternShape.original)
                Text(L("Négyzet", "Square")).tag(PatternShape.square)
                Text(L("Kör", "Circle")).tag(PatternShape.circle)
            }
            .pickerStyle(.segmented)
            if model.shape != .original {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(L("Kivágás nagyítása", "Crop zoom"))
                        Spacer()
                        Text(String(format: "%.1f×", model.cropZoom)).monospacedDigit().foregroundColor(.secondary)
                    }
                    Slider(value: $model.cropZoom, in: 1...4)
                    Text(L("A kivágást a fenti képen húzással igazíthatod.", "Drag on the image above to adjust the crop."))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            sliderRow(model.shape == .circle ? L("Átmérő", "Diameter") : L("Szélesség", "Width"), $model.width, 10...300, L("öltés", "stitches"))
            sliderRow(L("Színek száma", "Number of colours"), $model.colors, 2...40, "")
            Divider()
            HStack {
                Text(L("Képjavítás", "Image adjustments")).font(.headline)
                Spacer()
                Button(L("Mind alap", "Reset all")) {
                    model.vivid = 1.25; model.contrast = 1.0; model.highlights = 0; model.shadows = 0
                }
                .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L("Élénkség", "Vibrance"))
                    Spacer()
                    Text(model.vivid >= 0.995 ? "+\(Int(((model.vivid - 1) * 100).rounded()))%"
                                              : "\(Int(((model.vivid - 1) * 100).rounded()))%")
                        .monospacedDigit().foregroundColor(.secondary)
                    Button(L("Alap", "Reset")) { model.vivid = 1.25 }
                        .controlSize(.small)
                        .disabled(abs(model.vivid - 1.25) < 0.01)
                }
                Slider(value: snapped($model.vivid, 0.05), in: 0.8...2.0)
                Text(L("A kicsinyítés és a színcsökkentés átlagol, ami tompítja a színeket – ez ellensúlyozza.", "Downscaling and colour reduction average colours, which dulls them – this compensates."))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L("Kontraszt", "Contrast"))
                    Spacer()
                    Text(model.contrast >= 0.995 ? "+\(Int(((model.contrast - 1) * 100).rounded()))%"
                                                 : "\(Int(((model.contrast - 1) * 100).rounded()))%")
                        .monospacedDigit().foregroundColor(.secondary)
                    Button(L("Alap", "Reset")) { model.contrast = 1.0 }
                        .controlSize(.small)
                        .disabled(abs(model.contrast - 1.0) < 0.01)
                }
                Slider(value: snapped($model.contrast, 0.05), in: 0.6...1.6)
            }
            adjustRow(L("Csúcsfények", "Highlights"), $model.highlights)
                .help(L("Jobbra: világosabb világos részek. Balra: a kiégett, túl világos részek visszahozása.", "Right: brighter highlights. Left: recover blown-out, overly bright areas."))
            adjustRow(L("Árnyékok", "Shadows"), $model.shadows)
                .help(L("Jobbra: a sötét részek kivilágosítása, hogy látszódjanak a részletek. Balra: mélyebb árnyékok.", "Right: lift dark areas to reveal detail. Left: deeper shadows."))
            Toggle(L("Szórt öltések csökkentése", "Reduce stray stitches"), isOn: $model.cleanup)
                .help(L("A környezetüktől elütő, magányos öltéseket a szomszédos színre cseréli.", "Replaces lone stitches that stand out from their surroundings with a neighbouring colour."))
            Toggle(L("DMC fonalszínek használata", "Use DMC thread colours"), isOn: $model.useDMC)
                .help(L("Minden színt a legközelebbi DMC hímzőfonalra cserél (CIEDE2000 színeltérés alapján).", "Replaces every colour with the closest DMC embroidery thread (CIEDE2000 colour difference)."))
            if model.useDMC {
                Text(L("Ha két szín ugyanarra a fonalra esik, összevonja őket, így kevesebb szín is lehet a beállítottnál.", "If two colours map to the same thread they are merged, so you may get fewer colours than set."))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Text(L("Megjelenés", "Appearance")).font(.headline)
            sliderRow(L("Cellaméret", "Cell size"), $model.cell, 10...40, "px")
            Toggle(L("Színes cellák", "Coloured cells"), isOn: $model.colored)
            Text(L("Kikapcsolva fekete-fehér, nyomtatóbarát minta készül – a színek a jelmagyarázatban maradnak.", "When off, you get a printer-friendly black-and-white chart – colours stay in the key."))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

            if let p = model.pattern {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(p.width) × \(p.height) " + L("öltés, \(p.palette.count) szín", "stitches, \(p.palette.count) colours"))
                    if p.shape == .circle {
                        Text(L("Ebből \(p.stitchCount) öltés esik a körbe", "\(p.stitchCount) of them fall inside the circle")).foregroundColor(.secondary)
                    }
                    Text(String(format: L("14-es aidán kb. %.1f × %.1f cm", "≈ %.1f × %.1f cm on 14-count Aida"),
                                Double(p.width) / 14 * 2.54, Double(p.height) / 14 * 2.54))
                        .foregroundColor(.secondary)
                }
                .font(.callout)
            }
        }
    }

    private func progressSummary(_ p: Pattern) -> some View {
        let total = p.stitchCount
        let doneN = model.totalDone
        return VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(L("Haladás", "Progress")).font(.headline)
            ProgressView(value: Double(doneN), total: Double(max(1, total)))
            Text("\(doneN) / \(total) " + L("öltés kész", "stitches done") + " (\(Int((Double(doneN) / Double(max(1, total)) * 100).rounded()))%)")
                .font(.callout).monospacedDigit()
            Text(L("Kattints vagy húzd végig az egeret a kész öltéseken – ezek eltűnnek, így csak a hátralévő rész látszik. Színfolt módban egy kattintás az egész összefüggő, azonos színű foltot jelöli. A „Kész részek” gombbal (⌘K) újra megmutathatod őket zöld pipával; így kattintva vissza is vonhatod egy jelölést.", "Click or drag across the stitches you have finished – they disappear, so only what is left remains visible. In Colour area mode one click marks the whole connected patch of that colour. Use “Done” (⌘K) to show them again with a green tick; click one to unmark it."))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L("A haladást a CraftDora automatikusan megjegyzi: ha ugyanazt a képet ugyanazokkal a beállításokkal nyitod meg, folytathatod.", "CraftDora remembers your progress automatically: open the same image with the same settings and you can carry on."))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(role: .destructive) { confirmClear = true } label: {
                Label(L("Összes jelölés törlése", "Clear all marks"), systemImage: "trash")
            }
            .controlSize(.small)
            .disabled(doneN == 0)
        }
    }

    private func colorRow(_ p: Pattern, _ i: Int) -> some View {
        let doneN = i < model.doneCounts.count ? model.doneCounts[i] : 0
        let selected = model.mode == .progress && model.highlight == i
        let inProgress = model.mode == .progress
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(cgColor: cgColor(p.palette[i])))
                .overlay(Text(symbol(i)).font(.system(size: 11, weight: .bold))
                    .foregroundColor(luminance(p.palette[i]) < 0.5 ? .white : .black))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.5)))
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                if let t = p.threads?[i] {
                    Text("DMC \(t.code)").font(.callout.bold())
                    Text(t.name).font(.caption).foregroundColor(.secondary).lineLimit(1)
                } else {
                    Text(hex(p.palette[i])).font(.callout.monospaced())
                }
                if inProgress {
                    ProgressView(value: Double(doneN), total: Double(max(1, p.counts[i])))
                        .controlSize(.small)
                }
            }
            Spacer()
            Text(inProgress ? "\(doneN)/\(p.counts[i])" : "\(p.counts[i])")
                .font(.caption).monospacedDigit().foregroundColor(.secondary)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.2) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            guard inProgress else { return }
            model.highlight = selected ? nil : i
        }
        .contextMenu {
            Button(L("Szín késznek jelölése", "Mark this colour as done")) { model.markColor(i, true) }
            Button(L("Szín jelöléseinek törlése", "Unmark this colour")) { model.markColor(i, false) }
        }
    }

    // MARK: Preview / Progress

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $model.mode) {
                    Text(L("Minta", "Pattern")).tag(ViewMode.preview)
                    Text(L("Előnézet", "Preview")).tag(ViewMode.stitched)
                    Text(L("Haladás", "Progress")).tag(ViewMode.progress)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 250)
                .help(L("Minta: a hímzőminta · Előnézet: így fog kinézni kihímezve · Haladás: kész öltések jelölése", "Pattern: the chart · Preview: how it will look stitched · Progress: mark finished stitches"))

                Divider().frame(height: 18)

                if model.mode != .progress {
                    Picker("", selection: $fit) {
                        Text(L("Ablakhoz igazítva", "Fit to window")).tag(true)
                        Text(L("Nagyítás", "Zoom")).tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 230)
                    if !fit {
                        Slider(value: $zoom, in: 0.1...3).frame(width: 150)
                        Text("\(Int(zoom * 100))%").monospacedDigit().foregroundColor(.secondary)
                    }
                } else {
                    Picker("", selection: $model.markMode) {
                        Text(L("Egyesével", "Single")).tag(MarkMode.single)
                        Text(L("Színfolt", "Colour area")).tag(MarkMode.region)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                    .help(L("Egyesével: kattintás vagy húzás. Színfolt: az összefüggő azonos színű terület egyszerre.", "Single: click or drag. Colour area: the whole connected area of the same colour at once."))
                    Image(systemName: "minus.magnifyingglass").foregroundColor(.secondary)
                    Slider(value: $progressZoom, in: 4...maxProgressZoom).frame(width: 130)
                    Image(systemName: "plus.magnifyingglass").foregroundColor(.secondary)
                    Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .help(L("Visszavonás (⌘Z)", "Undo (⌘Z)"))
                        .keyboardShortcut("z")
                        .disabled(!model.canUndo)
                    Toggle(isOn: $showDone) {
                        Label(L("Kész részek", "Done"), systemImage: showDone ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    .toggleStyle(.button)
                    .keyboardShortcut("k")
                    .help(showDone ? L("A kész öltések elrejtése (⌘K)", "Hide finished stitches (⌘K)") : L("A kész öltések megmutatása zöld pipával (⌘K)", "Show finished stitches with a green tick (⌘K)"))
                    if model.highlight != nil {
                        Button(L("Kiemelés ki", "Clear highlight")) { model.highlight = nil }
                    }
                }
                Spacer()
                if model.mode == .progress, let p = model.pattern {
                    Text("\(Int((Double(model.totalDone) / Double(max(1, p.stitchCount)) * 100).rounded()))% " + L("kész", "done"))
                        .monospacedDigit().foregroundColor(.secondary)
                }
            }
            .padding(8)
            Divider()
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if model.mode == .progress, model.pattern != nil {
                    ScrollView([.horizontal, .vertical]) {
                        ProgressGrid(model: model, zoom: min(progressZoom, maxProgressZoom), showDone: showDone)
                            .padding()
                    }
                } else if let img = (model.mode == .stitched ? model.stitchedImage : model.output) {
                    if fit {
                        Image(decorative: img, scale: 1).resizable().interpolation(.high).scaledToFit().padding()
                    } else {
                        ScrollView([.horizontal, .vertical]) {
                            Image(decorative: img, scale: 1).resizable().interpolation(.medium)
                                .frame(width: CGFloat(img.width) * zoom, height: CGFloat(img.height) * zoom)
                                .padding()
                        }
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 48))
                        Text(L("Nyiss meg vagy húzz ide egy képet", "Open or drop an image here")).font(.title3)
                    }
                    .foregroundColor(.secondary)
                }
                if model.busy {
                    ProgressView().padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}

// MARK: - App

/// About panel: version, copyright (Info.plist) and a clickable website link.
@MainActor
func showAboutPanel() {
    let credits = NSMutableAttributedString()
    let center = NSMutableParagraphStyle()
    center.alignment = .center
    let base: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor.secondaryLabelColor,
        .paragraphStyle: center,
    ]
    credits.append(NSAttributedString(string: L("Készítette: Zsolt Hoffmann\n", "Made by Zsolt Hoffmann\n"), attributes: base))
    var link = base
    link[.link] = URL(string: "https://zsolthoffmann.com")!
    link[.foregroundColor] = NSColor.linkColor
    credits.append(NSAttributedString(string: "zsolthoffmann.com", attributes: link))
    credits.append(NSAttributedString(
        string: L("\n\nDMC színadatok: Sharla Gelfand, MIT licenc.\nA DMC a DMC Corporation védjegye; a CraftDora nem kapcsolódik hozzájuk.", "\n\nDMC colour data: Sharla Gelfand, MIT licence.\nDMC is a trademark of DMC Corporation; CraftDora is not affiliated with it."),
        attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: center]))
    NSApplication.shared.orderFrontStandardAboutPanel(options: [
        .applicationName: "CraftDora",
        .credits: credits,
    ])
    NSApplication.shared.activate(ignoringOtherApps: true)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct CraftDoraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            ContentView().frame(minWidth: 880, minHeight: 580)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L("A CraftDora névjegye", "About CraftDora")) { showAboutPanel() }
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .undoRedo) {}   // ⌘Z belongs to the Progress view's Undo button
        }
    }
}
