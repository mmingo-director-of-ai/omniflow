import SwiftUI

/// Top-level SwiftUI view rendered inside the full-screen transparent panel.
/// The island follows its saved position; everything else is transparent and click-through.
/// Note: drag-drop is handled at the AppKit level in IslandWindowController (FileDropNSView),
/// not in SwiftUI, to avoid interfering with SwiftUI hit-testing.
struct IslandRootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        GeometryReader { geometry in
            let (width, height) = islandSize(mode: state.mode, view: state.view,
                                            nw: state.notchWidth, nh: state.notchHeight,
                                            vertical: state.islandEdge.isVertical,
                                            agentCount: state.tasks.count)
            let frame = IslandDockLayout(panelSize: geometry.size,
                                         islandSize: CGSize(width: width, height: height),
                                         edge: state.islandEdge, offset: state.islandXOffset).frame
            Group {
                if usesVerticalSessionLayout(mode: state.mode, view: state.view,
                                             vertical: state.islandEdge.isVertical) {
                    VerticalIslandContainer(state: state)
                } else {
                    IslandContainer(state: state)
                }
            }
            .position(x: frame.midX, y: frame.midY)
        }
        .ignoresSafeArea()
        .tint(NotchLeeTheme.accent)
    }
}

// MARK: - Island container

