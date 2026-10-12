import SwiftUI
import AppKit

struct ReaderPagedMacView: View {
    @ObservedObject var reader: ReaderController
    @Binding var browseTarget: ReaderSentenceRef?
    var columns: Int
    var fontSize: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var layout: ReaderMacPages?
    @State private var chapter = 0
    @State private var page = 0
    @State private var direction = 1
    @State private var following = true
    @State private var requestedPage: Int?
    @State private var jump = ""
    @State private var layoutReady = false

    private struct LayoutKey: Hashable {
        var book: String; var chapter: Int; var width: Int; var height: Int; var font: Double
    }
    var body: some View {
        GeometryReader { geometry in
            let count = columns == 2 && geometry.size.width >= 720 ? 2 : 1
            let size = CGSize(width: max(100, min(680, (geometry.size.width - 24) / Double(count) - 48)),
                              height: max(100, geometry.size.height - 120))
            let key = LayoutKey(book: reader.book?.id ?? "", chapter: chapter, width: Int(size.width), height: Int(size.height), font: fontSize)
            VStack(spacing: 12) {
                if let layout, layoutReady {
                    HStack(spacing: count == 2 ? 2 : 0) {
                        ForEach(0..<count, id: \.self) { column in
                            let index = page + column
                            VStack(spacing: 10) {
                                Text(reader.document?.chapters[chapter].title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if layout.pages.indices.contains(index) {
                                    TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !reader.isPlaying || !following || reduceMotion)) { _ in
                                        ReaderMacPageCanvas(text: layout.pages[index].text, fontSize: fontSize,
                                                            highlight: word(on: index, layout: layout))
                                    }
                                    .frame(width: size.width, height: size.height)
                                    Text("\(index + 1) / \(layout.pages.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                } else { Color.clear.frame(width: size.width, height: size.height + 24) }
                            }
                            .padding(.horizontal, 24).padding(.vertical, 12)
                            .background(Color.flowPaper, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(alignment: column == 0 ? .trailing : .leading) {
                                LinearGradient(colors: [.black.opacity(0.10), .clear], startPoint: column == 0 ? .trailing : .leading, endPoint: column == 0 ? .leading : .trailing)
                                    .frame(width: 24).allowsHitTesting(false)
                            }
                            .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 6)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .id("\(chapter)-\(page)")
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .modifier(active: ReaderPageTurn(angle: Double(direction) * -65, offset: CGFloat(direction) * 45), identity: ReaderPageTurn(angle: 0, offset: 0)),
                        removal: .modifier(active: ReaderPageTurn(angle: Double(direction) * 65, offset: CGFloat(direction) * -45), identity: ReaderPageTurn(angle: 0, offset: 0))))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: page)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 35).onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        turn(value.translation.width < 0 ? count : -count)
                    })
                    .accessibilityAction(named: "Next page") { turn(count) }
                    .accessibilityAction(named: "Previous page") { turn(-count) }
                    HStack(spacing: 12) {
                        Button("Previous", systemImage: "chevron.left") { turn(-count) }
                            .disabled(chapter == 0 && page == 0)
                        TextField("Page", text: $jump).frame(width: 56).textFieldStyle(.roundedBorder)
                            .onSubmit { jumpToPage(count: count) }.accessibilityLabel("Page number in chapter")
                        Button("Go") { jumpToPage(count: count) }
                        Text("of \(layout.pages.count)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if !following { Button("Back to reading") { follow() } }
                        Button("Read this page") {
                            if let document = reader.document, let ref = layout.ref(on: page, in: document), let i = reader.order.firstIndex(of: ref) {
                                reader.seek(to: i); reader.play(); following = true; browseTarget = nil
                            }
                        }.disabled(layout.pages.isEmpty)
                        Button("Next", systemImage: "chevron.right") { turn(count) }
                            .disabled(chapter == (reader.document?.chapters.count ?? 1) - 1 && page + count >= layout.pages.count)
                    }.controlSize(.small)
                } else { ProgressView("Laying out pages…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .background(ReaderInputBridge(key: { event in
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
                guard modifiers.isEmpty else { return false }
                if [123, 116].contains(event.keyCode) { turn(-count); return true }
                if [124, 121].contains(event.keyCode) { turn(count); return true }
                return false
            }, swipe: { delta in turn(delta * count) }))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: page)
            .task(id: key) {
                guard let document = reader.document, document.chapters.indices.contains(chapter) else { return }
                layoutReady = false
                let oldOffset = layout.flatMap { $0.chapter == chapter && $0.pages.indices.contains(page) ? $0.pages[page].range.location : nil }
                let work = Task.detached(priority: .userInitiated) { ReaderMacPages.build(document: document, chapter: key.chapter, size: CGSize(width: key.width, height: key.height), fontSize: key.font) }
                let fresh = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled else { return }
                layout = fresh
                if let target = browseTarget, let found = fresh.page(for: target, in: document) { page = found / count * count }
                else if following, let ref = reader.currentRef, let found = fresh.page(for: ref, in: document) { page = found / count * count }
                else if let requestedPage { page = requestedPage == .max ? max(0, fresh.pages.count - 1) / count * count : requestedPage }
                else if let oldOffset { page = (fresh.pages.firstIndex { NSLocationInRange(oldOffset, $0.range) } ?? 0) / count * count }
                else { page = 0 }
                requestedPage = nil; jump = String(page + 1); layoutReady = true
            }
            .onChange(of: browseTarget) { _, ref in
                guard let ref else { return }
                following = false
                if chapter != ref.chapter { chapter = ref.chapter }
                else if let layout, let document = reader.document, let found = layout.page(for: ref, in: document) {
                    page = found / count * count; jump = String(page + 1)
                }
            }
            .onChange(of: following) { _, enabled in
                guard enabled, let ref = reader.currentRef, let document = reader.document, let layout,
                      let found = layout.page(for: ref, in: document) else { return }
                page = found / count * count; jump = String(page + 1)
            }
            .onChange(of: reader.currentRef) { _, ref in
                guard following, let ref else { return }
                if chapter != ref.chapter { chapter = ref.chapter }
                else if let layout, let document = reader.document, let found = layout.page(for: ref, in: document) {
                    page = found / count * count; jump = String(page + 1)
                }
            }
        }
        .onAppear { chapter = browseTarget?.chapter ?? reader.currentRef?.chapter ?? 0; following = browseTarget == nil }
    }
    private func jumpToPage(count: Int) {
        guard let n = Int(jump), let layout, (1...max(1, layout.pages.count)).contains(n) else { jump = String(page + 1); return }
        page = (n - 1) / count * count; following = false; browseTarget = nil; jump = String(page + 1)
    }
    private func turn(_ delta: Int) {
        guard let layout, layoutReady else { return }
        guard !(delta < 0 && page == 0 && chapter == 0),
              !(delta > 0 && page + delta >= layout.pages.count && chapter + 1 >= (reader.document?.chapters.count ?? 0)) else { return }
        direction = delta > 0 ? 1 : -1
        following = false; browseTarget = nil
        let target = page + delta
        if target < 0, chapter > 0 { requestedPage = .max; chapter -= 1 }
        else if target >= layout.pages.count, chapter + 1 < (reader.document?.chapters.count ?? 0) { requestedPage = 0; chapter += 1 }
        else { page = max(0, min(max(0, layout.pages.count - 1), target)); jump = String(page + 1) }
    }
    private func follow() {
        guard let ref = reader.currentRef else { return }
        // A fresh view position is requested without changing the audio position.
        browseTarget = nil
        chapter = ref.chapter
        following = true
    }
    private func word(on index: Int, layout: ReaderMacPages) -> NSRange? {
        guard let document = reader.document, let ref = reader.currentRef, ref.chapter == layout.chapter,
              layout.pages.indices.contains(index), let start = layout.blocks[ref.block],
              let progress = reader.engine.playback.sentenceProgress(),
              let word = ReaderWordTiming.word(at: progress, in: ReaderWordTiming.words(in: document.text(ref))) else { return nil }
        let sentence = document.block(ref).sentences[ref.sentence]
        let range = NSIntersectionRange(NSRange(location: start + sentence.lowerBound + word.lowerBound, length: word.count), layout.pages[index].range)
        return range.length > 0 ? NSRange(location: range.location - layout.pages[index].range.location, length: range.length) : nil
    }
}

