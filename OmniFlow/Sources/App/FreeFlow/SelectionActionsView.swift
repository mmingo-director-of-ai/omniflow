import SwiftUI

struct SelectionActionsView: View {
    @ObservedObject var service: SelectionActionService
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("In another app, select text and choose Services → OmniFlow. Available actions depend on the app’s Services support.").foregroundStyle(.secondary)
                Picker("Action", selection: $service.action) {
                    ForEach(SelectionActionService.Action.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).disabled(service.busy)
                HStack {
                    languagePicker("Source language", selection: $service.sourceIdentifier).disabled(service.busy)
                    if service.action == .translate { languagePicker("Output language", selection: $service.targetIdentifier).disabled(service.busy) }
                }
                if service.action == .style {
                    Picker("Writing style", selection: $service.writingStyle) {
                        ForEach(WritingStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.disabled(service.busy)
                }
                if service.action == .translate {
                    TranslationSetupView(sourceIdentifier: service.sourceIdentifier, targetIdentifier: service.targetIdentifier)
                }
                DisclosureGroup("Paste text for preview") {
                    TextEditor(text: $service.pastedText).frame(height: 90)
                    Button("Use pasted text") { service.preview(text: service.pastedText, action: service.action) }.disabled(service.pastedText.isEmpty || service.busy)
                }
                HStack {
                    Button(service.action.title) { service.run() }.disabled(service.original.isEmpty || service.busy)
                    if service.busy { ProgressView().controlSize(.small); Button("Cancel") { service.cancel() } }
                }
                Text(service.note).font(.callout).foregroundStyle(.secondary)
                GroupBox("Result preview") {
                    Text(service.result.isEmpty ? "Your result will appear here." : service.result)
                        .textSelection(.enabled).frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading).padding(8)
                }
                HStack {
                    Button("Copy result") { service.copyResult() }.disabled(service.result.isEmpty || service.busy)
                    Button("Replace original selection") { service.replaceOriginal() }.disabled(!service.canReplace)
                }
                DisclosureGroup("Original text (retained for recovery)") {
                    Text(service.original).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Copy original") { service.copyOriginal() }.disabled(service.original.isEmpty)
                }
            }.padding(24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await service.loadLanguages() }
    }
    private func languagePicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            if !service.languages.contains(where: { $0.id == selection.wrappedValue }) {
                Text(Locale.current.localizedString(forIdentifier: selection.wrappedValue) ?? selection.wrappedValue).tag(selection.wrappedValue)
            }
            ForEach(service.languages) { Text($0.name).tag($0.id) }
        }
    }
}
