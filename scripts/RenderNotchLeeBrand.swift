import AppKit
import ImageIO
import UniformTypeIdentifiers

@main
enum RenderNotchLeeBrand {
    @MainActor static func main() throws {
        let assets = URL(fileURLWithPath: CommandLine.arguments[1])
        func render(width: Int, height: Int, opaque: Bool = false, to path: URL, drawing: (CGContext, CGRect) -> Void) throws {
            let color = CGColorSpace(name: CGColorSpace.sRGB)!
            let alpha = opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: color, bitmapInfo: alpha.rawValue)!
            context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
            drawing(context, CGRect(x: 0, y: 0, width: width, height: height))
            let destination = CGImageDestinationCreateWithURL(path as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            precondition(CGImageDestinationFinalize(destination))
        }
        let icon = assets.appendingPathComponent("AppIcon.appiconset")
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 2 ? "@2x" : ""
                try render(width: size * scale, height: size * scale, to: icon.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")) { context, bounds in
                    let card = bounds.insetBy(dx: bounds.width * 0.06, dy: bounds.height * 0.06)
                    context.setFillColor(CGColor(gray: 1, alpha: 1))
                    context.addPath(CGPath(roundedRect: card, cornerWidth: bounds.width * 0.20, cornerHeight: bounds.height * 0.20, transform: nil))
                    context.fillPath()
                    RedPandaDrawing.draw(context, in: bounds.insetBy(dx: bounds.width * 0.11, dy: bounds.height * 0.11))
                }
            }
        }
        // iOS/iPadOS: one full-bleed, opaque 1024 px icon; the system applies the mask.
        let iOSIcon = assets.deletingLastPathComponent().appendingPathComponent("iOSAssets.xcassets/AppIcon.appiconset")
        // The brand emerald (tokens.json canvas → surface, with an accent glow) behind the panda.
        try render(width: 1024, height: 1024, opaque: true, to: iOSIcon.appendingPathComponent("icon_1024.png")) { context, bounds in
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let base = CGGradient(colorsSpace: space, colors: [CGColor(red: 0, green: 0.20, blue: 0.17, alpha: 1),
                                                               CGColor(red: 0.004, green: 0.11, blue: 0.094, alpha: 1)] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(base, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: bounds.height), options: [])
            let glow = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.36, green: 0.71, blue: 0.57, alpha: 0.55),
                                                               CGColor(red: 0.36, green: 0.71, blue: 0.57, alpha: 0)] as CFArray, locations: [0, 1])!
            context.drawRadialGradient(glow, startCenter: CGPoint(x: bounds.midX, y: bounds.height * 0.52), startRadius: 0,
                                       endCenter: CGPoint(x: bounds.midX, y: bounds.height * 0.52), endRadius: bounds.width * 0.48, options: [])
            RedPandaDrawing.draw(context, in: bounds.insetBy(dx: bounds.width * 0.15, dy: bounds.height * 0.15))
        }
        let menu = assets.appendingPathComponent("MenuBarIcon.imageset")
        for scale in 1...3 {
            let suffix = scale == 1 ? "" : "@\(scale)x"
            try render(width: 24 * scale, height: 18 * scale, to: menu.appendingPathComponent("menubar\(suffix).png")) { ctx, _ in
                ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                ctx.setLineWidth(1.3); ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
                ctx.beginPath(); ctx.move(to: CGPoint(x: 4, y: 6))
                ctx.addQuadCurve(to: CGPoint(x: 4, y: 1.5), control: CGPoint(x: 1, y: 0))
                ctx.addLine(to: CGPoint(x: 8, y: 4))
                ctx.addQuadCurve(to: CGPoint(x: 16, y: 4), control: CGPoint(x: 12, y: 2))
                ctx.addLine(to: CGPoint(x: 20, y: 1.5))
                ctx.addQuadCurve(to: CGPoint(x: 20, y: 6), control: CGPoint(x: 23, y: 0))
                ctx.addQuadCurve(to: CGPoint(x: 20, y: 13), control: CGPoint(x: 25, y: 11))
                ctx.addQuadCurve(to: CGPoint(x: 4, y: 13), control: CGPoint(x: 12, y: 19))
                ctx.addQuadCurve(to: CGPoint(x: 4, y: 6), control: CGPoint(x: 0, y: 11)); ctx.strokePath()
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                for x in [7.0, 16.0] { ctx.fillEllipse(in: CGRect(x: x, y: 8, width: 1.7, height: 2)) }
                ctx.fillEllipse(in: CGRect(x: 11, y: 11.2, width: 2.5, height: 1.7))
            }
        }
        let preview = URL(fileURLWithPath: "/tmp/notchlee-red-panda-preview.png")
        try render(width: 1000, height: 370, to: preview) { context, bounds in
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
            for (index, state) in [BotState.idle, .thinking, .finished].enumerated() {
                RedPandaDrawing.draw(context, in: CGRect(x: 20 + index * 330, y: 20, width: 320, height: 320), state: state, time: 1)
            }
        }
        try render(width: 360, height: 180, to: URL(fileURLWithPath: "/tmp/notchlee-cursor-preview.png")) { context, bounds in
            for (index, background) in [CGColor(red: 0.48, green: 0.64, blue: 0.68, alpha: 1), CGColor(gray: 0.08, alpha: 1), CGColor(gray: 1, alpha: 1)].enumerated() {
                context.setFillColor(background)
                context.fill(CGRect(x: index * 120, y: 0, width: 120, height: 180))
                context.saveGState()
                context.translateBy(x: CGFloat(index * 120 + 36), y: 65)
                context.scaleBy(x: 2, y: 2)
                AgentPointerDrawing.draw(context)
                context.restoreGState()
            }
        }
        print("Monochrome red panda icons, mascot poses and outline cursor preview rendered.")
    }
}