struct IslandContainer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var state: AppState
    @AppStorage("wakePhraseEnabled") private var wakeEnabled = false
    @State private var islandWidth:  CGFloat = IslandConst.notchWidth
    @State private var islandHeight: CGFloat = IslandConst.notchHeight
    @State private var cornerRadius: CGFloat = IslandConst.roundedCorner
    // topRadius > 0 → convex expanded corners; < 0 → concave ear cutouts
    @State private var islandTopRadius: CGFloat = 0
    // Concave flare where the island meets the top screen edge, like the hardware notch.
    @State private var islandFlare: CGFloat = 0
    @State private var greetNotif: Bool = false

    // Droplet morph: a transient squash/stretch applied as the island expands,
    // for a liquid, iPad-style "drop" feel (pairs with the Liquid Glass shape morph).
    @State private var dropletPhase: CGFloat = 0

    private var openSpring: Animation { reduceMotion ? .linear(duration: 0) : .spring(response: 0.5, dampingFraction: 0.72) }
    private var closeEase: Animation { reduceMotion ? .linear(duration: 0) : .timingCurve(0.45, 0, 0.2, 1, duration: 0.34) }
    // Bouncy, loose spring so the morph reads as liquid rather than a stiff resize.
    private var dropletSpring: Animation { reduceMotion ? .linear(duration: 0) : .spring(duration: 0.6, bounce: 0.46) }

    private var chatPromptHeight: CGFloat {
        let base: CGFloat = 240
        let perMsg: CGFloat = 40
        return min(300, base + CGFloat(0) * perMsg)
    }

    /// Pixels the content must be pushed down to clear the concave ear transparent area.
    /// = 0 in expanded mode (no ears), = earRadius in compact/notch mode.
    private var earOffset: CGFloat { max(0, -islandTopRadius) }

    var body: some View {
        // Canvas active during drag-over (.upload), post-drop animation (.uploading),
        // AND choose overlay (.choose) — canvas handles the full sequence through user action.
        // Engine deactivates when user clicks a canvas choose button or navigates away.
        let uploadActive = state.mode == .expanded
            && UploadSequenceEngine.shared.isActive
            && (state.view == .upload || state.view == .uploading || state.view == .choose)

        let greetingActive = state.mode == .expanded && state.view == .greeting

        return ZStack(alignment: .topLeading) {
            // Island background: Liquid Glass (macOS 26) or opaque black.
            // When glass is on, the shape morphs fluidly as width/height animate on
            // expand/collapse, giving the iPad-style liquid feel.
            if state.liquidGlass {
                IslandShape(width: islandWidth, height: islandHeight,
                            cornerRadius: cornerRadius, topRadius: islandTopRadius, flare: islandFlare)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.black.opacity(0.62)),
                                 in: IslandShape(width: islandWidth, height: islandHeight,
                                                 cornerRadius: cornerRadius, topRadius: islandTopRadius, flare: islandFlare))
            } else {
                IslandShape(width: islandWidth, height: islandHeight,
                            cornerRadius: cornerRadius, topRadius: islandTopRadius, flare: islandFlare)
                    .fill(Color.black)
            }

            // Content
            if state.mode == .expanded {
                if greetingActive {
                    // Greeting canvas: fixed 640-wide, centered by offset so x=320 aligns with island center
                    GreetingCanvasView(state: state)
                        .frame(width: IslandConst.expandedWidth, height: 150)
                        .offset(x: (islandWidth - IslandConst.expandedWidth) / 2)
                        .clipShape(IslandShape(width: islandWidth, height: islandHeight,
                                              cornerRadius: cornerRadius, topRadius: islandTopRadius, flare: islandFlare))
                        .transition(.opacity)
                } else if uploadActive {
                    ZStack(alignment: .topLeading) {
                        UploadCanvasView(state: state)
                            .frame(width: islandWidth, height: islandHeight)
                            .clipShape(IslandShape(width: islandWidth, height: islandHeight,
                                                  cornerRadius: cornerRadius, topRadius: islandTopRadius, flare: islandFlare))
                        // Header overlaid: canvas CARD_Y=42 aligns exactly with header bottom,
                        // matching normal view proportions (8pt top + 34pt header + card + 10pt bottom).
                        IslandHeader(state: state)
                            .frame(width: islandWidth, height: 34)
                            .offset(y: 8)
                    }
                    .transition(.opacity)
                } else {
                    IslandContentView(state: state)
                        .frame(width: islandWidth, height: islandHeight - earOffset)
                        .offset(y: earOffset)
                        .clipShape(IslandShape(width: islandWidth, height: islandHeight,
                                              cornerRadius: cornerRadius, topRadius: islandTopRadius, flare: islandFlare))
                        .transition(.opacity)
                }
            }

            // Single BotPlacement — always alive in the view tree so spring animations
            // fire from the current position (e.g. choose at 60,101) when canvas deactivates.
            // Hidden during upload canvas or greeting (both draw their own Mochi).
            BotPlacement(state: state, islandW: islandWidth, islandH: islandHeight)
                // Keep idle animations inside the resting strip. Expanded views
                // retain the panel's full height for particles and hands.
                .mask(alignment: .topLeading) {
                    Rectangle().frame(width: islandWidth,
                                      height: state.mode == .expanded ? 320 : islandHeight)
                }
                .opacity(uploadActive || greetingActive ? 0 : 1)
                .animation(.easeInOut(duration: 0.25), value: uploadActive || greetingActive)

            // Mounted only while an auto-close can actually run; otherwise it has no clock.
            if state.mode == .expanded && !state.isPinned && state.view != .voice && state.view != .workspace {
                CountdownBar(state: state, islandW: islandWidth)
            }

            Group {
                if state.mode == .compact {
                    if wakeEnabled {
                        WakeStatusIndicator()
                            .position(x: 65, y: islandHeight / 2)
                    }
                    CompactTrailingSlot(state: state)
                        .scaleEffect(IslandRestingLayout(width: islandWidth, height: islandHeight).miniGridScale)
                        .position(x: islandWidth - 40, y: islandHeight / 2)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: state.mode == .compact)
        }
        .frame(width: islandWidth, height: islandHeight, alignment: .topLeading)
        // Droplet morph: anchored at the notch, the island briefly stretches down
        // and pinches in, then settles — a liquid "drop" forming on expand.
        .scaleEffect(x: 1 - dropletPhase * 0.08, y: 1 + dropletPhase * 0.18, anchor: .top)
        .onChange(of: state.mode) { oldMode, newMode in
            let shrinking = modeOrder(newMode) < modeOrder(oldMode)
            let expanding = newMode == .expanded && !shrinking
            let anim = shrinking ? closeEase : (expanding ? dropletSpring : openSpring)
            let (w, h) = islandSize(mode: newMode, view: state.view,
                                    progress: state.uploadProgress,
                                    nw: state.notchWidth, nh: state.notchHeight)
            let cr  = newMode == .expanded ? IslandConst.expandedCorner : IslandConst.roundedCorner
            let tr: CGFloat = 0
            if expanding && !reduceMotion {
                // Pop to stretched instantly, then settle on the next tick so the
                // scale animates 1.13→1.0 while the size springs open.
                dropletPhase = 1
                DispatchQueue.main.async {
                    withAnimation(dropletSpring) { dropletPhase = 0 }
                }
            }
            withAnimation(anim) {
                islandWidth      = w
                islandHeight     = (newMode == .expanded && state.view == .prompt) ? chatPromptHeight : h
                cornerRadius     = cr
                islandTopRadius  = tr
                islandFlare      = flare(for: newMode)
            }
        }
        .onChange(of: state.islandEdge) { _, _ in
            withAnimation(openSpring) { islandFlare = flare(for: state.mode) }
        }
        .onChange(of: state.view) { _, newView in
            guard state.mode == .expanded else { return }
            // Deactivate engine if user navigates outside the upload flow
            let uploadViews: Set<IslandView> = [.upload, .uploading, .choose]
            if UploadSequenceEngine.shared.isActive && !uploadViews.contains(newView) {
                UploadSequenceEngine.shared.deactivate()
            }
            let (w, h) = islandSize(mode: .expanded, view: newView,
                                    progress: state.uploadProgress,
                                    nw: state.notchWidth, nh: state.notchHeight)
            withAnimation(openSpring) {
                islandWidth  = w
                islandHeight = newView == .prompt ? chatPromptHeight : h
            }
        }
        .onAppear {
            let (w, h) = islandSize(mode: state.mode, view: state.view,
                                    progress: state.uploadProgress,
                                    nw: state.notchWidth, nh: state.notchHeight)
            islandWidth      = w
            islandHeight     = state.view == .prompt ? chatPromptHeight : h
            cornerRadius     = state.mode == .expanded ? IslandConst.expandedCorner : IslandConst.roundedCorner
            islandTopRadius  = 0
            islandFlare      = flare(for: state.mode)
        }
        .onReceive(NotificationCenter.default.publisher(for: .botGreet)) { _ in
            greetNotif.toggle()
        }
    }

    private func flare(for mode: IslandMode) -> CGFloat {
        guard state.islandEdge == .top else { return 0 }
        switch mode { case .hidden: return 0; case .compact: return 9; case .expanded: return 16 }
    }

    private func modeOrder(_ m: IslandMode) -> Int {
        switch m { case .hidden: return 0; case .compact: return 1; case .expanded: return 2 }
    }
}