private struct ReaderPageTurn: AnimatableModifier {
    nonisolated var angle: Double
    nonisolated var offset: CGFloat
    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { .init(angle, Double(offset)) }
        set { angle = newValue.first; offset = CGFloat(newValue.second) }
    }
    func body(content: Content) -> some View {
        content.rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), anchor: angle < 0 ? .leading : .trailing, perspective: 0.35)
            .offset(x: offset).opacity(1 - min(1, abs(angle) / 90))
    }
}

/// Window-scoped input, removed with the view. Never captures typing in fields.
struct ReaderInputBridge: NSViewRepresentable {
    var key: (NSEvent) -> Bool
    var swipe: ((Int) -> Void)? = nil
    func makeNSView(context: Context) -> InputView { let view = InputView(); view.install(); return view }
    func updateNSView(_ view: InputView, context: Context) { view.key = key; view.swipe = swipe }
    static func dismantleNSView(_ view: InputView, coordinator: ()) { view.uninstall() }
    final class InputView: NSView {
        var key: ((NSEvent) -> Bool)?
        var swipe: ((Int) -> Void)?
        private var monitor: Any?
        private var horizontal: CGFloat = 0
        private var vertical: CGFloat = 0
        private var turned = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .swipe]) { [weak self] event in
                guard let self, let window = self.window, window.isKeyWindow, event.window === window,
                      !self.isHiddenOrHasHiddenAncestor else { return event }
                if event.type == .keyDown {
                    if let text = window.firstResponder as? NSTextView, text.isEditable { return event }
                    return self.key?(event) == true ? nil : event
                }
                guard let swipe = self.swipe, self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                if event.type == .swipe, event.deltaX != 0 { swipe(event.deltaX < 0 ? 1 : -1); return nil }
                // One turn per horizontal trackpad gesture, with momentum ignored.
                if event.phase.contains(.began) { self.horizontal = 0; self.vertical = 0; self.turned = false }
                guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return event }
                self.horizontal += event.scrollingDeltaX; self.vertical += event.scrollingDeltaY
                if !self.turned, abs(self.horizontal) > 65, abs(self.horizontal) > abs(self.vertical) * 1.5 {
                    self.turned = true; swipe(self.horizontal < 0 ? 1 : -1); return nil
                }
                return event
            }
        }
        func uninstall() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}
