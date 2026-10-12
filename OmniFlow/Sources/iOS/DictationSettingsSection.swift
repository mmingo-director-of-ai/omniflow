import SwiftUI

/// Dictation vocabulary and history retention. Same preference keys as the Mac app.
struct DictationSettingsSection: View {
    @EnvironmentObject private var flow: IOSFlowModel
    @AppStorage(KeyboardSessionController.lengthKey) private var sessionMinutes = 5

    var body: some View {
        Section {
            TextField("Names and terms, one per line", text: $flow.vocabulary, axis: .vertical)
                .lineLimit(3...8)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Toggle(VocabularyPack.security.title, isOn: $flow.securityVocabulary)
            Picker("Keyboard dictation stays on for", selection: $sessionMinutes) {
                ForEach(KeyboardSessionController.lengths, id: \.self) { Text("\($0) minutes").tag($0) }
            }
            Picker("Keep history", selection: $flow.retention) {
                ForEach(HistoryRetention.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Dictation")
        } footer: {
            Text("Your vocabulary helps recognition spell names and terms. Dictations and history stay on this device, encrypted. To dictate in other apps, add the OmniFlow keyboard in Settings › General › Keyboard › Keyboards and turn on Allow Full Access. Full Access only lets the keyboard talk to this app over a connection inside this iPhone; the keyboard sends nothing off the device and records nothing itself. The microphone stays on, shown by the system indicator, until keyboard dictation turns off.")
        }
    }
}
