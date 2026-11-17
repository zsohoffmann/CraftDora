// © 2026 Zsolt Hoffmann – zsolthoffmann.com. Licensed under the GNU GPL v3 (see LICENSE).
// CraftDora – Progress view: marking finished stitches

import SwiftUI

/// Stable (same across launches) identifier of a pattern – saved progress is tied to it.
func stableKey(_ p: Pattern) -> String {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    func mix(_ v: UInt64) {
        h ^= v
        h = h &* 0x0000_0100_0000_01B3
    }
    mix(UInt64(p.width))
    mix(UInt64(p.height))
    for l in p.labels { mix(UInt64(bitPattern: Int64(l))) }
    mix(UInt64(p.shape == .circle ? 2 : p.shape == .square ? 1 : 0))
    for c in p.palette {
        mix(UInt64(min(255, max(0, (c.x * 255).rounded()))))
        mix(UInt64(min(255, max(0, (c.y * 255).rounded()))))
        mix(UInt64(min(255, max(0, (c.z * 255).rounded()))))
    }
    return String(h, radix: 16)
}

struct ProgressGrid: View {
    @ObservedObject var model: Model
    let zoom: Double
    /// false: finished stitches fade out (almost disappear) · true: green overlay + white tick
    let showDone: Bool

    @State private var strokeValue: Bool?
    @State private var started = false

    var body: some View {
        if let p = model.pattern, let base = model.progressImage, model.done.count == p.labels.count {
            let s = CGFloat(zoom)
            Canvas { gc, _ in
                gc.draw(Image(decorative: base, scale: 1).interpolation(.medium),
                        in: CGRect(x: 0, y: 0, width: CGFloat(p.width) * s, height: CGFloat(p.height) * s))

                // Highlight: dim all other colours
                if let hl = model.highlight {
                    var dim = Path()
                    for i in p.labels.indices where p.labels[i] != hl {
                        dim.addRect(CGRect(x: CGFloat(i % p.width) * s, y: CGFloat(i / p.width) * s, width: s, height: s))
                    }
                    gc.fill(dim, with: .color(Color.white.opacity(0.75)))
                }

                // Finished stitches
                var fill = Path()
                var check = Path()
                for i in model.done.indices where model.done[i] {
                    let x = CGFloat(i % p.width) * s, y = CGFloat(i / p.width) * s
                    fill.addRect(CGRect(x: x, y: y, width: s, height: s))
                    if showDone {
                        check.move(to: CGPoint(x: x + s * 0.24, y: y + s * 0.53))
                        check.addLine(to: CGPoint(x: x + s * 0.42, y: y + s * 0.70))
                        check.addLine(to: CGPoint(x: x + s * 0.77, y: y + s * 0.31))
                    }
                }
                if showDone {
                    // 40% green + thick white tick (thin dark outline so it shows on light cells too)
                    gc.fill(fill, with: .color(Color(red: 0.13, green: 0.62, blue: 0.3).opacity(0.42)))
                    let lw = max(1.5, s * 0.15)
                    let style = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)
                    let outline = StrokeStyle(lineWidth: lw + max(1, s * 0.06), lineCap: .round, lineJoin: .round)
                    gc.stroke(check, with: .color(Color(red: 0.05, green: 0.3, blue: 0.12).opacity(0.55)), style: outline)
                    gc.stroke(check, with: .color(.white), style: style)
                } else {
                    // almost disappears: blends into the background, leaving only a faint trace
                    gc.fill(fill, with: .color(Color(nsColor: .underPageBackgroundColor).opacity(0.9)))
                }
            }
            .frame(width: CGFloat(p.width) * s, height: CGFloat(p.height) * s)
            .gesture(markGesture(p, s))
        } else {
            EmptyView()
        }
    }

    private func markGesture(_ p: Pattern, _ s: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let x = Int(floor(v.location.x / s)), y = Int(floor(v.location.y / s))
                let inside = x >= 0 && y >= 0 && x < p.width && y < p.height
                let idx = y * p.width + x
                if !started {
                    started = true
                    guard inside else { return }
                    if model.markMode == .region {
                        model.toggleRegion(idx)
                        return
                    }
                    strokeValue = !model.done[idx]
                }
                if let val = strokeValue, inside { model.setCell(idx, val) }
            }
            .onEnded { _ in
                if let val = strokeValue { model.endStroke(value: val) }
                strokeValue = nil
                started = false
            }
    }
}
