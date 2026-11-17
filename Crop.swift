// © 2026 Zsolt Hoffmann – zsolthoffmann.com. Licensed under the GNU GPL v3 (see LICENSE).
// CraftDora – crop adjustment for the square / circle shapes

import SwiftUI

struct CropEditor: View {
    @ObservedObject var model: Model
    let image: CGImage

    @State private var dragStart: CGPoint?

    var body: some View {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let s = min(250 / iw, 170 / ih)
        let dw = iw * s, dh = ih * s
        let crop = cropRect(width: image.width, height: image.height, shape: model.shape,
                            cx: model.cropX, cy: model.cropY, zoom: model.cropZoom)

        ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1).resizable().frame(width: dw, height: dh)
            if let crop {
                let r = CGRect(x: crop.minX * s, y: crop.minY * s, width: crop.width * s, height: crop.height * s)
                let outline = model.shape == .circle ? Path(ellipseIn: r) : Path(r)
                Path { path in
                    path.addRect(CGRect(x: 0, y: 0, width: dw, height: dh))
                    path.addPath(outline)
                }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                outline.stroke(Color.white, lineWidth: 2)
            }
        }
        .frame(width: dw, height: dh)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard model.mode != .progress, let crop else { return }
                    if dragStart == nil {
                        // start from the centre actually in use (already clamped to the image)
                        dragStart = CGPoint(x: crop.midX / iw, y: crop.midY / ih)
                    }
                    guard let st = dragStart else { return }
                    let hx = Double(crop.width / iw) / 2, hy = Double(crop.height / ih) / 2
                    let nx = Double(st.x) + Double(v.translation.width / dw)
                    let ny = Double(st.y) + Double(v.translation.height / dh)
                    model.cropX = min(max(nx, hx), 1 - hx)
                    model.cropY = min(max(ny, hy), 1 - hy)
                }
                .onEnded { _ in dragStart = nil }
        )
        .help(model.shape == .original ? "" : L("Húzd a kijelölést a kivágás igazításához", "Drag the selection to adjust the crop"))
        .frame(maxWidth: .infinity)
    }
}