// MARK: - Island shape
//
// topRadius > 0  → convex rounded top corners (expanded mode)
// topRadius < 0  → concave ear cutouts, |topRadius| = ear radius (compact/notch mode)
// topRadius = 0  → sharp top corners (transient during animation)

struct IslandShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat   // bottom corners
    var topRadius: CGFloat      // see above
    /// > 0: the top corners curve down and out into the screen edge (drawn outside the frame).
    var flare: CGFloat = 0

    var animatableData: AnimatablePair<AnimatablePair<AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>, CGFloat>, CGFloat> {
        get { .init(.init(.init(.init(width, height), cornerRadius), topRadius), flare) }
        set {
            width        = newValue.first.first.first.first
            height       = newValue.first.first.first.second
            cornerRadius = newValue.first.first.second
            topRadius    = newValue.first.second
            flare        = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let cr = max(0, cornerRadius)
        var p  = Path()

        if flare > 0.5 && topRadius >= 0 {
            // ── Flared top: concave fillets blend the island into the screen edge ──
            let f = min(flare, height / 2)
            p.move(to: CGPoint(x: -f, y: 0))
            p.addLine(to: CGPoint(x: width + f, y: 0))
            p.addCurve(to: CGPoint(x: width, y: f),
                       control1: CGPoint(x: width + f * 0.42, y: 0),
                       control2: CGPoint(x: width, y: f * 0.42))
            p.addLine(to: CGPoint(x: width, y: height - cr))
            p.addArc(center: CGPoint(x: width - cr, y: height - cr), radius: cr,
                     startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: cr, y: height))
            p.addArc(center: CGPoint(x: cr, y: height - cr), radius: cr,
                     startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: CGPoint(x: 0, y: f))
            p.addCurve(to: CGPoint(x: -f, y: 0),
                       control1: CGPoint(x: 0, y: f * 0.42),
                       control2: CGPoint(x: -f * 0.42, y: 0))
        } else if topRadius >= 0 {
            // ── Convex rounded top corners (expanded) ──────────────────────────
            let tr = min(topRadius, min(width / 2, height / 2))
            p.move(to: CGPoint(x: tr, y: 0))
            p.addLine(to: CGPoint(x: width - tr, y: 0))
            // Top-right convex corner
            p.addArc(center: CGPoint(x: width - tr, y: tr), radius: tr,
                     startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            // Right edge
            p.addLine(to: CGPoint(x: width, y: height - cr))
            // Bottom-right corner
            p.addArc(center: CGPoint(x: width - cr, y: height - cr), radius: cr,
                     startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            // Bottom edge
            p.addLine(to: CGPoint(x: cr, y: height))
            // Bottom-left corner
            p.addArc(center: CGPoint(x: cr, y: height - cr), radius: cr,
                     startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            // Left edge
            p.addLine(to: CGPoint(x: 0, y: tr))
            // Top-left convex corner
            p.addArc(center: CGPoint(x: tr, y: tr), radius: tr,
                     startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        } else {
            // ── Concave ear cutouts (compact / notch) ─────────────────────────
            let er = -topRadius   // positive ear radius
            p.move(to: CGPoint(x: 0, y: 0))
            // Top-left ear
            p.addArc(center: CGPoint(x: 0, y: er), radius: er,
                     startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
            // Top edge
            p.addLine(to: CGPoint(x: width - er, y: er))
            // Top-right ear
            p.addArc(center: CGPoint(x: width, y: er), radius: er,
                     startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            // Right edge
            p.addLine(to: CGPoint(x: width, y: height - cr))
            // Bottom-right corner
            p.addArc(center: CGPoint(x: width - cr, y: height - cr), radius: cr,
                     startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            // Bottom edge
            p.addLine(to: CGPoint(x: cr, y: height))
            // Bottom-left corner
            p.addArc(center: CGPoint(x: cr, y: height - cr), radius: cr,
                     startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            // Left edge back to top-left corner
            p.addLine(to: CGPoint(x: 0, y: 0))
        }

        p.closeSubpath()
        return p
    }
}

// MARK: - Bot placement helper

struct BotPlacement: View {
    @ObservedObject var state: AppState
    let islandW: CGFloat
    let islandH: CGFloat

    var body: some View {
        let (cx, cy, diameter, opacity) = botPosition(mode: state.mode, view: state.view, islandW: islandW, islandH: islandH, uploadProgress: state.uploadProgress, hasNotch: state.hasNotch, vertical: state.islandEdge.isVertical)
        let canvasSize = diameter / 0.6
        let overhang: CGFloat = 40
        let isUploading = state.view == .uploading

        Group {
            // No glow in uploading mode — the tiny dot doesn't need it
            if state.mode == .expanded && !isUploading {
                Circle()
                    .fill(RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: botGlowColor(state.effectiveState), location: 0),
                            .init(color: .clear, location: 0.62)
                        ]),
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter * 1.1
                    ))
                    .frame(width: diameter * 2.2, height: diameter * 2.2)
                    .blur(radius: 6)
                    .opacity(botGlowOpacity(state.effectiveState))
                    .position(x: cx, y: cy)
                    .animation(.easeInOut(duration: 0.4), value: state.effectiveState)
            }

            // Uploading: no particle overhang (no hearts during upload), positioned directly at cy.
            // BotEngine cy = H/2 + 0 + oy*R + R*0.06 ≈ H/2 (body centered in canvas).
            // With .position(x:y:) placing the frame center at (uploadCx, cy), bot is at cy ✓.
            //
            // Normal: extra 40pt canvas at top for heart particles; position offset up by 20pt;
            // BotEngine compensates with cy = H/2 + particleOverhang/2 + oy*R + R*0.06.
            if isUploading {
                TimelineView(.animation) { tl in
                    let elapsed: Double = {
                        guard let start = state.uploadStartTime else { return 0 }
                        return tl.date.timeIntervalSince(start)
                    }()
                    let t = min(1.0, max(0, elapsed / state.uploadDuration))
                    // cx = 36 + 526*t: bot center at fill right edge (bar left=36, width=526)
                    let uploadCx = 36 + CGFloat(t * (2 - t)) * 526
                    BotCanvasView(state: state, particleOverhang: 0)
                        .frame(width: canvasSize, height: canvasSize)
                        .opacity(state.isDraggingBot ? 0 : opacity)
                        .position(x: uploadCx, y: cy)
                }
                .transition(.scale(scale: 0.01, anchor: .center).combined(with: .opacity))
            } else {
                BotCanvasView(state: state, particleOverhang: overhang)
                    .frame(width: canvasSize, height: canvasSize + overhang)
                    .opacity(state.isDraggingBot ? 0 : opacity)
                    .position(x: cx, y: cy - overhang / 2)
                    .animation(.spring(response: 0.5, dampingFraction: 0.72), value: cx)
                    .animation(.spring(response: 0.5, dampingFraction: 0.72), value: cy)
                    .animation(.spring(response: 0.5, dampingFraction: 0.72), value: canvasSize)
                    .transition(.scale(scale: 0.01, anchor: .center).combined(with: .opacity))
            }
        }
        // Branch switch (uploading ↔ normal) animates with a fast spring: uploading dot
        // scales out at bar-end while normal bot scales in at choose position.
        .animation(.spring(response: 0.36, dampingFraction: 0.72), value: isUploading)
        // Slap, drag, and hover are handled by the AppKit NSEvent monitor in
        // IslandWindowController — not SwiftUI gestures — so this is safe.
        .allowsHitTesting(false)
    }

    private func botGlowColor(_ s: BotState) -> Color {
        switch s {
        case .working:   return Color(hex: "#3B9EFF")
        case .thinking:  return Color(hex: "#A78BFA")
        case .searching: return Color(hex: "#6366F1")
        case .approval:  return Color(hex: "#F5A524")
        case .error:     return Color(hex: "#F4505E")
        case .finished:  return Color(hex: "#34D399")
        case .ratelimit: return Color(hex: "#F59E0B")
        default:         return Color.white
        }
    }

    private func botGlowOpacity(_ s: BotState) -> Double {
        switch s {
        case .idle, .sleeping: return 0.15
        case .dizzy:           return 0.0
        default:               return 0.65
        }
    }
}

func botPosition(mode: IslandMode, view: IslandView, islandW: CGFloat, islandH: CGFloat, uploadProgress: Double, hasNotch: Bool = true, vertical: Bool = false) -> (CGFloat, CGFloat, CGFloat, Double) {
    if vertical && mode == .expanded && view == .overview {
        let center = IslandSessionLayout.botCenter
        return (IslandSessionLayout.padding + center.x,
                IslandSessionLayout.headerExtent + IslandSessionLayout.padding + center.y,
                IslandSessionLayout.botDiameter, 1)
    }
    let resting = IslandRestingLayout(width: islandW, height: islandH)
    switch mode {
    case .hidden:
        return hasNotch ? (46, 16, 6, 0)
            : (islandW / 2, resting.botCenterY, resting.botDiameter, 1)
    case .compact: return (40, resting.botCenterY, resting.botDiameter, 1)
    case .expanded:
        let layout = IslandConst.viewLayouts[view]!
        let diameter = layout.botDiameter
        // Uploading: Mochi dot rides the leading edge of the progress fill.
        // Bar in island coords: left=36, width=526. cx = 36 + progress*526 (dot center at fill right edge).
        // cy comes from ViewLayout.botY (bar center in island coords).
        if view == .uploading {
            let cx = 36 + CGFloat(uploadProgress) * 526
            return (cx, layout.botY ?? 103, diameter, 1)
        }
        let cx = layout.botX
        let cy: CGFloat
        if let fixedY = layout.botY {
            cy = fixedY
        } else {
            // Content starts below the header and ends above the bottom padding.
            let headerBottom: CGFloat = 42
            cy = headerBottom + (islandH - headerBottom - 10) / 2
        }
        return (cx, cy, diameter, 1)
    }
}

// MARK: - Countdown bar

struct CountdownBar: View {
    @ObservedObject var state: AppState
    let islandW: CGFloat
    @State private var shrink: CountdownShrink.Plan?

    var body: some View {
        GeometryReader { _ in
            if let shrink {
                // A new activity timestamp replaces the view, cancelling the running shrink.
                CountdownShrink(plan: shrink).id(shrink.activity)
            }
        }
        .task { await run() }
    }

    /// Sleeps until the final window, then hands the shrink to one linear
    /// animation. `lastActivity` is not published, so a reset is noticed by
    /// re-reading it once a second instead of polling the bar at 10 Hz.
    private func run() async {
        while !Task.isCancelled {
            let activity = state.lastActivity
            let autoClose = state.autoCloseInterval
            let window = min(10.0, autoClose * 0.6)
            let remaining = autoClose - Date.now.timeIntervalSince(activity)
            if remaining <= 0 || remaining >= window || state.isPinned {
                if shrink != nil { shrink = nil }
            } else if shrink?.activity != activity {
                shrink = .init(activity: activity, startWidth: CGFloat(remaining / window) * CountdownShrink.fullWidth,
                               duration: remaining)
            }
            let untilWindow = remaining - window
            let delay = untilWindow > 0 ? min(1, untilWindow) : 1
            do { try await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(100)) } catch { return }
        }
    }
}

/// Draws its start width first, then animates to zero once (from onAppear).
struct CountdownShrink: View {
    struct Plan: Equatable {
        let activity: Date
        let startWidth: CGFloat
        let duration: TimeInterval
    }
    static let fullWidth: CGFloat = 160

    let plan: Plan
    @State private var width: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.35))
            .frame(width: width ?? plan.startWidth, height: 2)
            .cornerRadius(2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .onAppear { withAnimation(.linear(duration: plan.duration)) { width = 0 } }
    }
}

