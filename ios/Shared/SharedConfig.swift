import Foundation
import Observation

public enum AppGroup {
    public static let identifier: String = {
        if let value = Bundle.main.object(forInfoDictionaryKey: "LWAppGroupID") as? String,
           !value.isEmpty, !value.contains("$(") {
            return value
        }
        return "group.com.example.LocalWhisper"
    }()

    public static let defaultServerURL: String = {
        if let value = Bundle.main.object(forInfoDictionaryKey: "LWDefaultServerURL") as? String,
           !value.isEmpty, !value.contains("$(") {
            return value
        }
        return "https://your-mac.ts.net/parakeet"
    }()

    public static let keyboardBundleIdentifier: String = {
        if let value = Bundle.main.object(forInfoDictionaryKey: "LWKeyboardBundleID") as? String,
           !value.isEmpty, !value.contains("$(") {
            return value
        }
        return "LocalWhisper.Keyboard"
    }()

    public static let urlScheme = "localwhisper"
}

public enum TranscriptionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case clean
    case raw
    case notes

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .clean: return "Clean"
        case .raw: return "Raw"
        case .notes: return "Notes"
        }
    }

    public var subtitle: String {
        switch self {
        case .clean: return "Removes filler words, fixes stutters & context spacing"
        case .raw: return "Exact verbatim output from Parakeet"
        case .notes: return "Turns spoken bullets into crisp lists"
        }
    }

    public var symbolName: String {
        switch self {
        case .clean: return "sparkles"
        case .raw: return "waveform"
        case .notes: return "list.bullet"
        }
    }

    public var next: TranscriptionMode {
        switch self {
        case .clean: return .raw
        case .raw: return .notes
        case .notes: return .clean
        }
    }
}

public struct DictionaryEntry: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var spoken: String
    public var replacement: String
    public var caseSensitive: Bool

    public init(
        id: UUID = UUID(),
        spoken: String,
        replacement: String,
        caseSensitive: Bool = false
    ) {
        self.id = id
        self.spoken = spoken
        self.replacement = replacement
        self.caseSensitive = caseSensitive
    }

    enum CodingKeys: String, CodingKey {
        case id
        case spoken
        case replacement
        case caseSensitive = "case_sensitive"
    }
}

public struct DictationRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var rawText: String
    public var createdAt: Date
    public var durationSeconds: Double
    public var inferenceMs: Double
    public var mode: TranscriptionMode
    public var source: String

    public init(
        id: UUID = UUID(),
        text: String,
        rawText: String,
        createdAt: Date = Date(),
        durationSeconds: Double,
        inferenceMs: Double,
        mode: TranscriptionMode,
        source: String
    ) {
        self.id = id
        self.text = text
        self.rawText = rawText
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.inferenceMs = inferenceMs
        self.mode = mode
        self.source = source
    }
}

@MainActor
@Observable
public final class SharedStore {
    public static let shared = SharedStore()

    private enum Keys {
        static let serverURL = "pf.serverURL"
        static let apiToken = "pf.apiToken"
        static let mode = "pf.mode"
        static let useStreamingWebSocket = "pf.useStreamingWebSocket"
        static let smartSpacing = "pf.smartSpacing"
        static let enableHaptics = "pf.enableHaptics"
        static let prewarmWebView = "pf.prewarmWebView"
        static let autoTrailingSpace = "pf.autoTrailingSpace"
        static let dictionary = "pf.dictionary"
        static let history = "pf.history"
        static let didSeedDefaults = "pf.didSeedDefaults"
        static let pendingHandoffText = "pf.pendingHandoffText"
        static let pendingHandoffTimestamp = "pf.pendingHandoffTimestamp"
        static let lastDiagnostic = "pf.lastDiagnostic"
    }

    private let defaults: UserDefaults
    public let isAppGroupActive: Bool

    public var serverURL: String {
        didSet { defaults.set(serverURL, forKey: Keys.serverURL) }
    }

    public var apiToken: String {
        didSet { defaults.set(apiToken, forKey: Keys.apiToken) }
    }

    public var mode: TranscriptionMode {
        didSet { defaults.set(mode.rawValue, forKey: Keys.mode) }
    }

    public var useStreamingWebSocket: Bool {
        didSet { defaults.set(useStreamingWebSocket, forKey: Keys.useStreamingWebSocket) }
    }

    public var smartSpacing: Bool {
        didSet { defaults.set(smartSpacing, forKey: Keys.smartSpacing) }
    }

    public var enableHaptics: Bool {
        didSet { defaults.set(enableHaptics, forKey: Keys.enableHaptics) }
    }

    public var prewarmWebView: Bool {
        didSet { defaults.set(prewarmWebView, forKey: Keys.prewarmWebView) }
    }

    public var autoTrailingSpace: Bool {
        didSet { defaults.set(autoTrailingSpace, forKey: Keys.autoTrailingSpace) }
    }

    public var dictionary: [DictionaryEntry] {
        didSet { saveCodable(dictionary, forKey: Keys.dictionary) }
    }

