import Foundation

public struct HealthResponse: Codable, Sendable {
    public let status: String
    public let ready: Bool
    public let model: String
    public let sampleRate: Int
    public let device: String
    public let authRequired: Bool
    public let uptimeSeconds: Double
    public var pingMs: Double = 0

    enum CodingKeys: String, CodingKey {
        case status
        case ready
        case model
        case sampleRate = "sample_rate"
        case device
        case authRequired = "auth_required"
        case uptimeSeconds = "uptime_seconds"
    }
}

public struct TranscriptionResponse: Codable, Sendable {
    public let text: String
    public let rawText: String
    public let durationSeconds: Double
    public let inferenceMs: Double
    public let totalMs: Double
    public let model: String
    public let mode: String

    enum CodingKeys: String, CodingKey {
        case text
        case rawText = "raw_text"
        case durationSeconds = "duration_seconds"
        case inferenceMs = "inference_ms"
        case totalMs = "total_ms"
        case model
        case mode
    }
}

public struct DictionarySyncResponse: Codable, Sendable {
    public let entries: [DictionaryEntry]
    public let updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case entries
        case updatedAt = "updated_at"
    }
}

public enum ParakeetError: LocalizedError, Sendable {
    case invalidURL
    case emptyAudio
    case unauthorized
    case serverUnreachable(String)
    case httpError(Int, String)
    case decodingFailed
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Mac mini server URL"
        case .emptyAudio:
            return "No speech detected"
        case .unauthorized:
            return "Invalid API token"
        case .serverUnreachable(let detail):
            return "Can't reach Mac mini (\(detail)). Check Tailscale."
        case .httpError(let code, let detail):
            return "Server error (\(code)): \(detail)"
        case .decodingFailed:
            return "Unexpected response from Parakeet server"
        case .cancelled:
            return "Cancelled"
        }
    }
}