// MARK: - Island content (header + views, only in expanded mode)

struct IslandContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            IslandHeader(state: state)
                .frame(height: IslandSessionLayout.headerHeight)
                .opacity(state.view == .confused ? 0 : 1)
                .animation(.easeInOut(duration: 0.2), value: state.view == .confused)

            // Only mount the current page: hidden pages must not read the host,
            // retain focus, or keep their animations running.
            let fillsHeight = [IslandView.prompt, .voice, .ambient, .workspace].contains(state.view)
            IslandViewContent(view: state.view, state: state)
                // Overview and empty share the carousel; keep it mounted across that switch.
                .id(state.view == .empty ? IslandView.overview : state.view)
                .frame(maxWidth: .infinity)
                .frame(height: fillsHeight ? nil : IslandSessionLayout.cardHeight)
                .frame(maxHeight: fillsHeight ? .infinity : nil)
                .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 10)
        }
        .padding(.top, IslandSessionLayout.headerTopPadding)
        .padding(.bottom, 10)
        .foregroundColor(Color(hex: "#F5F6F8"))
        .overlay { OmniFlowToastOverlay().scaleEffect(0.9).environment(\.colorScheme, .dark) }
    }
}

// MARK: - Island header (tabs + icons)

struct IslandHeader: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            // Left: tab capsules
            HStack(spacing: 5) {
                TabButton(icon: "house.fill", view: .overview, state: state)
                    .help("Home")
                    .accessibilityLabel("Home")
                TabButton(icon: "plus", view: .upload, state: state)
                    .help("Add files")
                    .accessibilityLabel("Add files")
                IslandVoiceButton()
                AgentCursorButton()
                Button { IslandWorkspace.shared.show() } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(.press)
                .help("Assistant, ambient watches and transcripts")
                .accessibilityLabel("Open OmniFlow")
            }
            .padding(.leading, 14)

            Spacer()
            if state.view == .overview || state.view == .empty { NotchLeeCarouselDots(state: state) }
            Spacer()

            // Right: action icons
            HStack(spacing: 14) {
                if state.view == .workspace {
                    Button {
                        NotificationCenter.default.post(name: .islandCollapse, object: nil)
                    } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.press)
                        .keyboardShortcut(.cancelAction)
                        .help("Collapse island · Escape")
                        .accessibilityLabel("Collapse island")
                }
                Button(action: { IslandWorkspace.shared.show(.settings) }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "#C6CBD4"))
                }
                .buttonStyle(.press)
                .help("Settings")
                .accessibilityLabel("Settings")

                Button(action: { state.soundEnabled.toggle() }) {
                    Image(systemName: state.soundEnabled ? "speaker.wave.2" : "speaker.slash")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "#C6CBD4"))
                }
                .buttonStyle(.press)
                .help(state.soundEnabled ? "Mute sound" : "Unmute sound")
                .accessibilityLabel(state.soundEnabled ? "Mute sound" : "Unmute sound")
            }
            .padding(.trailing, 16)
        }
        .frame(maxHeight: .infinity)
    }
}

