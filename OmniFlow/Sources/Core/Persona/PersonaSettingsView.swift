import SwiftUI

/// Persona picker and phrasing options. Pure SwiftUI so it works on macOS and iOS.
struct PersonaSettingsView: View {
    @Bindable var store: PersonaStore
    @State private var preview: String?
    @State private var editing: Persona?
    @State private var creating = false

    var body: some View {
        Form {
            Section {
                Picker("Persona", selection: $store.selectedID) {
                    ForEach(store.visiblePersonas) { persona in
                        Text(persona.displayName).tag(persona.id)
                    }
                    // Keep the stored selection representable while the gate hides it.
                    if !store.visiblePersonas.contains(where: { $0.id == store.selectedID }) {
                        Text("\(store.selectedPersona.displayName) (needs explicit language)").tag(store.selectedID)
                    }
                }
                Text(store.effectivePersona.summary).font(.callout).foregroundStyle(.secondary)
                Button("Preview a warning") {
                    preview = store.phraseNow(.memoryPressure(percent: 91)).text
                }
                if let preview {
                    Text(preview).font(.callout).textSelection(.enabled).accessibilityLabel("Preview: \(preview)")
                }
            } header: { Text("Voice") }

            Section {
                Toggle("Allow explicit language", isOn: $store.allowExplicit)
                Text("Shows personas that swear and insult you, playfully. Off by default. Spoken alerts use the same words.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Vary wording", isOn: $store.variationEnabled)
                Text("Avoids repeating the same line for the same kind of notice.").font(.caption).foregroundStyle(.secondary)
                Toggle("Rewrite with the on-device model", isOn: $store.modelRewriteEnabled)
                    .disabled(!store.variationEnabled)
                Text("Apple's on-device model may rephrase notices if it answers within a moment; facts are checked and the built-in wording is used otherwise. Explicit personas always use built-in wording.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Phrasing") }

            Section {
                ForEach(store.customPersonas.filter { store.allowExplicit || !$0.explicitLanguage }) { persona in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(persona.displayName)
                            Text(persona.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        // Borderless: in an iOS Form row, bordered buttons all fire on a row tap.
                        Button("Edit") { editing = persona }.buttonStyle(.borderless)
                        Button("Delete", role: .destructive) { store.deleteCustom(id: persona.id) }.buttonStyle(.borderless)
                    }
                }
                Button("New persona…") { creating = true }
                if let error = store.lastError { Text(error).font(.caption).foregroundStyle(.red) }
            } header: { Text("Custom personas") }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $creating) {
            CustomPersonaEditor(store: store, persona: nil) { creating = false }
        }
        .sheet(item: $editing) { persona in
            CustomPersonaEditor(store: store, persona: persona) { editing = nil }
        }
    }
}

private struct CustomPersonaEditor: View {
    let store: PersonaStore
    let persona: Persona?
    let done: () -> Void
    @State private var name = ""
    @State private var tone = ""
    @State private var terms = ""
    @State private var base = PersonaStyle.standard
    @State private var explicit = false

    var body: some View {
        Form {
            TextField("Name", text: $name)
            TextField("Tone", text: $tone, axis: .vertical).lineLimit(3...6)
            Text("\(tone.count)/\(Persona.maxToneLength) characters").font(.caption).foregroundStyle(.secondary)
            TextField("Ways to address you (comma-separated)", text: $terms)
            Picker("Base wording", selection: $base) {
                ForEach(PersonaStyle.allCases.filter { store.allowExplicit || !$0.isExplicit }, id: \.self) { style in
                    Text(Persona.builtIns.first { $0.style == style }?.displayName ?? style.rawValue).tag(style)
                }
            }
            if store.allowExplicit { Toggle("Uses explicit language", isOn: $explicit) }
            Text("Profanity in any field marks the persona explicit, so it stays behind the explicit language setting.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel, action: done).buttonStyle(.borderless)
                Spacer()
                Button("Save") { save(); done() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 360)
        .onAppear {
            guard let persona else { return }
            name = persona.displayName; tone = persona.toneInstructions; base = persona.style
            explicit = persona.explicitLanguage; terms = persona.addressTerms.joined(separator: ", ")
        }
        .onChange(of: tone) { _, value in
            if value.count > Persona.maxToneLength { tone = String(value.prefix(Persona.maxToneLength)) }
        }
    }

    private func save() {
        let list = terms.split(separator: ",").map(String.init)
        if var persona {
            persona.displayName = name; persona.toneInstructions = tone; persona.style = base
            persona.explicitLanguage = explicit; persona.addressTerms = list
            store.updateCustom(persona)
        } else {
            store.addCustom(name: name, tone: tone, base: base, explicit: explicit, addressTerms: list)
        }
    }
}
