import SwiftUI

struct DictionaryView: View {
    private var store = SharedStore.shared
    @State private var showingAddSheet = false
    @State private var newSpoken = ""
    @State private var newReplacement = ""
    @State private var newCaseSensitive = false

    var body: some View {
        NavigationStack {
            Group {
                if store.dictionary.isEmpty {
                    ContentUnavailableView(
                        "Personal Dictionary",
                        systemImage: "character.book.closed",
                        description: Text("Add names, technical jargon, or snippets to auto-replace after Parakeet transcribes.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(store.dictionary) { entry in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.replacement)
                                            .font(.body.weight(.semibold))
                                        Text("When Parakeet hears “\(entry.spoken)”")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if entry.caseSensitive {
                                        Text("Aa")
                                            .font(.caption2.monospaced().weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.secondary.opacity(0.15), in: Capsule())
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .onDelete { offsets in
                                var next = store.dictionary
                                for idx in offsets.sorted(by: >) where next.indices.contains(idx) {
                                    next.remove(at: idx)
                                }
                                store.dictionary = next
                            }
                        } footer: {
                            Text("Synced to the keyboard extension and applied on every dictation.")
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Dictionary")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newSpoken = ""
                        newReplacement = ""
                        newCaseSensitive = false
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add dictionary entry")
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                NavigationStack {
                    Form {
                        Section("Replacement Rule") {
                            TextField("Spoken phrase (e.g. tail scale)", text: $newSpoken)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("Exact output (e.g. Tailscale)", text: $newReplacement)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Toggle("Case sensitive match", isOn: $newCaseSensitive)
                        }
                    }
                    .navigationTitle("New Entry")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingAddSheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                let spoken = newSpoken.trimmingCharacters(in: .whitespacesAndNewlines)
                                let replacement = newReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !spoken.isEmpty, !replacement.isEmpty else { return }
                                store.dictionary.append(
                                    DictionaryEntry(
                                        spoken: spoken,
                                        replacement: replacement,
                                        caseSensitive: newCaseSensitive
                                    )
                                )
                                showingAddSheet = false
                            }
                            .disabled(
                                newSpoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                newReplacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }
}
