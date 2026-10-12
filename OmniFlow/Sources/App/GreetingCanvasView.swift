import SwiftUI

struct GreetingCanvasView: View {
    @ObservedObject var state: AppState
    var body: some View {
        HStack(spacing: 20) {
            RedPandaView(state: .finished, cheerful: true).frame(width: 112, height: 112)
            VStack(alignment: .leading, spacing: 6) {
                Text("Hey. I'm OmniFlow.").font(.title3.weight(.semibold))
                Text("Here with you. Right on your Mac.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            SoundEngine.shared.play("greet")
            try? await Task.sleep(for: .seconds(2.8))
            guard !Task.isCancelled else { return }
            NotificationCenter.default.post(name: .greetComplete, object: nil)
        }
    }
}