public final class ParakeetClient: Sendable {
    public static let shared = ParakeetClient()

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    public static func normalizedBaseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            return nil
        }
        return url
    }

    public func checkHealth(serverURL: String, apiToken: String = "") async throws -> HealthResponse {
        guard let base = Self.normalizedBaseURL(serverURL) else {
            throw ParakeetError.invalidURL
        }
        let url = base.appendingPathComponent("health")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 5
        if !apiToken.isEmpty {
            req.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ParakeetError.serverUnreachable(error.localizedDescription)
        }
        let pingMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0

        guard let http = response as? HTTPURLResponse else {
            throw ParakeetError.decodingFailed
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ParakeetError.httpError(http.statusCode, body)
        }
        var decoded = try JSONDecoder().decode(HealthResponse.self, from: data)
        decoded.pingMs = pingMs
        return decoded
    }

    public func transcribeWAV(
        wavData: Data,
        serverURL: String,
        apiToken: String,
        mode: TranscriptionMode,
        dictionary: [DictionaryEntry],
        context: String?,
        smartSpacing: Bool
    ) async throws -> TranscriptionResponse {
        guard wavData.count > 44 else {
            throw ParakeetError.emptyAudio
        }
        guard let base = Self.normalizedBaseURL(serverURL) else {
            throw ParakeetError.invalidURL
        }

        let url = base.appendingPathComponent("v1/transcribe")
        let boundary = "LocalWhisper-\(UUID().uuidString)"

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !apiToken.isEmpty {
            req.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        func appendField(_ name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendField("mode", value: mode.rawValue)
        appendField("smart_spacing", value: smartSpacing ? "true" : "false")
        if let context, !context.isEmpty {
            appendField("context", value: context)
        }
        if !dictionary.isEmpty, let dictData = try? JSONEncoder().encode(dictionary),
           let dictJSON = String(data: dictData, encoding: .utf8) {
            appendField("dictionary", value: dictJSON)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        req.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            throw ParakeetError.cancelled
        } catch {
            throw ParakeetError.serverUnreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ParakeetError.decodingFailed
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ParakeetError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw ParakeetError.httpError(http.statusCode, msg)
        }

        guard let result = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) else {
            throw ParakeetError.decodingFailed
        }
        return result
    }

    // MARK: - Mac-Hosted Personal Dictionary Sync

    public func fetchDictionary(serverURL: String, apiToken: String = "") async throws -> DictionarySyncResponse {
        guard let base = Self.normalizedBaseURL(serverURL) else {
            throw ParakeetError.invalidURL
        }
        var req = URLRequest(url: base.appendingPathComponent("v1/dictionary"))
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        if !apiToken.isEmpty {
            req.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }
        return try await performDictionaryRequest(req)
    }

    public func replaceDictionary(
        _ entries: [DictionaryEntry],
        serverURL: String,
        apiToken: String = ""
    ) async throws -> DictionarySyncResponse {
        guard let base = Self.normalizedBaseURL(serverURL) else {
            throw ParakeetError.invalidURL
        }
        var req = URLRequest(url: base.appendingPathComponent("v1/dictionary"))
        req.httpMethod = "PUT"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiToken.isEmpty {
            req.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }
        struct Payload: Encodable { let entries: [DictionaryEntry] }
        req.httpBody = try JSONEncoder().encode(Payload(entries: entries))
        return try await performDictionaryRequest(req)
    }

    public func upsertDictionaryEntry(
        _ entry: DictionaryEntry,
        serverURL: String,
        apiToken: String = ""
    ) async throws -> DictionarySyncResponse {
        guard let base = Self.normalizedBaseURL(serverURL) else {
            throw ParakeetError.invalidURL
        }
        var req = URLRequest(url: base.appendingPathComponent("v1/dictionary"))
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiToken.isEmpty {
            req.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(entry)
        return try await performDictionaryRequest(req)
    }

    public func deleteDictionaryEntry(
        id: String,
        serverURL: String,
        apiToken: String = ""
    ) async throws -> DictionarySyncResponse {
        guard let base = Self.normalizedBaseURL(serverURL) else {
            throw ParakeetError.invalidURL
        }
        var req = URLRequest(url: base.appendingPathComponent("v1/dictionary").appendingPathComponent(id))
        req.httpMethod = "DELETE"
        req.timeoutInterval = 8
        if !apiToken.isEmpty {
            req.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }
        return try await performDictionaryRequest(req)
    }

    private func performDictionaryRequest(_ req: URLRequest) async throws -> DictionarySyncResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ParakeetError.serverUnreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ParakeetError.decodingFailed
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ParakeetError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw ParakeetError.httpError(http.statusCode, msg)
        }
        guard let decoded = try? JSONDecoder().decode(DictionarySyncResponse.self, from: data) else {
            throw ParakeetError.decodingFailed
        }
        return decoded
    }
}

