import SwiftUI

/// Original black-and-white line art. The broad cheeks, pointed ears and ringed
/// tail identify the red panda without colors, shading, textures or accessories.
enum RedPandaDrawing {
    static func draw(_ ctx: CGContext, in rect: CGRect, state: BotState = .idle,
                     time: Double = 0, look: CGPoint = .zero, cheerful: Bool = false, blinking: Bool = false) {
        let ink = CGColor(gray: 0, alpha: 1)
        let paper = CGColor(gray: 1, alpha: 1)
        let happy = cheerful || state == .finished
        ctx.saveGState()
        let scale = min(rect.width, rect.height) / 100
        ctx.translateBy(x: rect.midX - 50 * scale, y: rect.midY - 50 * scale)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 48, y: 58)
        ctx.rotate(by: state == .question ? 0.09 :
            state == .thinking ? -0.05 + sin(time * 1.1) * 0.025 :
            state == .working ? sin(time * 2) * 0.035 : 0)
        ctx.translateBy(x: -48, y: -58 + sin(time * 1.5) * 0.35)
        ctx.setLineWidth(2.8)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(ink)

        func outline(_ path: CGPath) {
            ctx.addPath(path); ctx.setFillColor(paper); ctx.setStrokeColor(ink)
            ctx.drawPath(using: .fillStroke)
        }
        func curve(_ from: CGPoint, _ control: CGPoint, _ to: CGPoint) {
            ctx.beginPath(); ctx.move(to: from); ctx.addQuadCurve(to: to, control: control); ctx.strokePath()
        }

        // Three simple rings on a broad curled tail; its interior remains white.
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: 62, y: 83))
        tail.addCurve(to: CGPoint(x: 92, y: 61), control1: CGPoint(x: 87, y: 95), control2: CGPoint(x: 101, y: 80))
        tail.addCurve(to: CGPoint(x: 80, y: 38), control1: CGPoint(x: 89, y: 49), control2: CGPoint(x: 86, y: 37))
        tail.addCurve(to: CGPoint(x: 75, y: 49), control1: CGPoint(x: 74, y: 35), control2: CGPoint(x: 70, y: 42))
        tail.addCurve(to: CGPoint(x: 63, y: 74), control1: CGPoint(x: 88, y: 69), control2: CGPoint(x: 81, y: 77))
        tail.closeSubpath(); outline(tail)
        ctx.saveGState(); ctx.addPath(tail); ctx.clip()
        curve(CGPoint(x: 71, y: 51), CGPoint(x: 82, y: 57), CGPoint(x: 93, y: 49))
        curve(CGPoint(x: 78, y: 65), CGPoint(x: 87, y: 70), CGPoint(x: 99, y: 64))
        curve(CGPoint(x: 72, y: 77), CGPoint(x: 80, y: 85), CGPoint(x: 79, y: 91))
        ctx.restoreGState()

        // One rounded body silhouette, with two small feet.
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 31, y: 52))
        body.addCurve(to: CGPoint(x: 28, y: 77), control1: CGPoint(x: 25, y: 60), control2: CGPoint(x: 25, y: 70))
        body.addCurve(to: CGPoint(x: 29, y: 90), control1: CGPoint(x: 21, y: 82), control2: CGPoint(x: 21, y: 89))
        body.addQuadCurve(to: CGPoint(x: 40, y: 86), control: CGPoint(x: 39, y: 94))
        body.addQuadCurve(to: CGPoint(x: 55, y: 86), control: CGPoint(x: 47, y: 89))
        body.addCurve(to: CGPoint(x: 67, y: 87), control1: CGPoint(x: 59, y: 94), control2: CGPoint(x: 72, y: 93))
        body.addQuadCurve(to: CGPoint(x: 65, y: 77), control: CGPoint(x: 69, y: 82))
        body.addQuadCurve(to: CGPoint(x: 64, y: 53), control: CGPoint(x: 73, y: 65))
        body.closeSubpath(); outline(body)

        if happy {
            ctx.saveGState(); ctx.translateBy(x: 29, y: 65)
            ctx.rotate(by: sin(time * 5) * 0.16)
            let arm = CGMutablePath()
            arm.move(to: CGPoint(x: 2, y: 4))
            arm.addCurve(to: CGPoint(x: -16, y: -15), control1: CGPoint(x: -9, y: 1), control2: CGPoint(x: -15, y: -5))
            arm.addCurve(to: CGPoint(x: -24, y: -11), control1: CGPoint(x: -18, y: -22), control2: CGPoint(x: -27, y: -19))
            arm.addQuadCurve(to: CGPoint(x: 0, y: 12), control: CGPoint(x: -21, y: 5))
            outline(arm); ctx.restoreGState()
        } else {
            curve(CGPoint(x: 31, y: 64), CGPoint(x: 25, y: 74), CGPoint(x: 33, y: 76))
        }
        curve(CGPoint(x: 63, y: 65), CGPoint(x: 68, y: 74), CGPoint(x: 61, y: 76))

        // Head and ears share one uninterrupted outline.
        let head = CGMutablePath()
        head.move(to: CGPoint(x: 20, y: 32))
        head.addCurve(to: CGPoint(x: 22, y: 12), control1: CGPoint(x: 15, y: 25), control2: CGPoint(x: 15, y: 8))
        head.addQuadCurve(to: CGPoint(x: 34, y: 22), control: CGPoint(x: 29, y: 13))
        head.addQuadCurve(to: CGPoint(x: 61, y: 22), control: CGPoint(x: 47, y: 16))
        head.addQuadCurve(to: CGPoint(x: 76, y: 12), control: CGPoint(x: 74, y: 8))
        head.addQuadCurve(to: CGPoint(x: 77, y: 32), control: CGPoint(x: 82, y: 20))
        head.addQuadCurve(to: CGPoint(x: 80, y: 46), control: CGPoint(x: 86, y: 40))
        head.addLine(to: CGPoint(x: 83, y: 49))
        head.addLine(to: CGPoint(x: 76, y: 52))
        head.addCurve(to: CGPoint(x: 22, y: 52), control1: CGPoint(x: 66, y: 67), control2: CGPoint(x: 32, y: 66))
        head.addLine(to: CGPoint(x: 15, y: 49))
        head.addLine(to: CGPoint(x: 19, y: 45))
        head.addQuadCurve(to: CGPoint(x: 20, y: 32), control: CGPoint(x: 12, y: 39))
        head.closeSubpath(); outline(head)

        ctx.setLineWidth(2.2)
        curve(CGPoint(x: 23, y: 25), CGPoint(x: 19, y: 14), CGPoint(x: 29, y: 25))
        curve(CGPoint(x: 66, y: 25), CGPoint(x: 77, y: 14), CGPoint(x: 73, y: 25))
        curve(CGPoint(x: 25, y: 40), CGPoint(x: 26, y: 46), CGPoint(x: 31, y: 48))
        curve(CGPoint(x: 70, y: 40), CGPoint(x: 69, y: 46), CGPoint(x: 64, y: 48))

        let blink = blinking || (time > 0 && time.truncatingRemainder(dividingBy: 4.6) < 0.15)
        let dx = max(-1.5, min(1.5, look.x * 1.5))
        let dy = max(-1, min(1, look.y))
        for x: CGFloat in [34, 61] {
            if happy {
                curve(CGPoint(x: x - 3, y: 41), CGPoint(x: x, y: 35), CGPoint(x: x + 3, y: 41))
            } else if blink || state == .sleeping {
                curve(CGPoint(x: x - 3, y: 40), CGPoint(x: x, y: 43), CGPoint(x: x + 3, y: 40))
            } else {
                ctx.setFillColor(ink)
                ctx.fillEllipse(in: CGRect(x: x - 1.8 + dx, y: 38 + dy, width: 3.6, height: 4))
            }
        }
        outline(CGPath(ellipseIn: CGRect(x: 40, y: 43, width: 15, height: 14), transform: nil))
        ctx.setFillColor(ink); ctx.fillEllipse(in: CGRect(x: 45, y: 46, width: 5, height: 3))
        ctx.setLineWidth(1.8)
        curve(CGPoint(x: 44, y: 51), CGPoint(x: 47.5, y: 55), CGPoint(x: 51, y: 51))
        if state == .thinking || state == .question {
            ctx.setLineWidth(2.8)
            outline(CGPath(ellipseIn: CGRect(x: 56, y: 56, width: 11, height: 13), transform: nil))
        }
        ctx.restoreGState()
    }
}

