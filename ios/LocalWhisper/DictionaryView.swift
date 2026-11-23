import SwiftUI

struct DictionaryView: View {
    private var store = SharedStore.shared

    @State private var showingEditor = false
    @State private var editingEntryId: String?
    @State private var draftSpoken = ""
    @State private var draftReplacement = ""
    @State private var draftCaseSensitive = false
    @State private var isSyncing = false
    @State private var syncError: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.dictionary.isEmpty {
                    ContentUnavailableView(
                        "Personal Dictionary",
                        systemImage: "character.book.closed",
                        description: Text("Add names, jargon, or snippets. Stored on your Mac and shared across all your devices.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(store.dictionary) { entry in
                                Button {
                                    beginEdit(entry)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.replacement)
                                                .font(.body.weight(.semibold))
                                                .foregroundStyle(.primary)
                                            Text("When Parakeet hears “\(entry.spoken)”")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if entry.caseSensitive {
                                            Text("Aa")
                                                .font(.caption2.monospaced().weight(.semibold))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.secondary.opacity(0.15), in: Capsule())
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                                .buttonStyle(.plain)
                            }
                            .onDelete { offsets in
                                deleteEntries(at: offsets)
                            }
                        } footer: {
                            syncFooterText
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable {
                        await syncWithMac()
                    }
                }
            }
            .navigationTitle("Dictionary")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await syncWithMac() }
                    } label: {
                        if isSyncing {
                            ProgressView()
                        } else {
                            Image(systemName: store.dictionaryHasUnsyncedChanges ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(isSyncing)
                    .accessibilityLabel("Sync dictionary with Mac")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editingEntryId = nil
                        draftSpoken = ""
                        draftReplacement = ""
                        draftCaseSensitive = false
                        showingEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add dictionary entry")
                }
            }
            .task {
                await syncWithMac()
            }
            .sheet(isPresented: $showingEditor) {
                NavigationStack {
                    Form {
                        Section("Replacement Rule") {
                            TextField("Spoken phrase (e.g. tail scale)", text: $draftSpoken)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("Exact output (e.g. Tailscale)", text: $draftReplacement)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Toggle("Case sensitive match", isOn: $draftCaseSensitive)
                        }
                    }
                    .navigationTitle(editingEntryId == nil ? "New Entry" : "Edit Entry")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingEditor = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                saveDraft()
                            }
                            .disabled(
                                draftSpoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                draftReplacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                        }
                    }
                }
                .presentationDetents([.medium])
            }
        }
    }

    @ViewBuilder
    private var syncFooterText: some View {
        if let syncError {
            Text("Saved locally · Mac sync failed (\(syncError)). Pull to retry.")
                .foregroundStyle(.orange)
        } else if store.dictionaryHasUnsyncedChanges {
            Text("Saved locally · waiting to sync to your Mac.")
                .foregroundStyle(.orange)
        } else if let syncedAt = store.dictionaryLastSyncedAt {
            Text("Hosted on your Mac · synced \(syncedAt, style: .relative) ago across all devices.")
        } else {
            Text("Hosted on your Mac · shared automatically across iPhone and iPad.")
        }
    }

    private func beginEdit(_ entry: DictionaryEntry) {
        editingEntryId = entry.id
        draftSpoken = entry.spoken
        draftReplacement = entry.replacement
        draftCaseSensitive = entry.caseSensitive
        showingEditor = true
    }

    private func saveDraft() {
        let spoken = draftSpoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = draftReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty, !replacement.isEmpty else { return }

        let entry = DictionaryEntry(
            id: editingEntryId ?? UUID().uuidString.lowercased(),
            spoken: spoken,
            replacement: replacement,
            caseSensitive: draftCaseSensitive
        )

        var next = store.dictionary
        if let idx = next.firstIndex(where: { $0.id == entry.id || $0.spoken.lowercased() == entry.spoken.lowercased() }) {
            next[idx] = entry
        } else {
            next.append(entry)
        }
        store.dictionary = next
        showingEditor = false

        Task {
            await pushUpsert(entry)
        }
    }

    private func deleteEntries(at offsets: IndexSet) {
        var removedIds: [String] = []
        var next = store.dictionary
        for idx in offsets.sorted(by: >) where next.indices.contains(idx) {
            removedIds.append(next[idx].id)
            next.remove(at: idx)
        }
        store.dictionary = next

        Task {
            for id in removedIds {
                await pushDelete(id: id)
            }
        }
    }

    private func syncWithMac() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let response: DictionarySyncResponse
            if store.dictionaryHasUnsyncedChanges {
                response = try await ParakeetClient.shared.replaceDictionary(
                    store.dictionary,
                    serverURL: store.serverURL,
                    apiToken: store.apiToken
                )
            } else {
                response = try await ParakeetClient.shared.fetchDictionary(
                    serverURL: store.serverURL,
                    apiToken: store.apiToken
                )
            }
            store.dictionary = response.entries
            store.dictionaryHasUnsyncedChanges = false
            store.dictionaryLastSyncedAt = Date()
            syncError = nil
        } catch {
            syncError = error.localizedDescription
        }
    }

    private func pushUpsert(_ entry: DictionaryEntry) async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let response = try await ParakeetClient.shared.upsertDictionaryEntry(
                entry,
                serverURL: store.serverURL,
                apiToken: store.apiToken
            )
            store.dictionary = response.entries
            store.dictionaryHasUnsyncedChanges = false
            store.dictionaryLastSyncedAt = Date()
            syncError = nil
        } catch {
            store.dictionaryHasUnsyncedChanges = true
            syncError = error.localizedDescription
        }
    }

    private func pushDelete(id: String) async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let response = try await ParakeetClient.shared.deleteDictionaryEntry(
                id: id,
                serverURL: store.serverURL,
                apiToken: store.apiToken
            )
            store.dictionary = response.entries
            store.dictionaryHasUnsyncedChanges = false
            store.dictionaryLastSyncedAt = Date()
            syncError = nil
        } catch {
            store.dictionaryHasUnsyncedChanges = true
            syncError = error.localizedDescription
        }
    }
}