struct AgentCursorButton: View {
    @ObservedObject private var cursor = AgentCursor.shared
    var body: some View {
        Button {
            cursor.enabled.toggle()
            if cursor.enabled && !cursor.hasAccessibility { cursor.requestAccessibility() }
        } label: {
            Image(systemName: "cursorarrow")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(cursor.enabled ? NotchLeeTheme.accent : NotchLeeTheme.sage)
                .frame(width: 26, height: 24)
                .background(cursor.enabled ? Color.white.opacity(0.16) : .clear, in: Capsule())
        }
        .buttonStyle(.press)
        .help(cursor.enabled ? "Restore Mac pointer and pause context" : "Use agent pointer and cursor context")
        .accessibilityLabel(cursor.enabled ? "Pause agent cursor" : "Enable agent cursor")
    }
}

struct TabButton: View {
    let icon: String
    let view: IslandView
    @ObservedObject var state: AppState
    var preAction: (() -> Void)? = nil
    @State private var isHovered = false

    private var isOn: Bool {
        if view == .overview { return state.view == .overview || state.view == .empty }
        return state.view == view
    }

    var body: some View {
        Button(action: {
            preAction?()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                state.view = view
            }
        }) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                // Brighter on glass: dark grays vanished against Liquid Glass.
                .foregroundColor(isOn ? Color(hex: "#FFFFFF") : (isHovered ? Color(hex: "#EDEFF3") : Color(hex: "#C6CBD4")))
                .frame(width: 30, height: 22)
                .background(
                    // Light translucent selection chip instead of a near-black pill.
                    isOn ? Color.white.opacity(0.22) :
                    isHovered ? Color.white.opacity(0.10) : Color.clear
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.press)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Compact mini mochi grid (2×2 to the right of the notch)

struct CompactMiniGrid: View {
    @ObservedObject var state: AppState

    private var others: [AgentTask] {
        Array(state.tasks.filter { $0.id != state.focusId }.prefix(4))
    }

    var body: some View {
        let cols = [GridItem(.fixed(12), spacing: 4), GridItem(.fixed(12), spacing: 4)]
        LazyVGrid(columns: cols, spacing: 4) {
            ForEach(others) { task in
                MiniBotCanvasView(task: task, paused: state.mode != .compact)
                    .frame(width: 12 / 0.6, height: 12 / 0.6)
                    .frame(width: 12, height: 12, alignment: .center)
            }
        }
        .frame(width: 28, height: 28)
    }
}

// MARK: - Color helper

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let val = UInt64(h, radix: 16) ?? 0
        let r = Double((val >> 16) & 0xFF) / 255
        let g = Double((val >> 8)  & 0xFF) / 255
        let b = Double( val        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