/// Hosts set this when their surface is not on screen (display asleep, panel occluded).
extension EnvironmentValues {
    @Entry var redPandaAnimationsPaused = false
}

/// Continuous motion only while the panda is busy (working, thinking or
/// cheering). At rest it is a static frame with an occasional one-shot blink,
/// so a resting island does not redraw every frame.
struct RedPandaView: View {
    var state: BotState = .idle
    var look = CGPoint.zero
    var paused = false
    var cheerful = false
    /// Mini pandas stay still at rest; only the main character blinks.
    var blinks = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.redPandaAnimationsPaused) private var hostPaused
    @State private var blinking = false

    private var still: Bool { paused || reduceMotion || hostPaused }
    private var moving: Bool { !still && (state == .working || state == .thinking || cheerful) }
    private var blinkScheduled: Bool { blinks && !still && !moving && state != .sleeping }

    var body: some View {
        Group {
            if moving {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    canvas(time: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                canvas(time: 0)
            }
        }
        .task(id: blinkScheduled) {
            blinking = false
            guard blinkScheduled else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(4.45), tolerance: .milliseconds(500)) } catch { return }
                blinking = true
                do { try await Task.sleep(for: .milliseconds(150)) } catch { blinking = false; return }
                blinking = false
            }
        }
        .accessibilityLabel("OmniFlow red panda, \(state.rawValue)")
    }

    private func canvas(time: Double) -> some View {
        Canvas { context, size in
            context.withCGContext { cg in
                RedPandaDrawing.draw(cg, in: CGRect(origin: .zero, size: size), state: state,
                                     time: time, look: look, cheerful: cheerful, blinking: blinking)
            }
        }
    }
}