    public var history: [DictationRecord] {
        didSet { saveCodable(history, forKey: Keys.history) }
    }

    public var lastDiagnostic: String {
        didSet { defaults.set(lastDiagnostic, forKey: Keys.lastDiagnostic) }
    }

    private init() {
        if let suite = UserDefaults(suiteName: AppGroup.identifier) {
            self.defaults = suite
            self.isAppGroupActive = true
        } else {
            self.defaults = .standard
            self.isAppGroupActive = false
        }

        self.serverURL = defaults.string(forKey: Keys.serverURL) ?? AppGroup.defaultServerURL
        self.apiToken = defaults.string(forKey: Keys.apiToken) ?? ""
        self.mode = TranscriptionMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .clean
        self.useStreamingWebSocket = defaults.object(forKey: Keys.useStreamingWebSocket) as? Bool ?? true
        self.smartSpacing = defaults.object(forKey: Keys.smartSpacing) as? Bool ?? true
        self.enableHaptics = defaults.object(forKey: Keys.enableHaptics) as? Bool ?? true
        self.prewarmWebView = defaults.object(forKey: Keys.prewarmWebView) as? Bool ?? true
        self.autoTrailingSpace = defaults.object(forKey: Keys.autoTrailingSpace) as? Bool ?? false
        self.lastDiagnostic = defaults.string(forKey: Keys.lastDiagnostic) ?? ""

        let loadedDict: [DictionaryEntry] = Self.loadCodable(from: defaults, forKey: Keys.dictionary) ?? []
        let seededDefaults: [DictionaryEntry]?
        if loadedDict.isEmpty && !defaults.bool(forKey: Keys.didSeedDefaults) {
            let seeded = [
                DictionaryEntry(spoken: "whisper flow", replacement: "Wispr Flow"),
                DictionaryEntry(spoken: "whisperflow", replacement: "Wispr Flow"),
                DictionaryEntry(spoken: "tail scale", replacement: "Tailscale"),
                DictionaryEntry(spoken: "parakeet", replacement: "Parakeet"),
            ]
            self.dictionary = seeded
            seededDefaults = seeded
        } else {
            self.dictionary = loadedDict
            seededDefaults = nil
        }

        self.history = Self.loadCodable(from: defaults, forKey: Keys.history) ?? []

        if let seededDefaults {
            defaults.set(true, forKey: Keys.didSeedDefaults)
            saveCodable(seededDefaults, forKey: Keys.dictionary)
        }
    }

    public func reload() {
        defaults.synchronize()
        serverURL = defaults.string(forKey: Keys.serverURL) ?? AppGroup.defaultServerURL
        apiToken = defaults.string(forKey: Keys.apiToken) ?? ""
        mode = TranscriptionMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .clean
        useStreamingWebSocket = defaults.object(forKey: Keys.useStreamingWebSocket) as? Bool ?? true
        smartSpacing = defaults.object(forKey: Keys.smartSpacing) as? Bool ?? true
        enableHaptics = defaults.object(forKey: Keys.enableHaptics) as? Bool ?? true
        prewarmWebView = defaults.object(forKey: Keys.prewarmWebView) as? Bool ?? true
        autoTrailingSpace = defaults.object(forKey: Keys.autoTrailingSpace) as? Bool ?? false
        lastDiagnostic = defaults.string(forKey: Keys.lastDiagnostic) ?? ""
        if let loadedDict: [DictionaryEntry] = Self.loadCodable(from: defaults, forKey: Keys.dictionary) {
            dictionary = loadedDict
        }
        if let loadedHistory: [DictationRecord] = Self.loadCodable(from: defaults, forKey: Keys.history) {
            history = loadedHistory
        }
    }

    public func appendHistory(_ record: DictationRecord) {
        var next = history
        next.insert(record, at: 0)
        if next.count > 100 {
            next = Array(next.prefix(100))
        }
        history = next
    }

    public func deleteHistory(at offsets: IndexSet) {
        var next = history
        for index in offsets.sorted(by: >) {
            if next.indices.contains(index) {
                next.remove(at: index)
            }
        }
        history = next
    }

    public func clearHistory() {
        history = []
    }

    public func setPendingHandoffText(_ text: String) {
        defaults.set(text, forKey: Keys.pendingHandoffText)
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.pendingHandoffTimestamp)
        defaults.synchronize()
    }

    public func consumePendingHandoffText(maxAgeSeconds: TimeInterval = 90) -> String? {
        defaults.synchronize()
        guard let text = defaults.string(forKey: Keys.pendingHandoffText), !text.isEmpty else {
            return nil
        }
        let ts = defaults.double(forKey: Keys.pendingHandoffTimestamp)
        defaults.removeObject(forKey: Keys.pendingHandoffText)
        defaults.removeObject(forKey: Keys.pendingHandoffTimestamp)
        defaults.synchronize()
        guard Date().timeIntervalSince1970 - ts <= maxAgeSeconds else {
            return nil
        }
        return text
    }

    private func saveCodable<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func loadCodable<T: Decodable>(from defaults: UserDefaults, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