/// Streams 16 kHz Int16 PCM chunks live over WebSocket while recording so Mac mini
/// already holds the audio the instant the user taps Stop. Automatically falls back
/// to HTTP WAV upload if the WebSocket fails or drops.
public actor ParakeetStreamSession {
    private let serverURL: String
    private let apiToken: String
    private let mode: TranscriptionMode
    private let dictionary: [DictionaryEntry]
    private let context: String?
    private let smartSpacing: Bool
    private let enableWebSocket: Bool

    private var wsTask: URLSessionWebSocketTask?
    private var wsHealthy = false
    private var accumulatedPCM = Data()
    private var isClosed = false

    public init(
        serverURL: String,
        apiToken: String,
        mode: TranscriptionMode,
        dictionary: [DictionaryEntry],
        context: String?,
        smartSpacing: Bool,
        enableWebSocket: Bool = true
    ) {
        self.serverURL = serverURL
        self.apiToken = apiToken
        self.mode = mode
        self.dictionary = dictionary
        self.context = context
        self.smartSpacing = smartSpacing
        self.enableWebSocket = enableWebSocket
    }

    public func open() async {
        guard enableWebSocket, let base = ParakeetClient.normalizedBaseURL(serverURL) else { return }
        guard var components = URLComponents(url: base.appendingPathComponent("v1/stream"), resolvingAgainstBaseURL: false) else {
            return
        }
        if components.scheme == "https" {
            components.scheme = "wss"
        } else if components.scheme == "http" {
            components.scheme = "ws"
        }
        guard let wsURL = components.url else { return }

        var req = URLRequest(url: wsURL)
        req.timeoutInterval = 15
        if !apiToken.isEmpty {
            req.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }

        let task = URLSession.shared.webSocketTask(with: req)
        self.wsTask = task
        task.resume()

        var payload: [String: Any] = [
            "type": "start",
            "sample_rate": 16_000,
            "mode": mode.rawValue,
            "smart_spacing": smartSpacing,
        ]
        if let context, !context.isEmpty {
            payload["context"] = context
        }
        if !dictionary.isEmpty {
            payload["dictionary"] = dictionary.map {
                [
                    "spoken": $0.spoken,
                    "replacement": $0.replacement,
                    "case_sensitive": $0.caseSensitive,
                ]
            }
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: payload)
            guard let jsonStr = String(data: jsonData, encoding: .utf8) else { return }
            try await task.send(.string(jsonStr))
            self.wsHealthy = true
        } catch {
            self.wsHealthy = false
            task.cancel(with: .goingAway, reason: nil)
            self.wsTask = nil
        }
    }

    public func appendPCMChunk(_ pcmChunk: Data) async {
        guard !isClosed, !pcmChunk.isEmpty else { return }
        accumulatedPCM.append(pcmChunk)

        if wsHealthy, let task = wsTask {
            do {
                try await task.send(.data(pcmChunk))
            } catch {
                wsHealthy = false
                task.cancel(with: .goingAway, reason: nil)
                wsTask = nil
            }
        }
    }

    public func finish() async throws -> TranscriptionResponse {
        isClosed = true
        let pcmSnapshot = accumulatedPCM
        guard pcmSnapshot.count >= 640 else {
            cancelSocket()
            throw ParakeetError.emptyAudio
        }

        // Fast path: finish active WebSocket stream (zero upload latency after stop)
        if wsHealthy, let task = wsTask {
            do {
                try await task.send(.string(#"{"type":"stop"}"#))
                while true {
                    let message = try await task.receive()
                    switch message {
                    case .string(let str):
                        guard let data = str.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = obj["type"] as? String else {
                            continue
                        }
                        if type == "ready" || type == "pong" {
                            continue
                        }
                        if type == "error" {
                            let msg = (obj["message"] as? String) ?? "Stream transcription error"
                            throw ParakeetError.httpError(500, msg)
                        }
                        if type == "final" {
                            let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
                            cancelSocket()
                            return decoded
                        }
                    case .data:
                        continue
                    @unknown default:
                        break
                    }
                }
            } catch {
                // Fall back transparently to HTTP WAV upload below
                cancelSocket()
            }
        }

        let wavData = AudioWAVEncoder.encodePCM16ToWAV(pcmData: pcmSnapshot, sampleRate: 16_000, channels: 1)
        return try await ParakeetClient.shared.transcribeWAV(
            wavData: wavData,
            serverURL: serverURL,
            apiToken: apiToken,
            mode: mode,
            dictionary: dictionary,
            context: context,
            smartSpacing: smartSpacing
        )
    }

    public func cancel() {
        isClosed = true
        accumulatedPCM.removeAll(keepingCapacity: false)
        if let task = wsTask {
            Task {
                try? await task.send(.string(#"{"type":"cancel"}"#))
                task.cancel(with: .normalClosure, reason: nil)
            }
            wsTask = nil
        }
        wsHealthy = false
    }

    private func cancelSocket() {
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        wsHealthy = false
    }
}
