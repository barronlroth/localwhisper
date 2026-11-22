import SwiftUI
import UIKit

struct HistoryView: View {
    private var store = SharedStore.shared
    @State private var searchText = ""
    @State private var copiedId: UUID?
    @State private var expandedRawIds: Set<UUID> = []

    private var filteredHistory: [DictationRecord] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return store.history
        }
        let q = searchText.lowercased()
        return store.history.filter {
            $0.text.lowercased().contains(q) || $0.rawText.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filteredHistory.isEmpty {
                    ContentUnavailableView(
                        store.history.isEmpty ? "No Dictations Yet" : "No Matching Transcripts",
                        systemImage: "waveform",
                        description: Text(
                            store.history.isEmpty
                                ? "Transcripts from the LocalWhisper keyboard appear here automatically."
                                : "Try a different search phrase."
                        )
                    )
                } else {
                    List {
                        ForEach(filteredHistory) { record in
                            historyRow(record)
                        }
                        .onDelete { offsets in
                            if searchText.isEmpty {
                                store.deleteHistory(at: offsets)
                            } else {
                                let ids = Set(offsets.map { filteredHistory[$0].id })
                                store.history.removeAll { ids.contains($0.id) }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("History")
            .searchable(text: $searchText, prompt: "Search transcripts")
            .toolbar {
                if !store.history.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear", role: .destructive) {
                            store.clearHistory()
                        }
                    }
                }
            }
            .onAppear {
                store.reload()
            }
        }
    }

    private func historyRow(_ record: DictationRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.text)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)

            if expandedRawIds.contains(record.id), record.rawText != record.text {
                Text("Raw: \(record.rawText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 10) {
                Text(record.createdAt, style: .relative)
                Text("·")
                Text(String(format: "%.1fs", record.durationSeconds))
                    .monospacedDigit()
                Text("·")
                Text("\(Int(round(record.inferenceMs)))ms")
                    .monospacedDigit()
                Text("·")
                Text(record.mode.title)

                Spacer()

                if record.rawText != record.text {
                    Button {
                        if expandedRawIds.contains(record.id) {
                            expandedRawIds.remove(record.id)
                        } else {
                            expandedRawIds.insert(record.id)
                        }
                    } label: {
                        Text(expandedRawIds.contains(record.id) ? "Hide Raw" : "Raw")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                }

                Button {
                    UIPasteboard.general.string = record.text
                    HapticFeedback.keyTap()
                    copiedId = record.id
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        if copiedId == record.id { copiedId = nil }
                    }
                } label: {
                    Image(systemName: copiedId == record.id ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(copiedId == record.id ? .green : .secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy transcript")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
