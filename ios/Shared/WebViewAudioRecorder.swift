import Foundation
import UIKit
import WebKit

public struct CaptureMetrics: Sendable, Equatable {
    public var wkMs: Double = 0
    public var jsMs: Double = 0
    public var gumMs: Double = 0
    public var firstChunkMs: Double = 0
    public var hardwareSampleRate: Int = 0
    public var wasPrewarmed: Bool = false

    public var summary: String {
        let pre = wasPrewarmed ? "warm" : "cold"
        return "\(pre) wk=\(Int(wkMs))ms gum=\(Int(gumMs))ms first=\(Int(firstChunkMs))ms @\(hardwareSampleRate)Hz"
    }
}

public enum WebViewMicError: LocalizedError, Sendable {
    case permissionDenied
    case micUnavailable(String)
    case webViewNotAttached
    case startTimedOut

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access denied. Tap to grant permission in LocalWhisper."
        case .micUnavailable(let detail):
            return "Microphone unavailable: \(detail)"
        case .webViewNotAttached:
            return "Audio bridge not ready"
        case .startTimedOut:
            return "Microphone took too long to start. Try again."
        }
    }
}

/// Captures live 16 kHz mono Int16 PCM directly inside an iOS keyboard extension
/// without leaving the host app, using an invisible 1x1 pt (alpha 0.01) WKWebView
/// running getUserMedia over an RFC 2606 `.invalid` HTTPS origin + dead-man's switch.
@MainActor
public final class WebViewAudioRecorder: NSObject {
    public var onPCMChunk: ((Data, Float) -> Void)?
    public var onAudioLevel: ((Float) -> Void)?
    public var onRecordingLive: ((CaptureMetrics) -> Void)?
    public var onError: ((WebViewMicError) -> Void)?
    public var onDiagnostic: ((String) -> Void)?

    public private(set) var isRecording = false
    public private(set) var isWebPageReady = false
    public private(set) var latestMetrics = CaptureMetrics()

    private static let secureOriginHost = "dictation.local.invalid"
    private static let secureBaseURL = URL(string: "https://dictation.local.invalid/")!
    private static let bridgeHandlerName = "audioBridge"

    private var webView: WKWebView?
    private weak var hostView: UIView?
    private var heartbeatTimer: Timer?
    private var startTimeoutTimer: Timer?
    private var pcmBuffer = Data()
    private var recordingSessionId = 0
    private var pendingStart = false
    private var startRequestedAt: CFAbsoluteTime = 0
    private var webViewCreatedAt: CFAbsoluteTime = 0
    private var recordedFirstChunk = false
    private var wasPrewarmedForRun = false

    public override init() {
        super.init()
    }

    public func attach(to view: UIView, prewarm: Bool) {
        self.hostView = view
        if let existing = webView {
            if existing.superview !== view {
                existing.removeFromSuperview()
                view.addSubview(existing)
            }
            return
        }
        if prewarm {
            ensureWebViewLoaded()
        }
    }

    public func prewarm() {
        ensureWebViewLoaded()
    }

    public func startRecording() {
        guard hostView != nil else {
            onError?(.webViewNotAttached)
            return
        }

        recordingSessionId += 1
        pcmBuffer.removeAll(keepingCapacity: true)
        recordedFirstChunk = false
        startRequestedAt = CFAbsoluteTimeGetCurrent()
        wasPrewarmedForRun = isWebPageReady
        latestMetrics = CaptureMetrics(wasPrewarmed: wasPrewarmedForRun)

        ensureWebViewLoaded()

        if isWebPageReady {
            dispatchStartToJS()
        } else {
            pendingStart = true
        }

        startTimeoutTimer?.invalidate()
        let rid = recordingSessionId
        startTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.recordingSessionId == rid, !self.recordedFirstChunk else { return }
                self.cancelRecording()
                self.onError?(.startTimedOut)
            }
        }
    }

    public func stopRecording() -> (pcmData: Data, durationSeconds: Double) {
        startTimeoutTimer?.invalidate()
        startTimeoutTimer = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        pendingStart = false

        let wasActive = isRecording
        isRecording = false

        if wasActive || webView != nil {
            webView?.evaluateJavaScript("window.__pfStop && window.__pfStop('stop')", completionHandler: nil)
        }

        let data = pcmBuffer
        pcmBuffer = Data()
        let duration = AudioWAVEncoder.durationSeconds(forPCM16Bytes: data.count, sampleRate: 16_000)
        return (data, duration)
    }

    public func cancelRecording() {
        startTimeoutTimer?.invalidate()
        startTimeoutTimer = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        pendingStart = false
        isRecording = false
        pcmBuffer.removeAll(keepingCapacity: false)
        webView?.evaluateJavaScript("window.__pfStop && window.__pfStop('cancel')", completionHandler: nil)
    }

    public func teardown() {
        cancelRecording()
        if let wv = webView {
            wv.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeHandlerName)
            wv.navigationDelegate = nil
            wv.uiDelegate = nil
            wv.removeFromSuperview()
        }
        webView = nil
        isWebPageReady = false
    }

    private func ensureWebViewLoaded() {
        guard webView == nil, let hostView else { return }
        webViewCreatedAt = CFAbsoluteTimeGetCurrent()

        let contentController = WKUserContentController()
        contentController.add(WeakScriptMessageHandler(delegate: self), name: Self.bridgeHandlerName)

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .nonPersistent()

        // Must stay attached, non-hidden, and alpha > 0 so WebKit does not throttle media capture.
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        wv.alpha = 0.01
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.isUserInteractionEnabled = false
        wv.scrollView.isScrollEnabled = false
        wv.uiDelegate = self
        wv.navigationDelegate = self
        wv.accessibilityElementsHidden = true

        hostView.addSubview(wv)
        self.webView = wv
        self.isWebPageReady = false

        let wkMs = (CFAbsoluteTimeGetCurrent() - webViewCreatedAt) * 1000.0
        latestMetrics.wkMs = wkMs
        wv.loadHTMLString(Self.captureHTML, baseURL: Self.secureBaseURL)
    }

    private func dispatchStartToJS() {
        pendingStart = false
        isRecording = true
        let rid = recordingSessionId
        startHeartbeat()
        webView?.evaluateJavaScript("window.__pfStart && window.__pfStart(\(rid))") { [weak self] _, err in
            if let err {
                Task { @MainActor in
                    self?.onDiagnostic?("JS start error: \(err.localizedDescription)")
                }
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        // Dead-man's switch: ping every 1.0s; JS kills the mic after 3.0s without a ping.
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording, let wv = self.webView else { return }
                _ = try? await wv.evaluateJavaScript("window.__pfPing && window.__pfPing()")
            }
        }
    }

    private func handleBridgeMessage(_ body: [String: Any]) {
        guard let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            isWebPageReady = true
            let jsMs = (CFAbsoluteTimeGetCurrent() - webViewCreatedAt) * 1000.0
            latestMetrics.jsMs = jsMs
            onDiagnostic?("WebMic ready (js=\(Int(jsMs))ms)")
            if pendingStart {
                dispatchStartToJS()
            }

        case "live":
            let rid = (body["rid"] as? Int) ?? -1
            guard rid == recordingSessionId else { return }
            let sr = (body["sampleRate"] as? Int) ?? 48_000
            let gumMs = (CFAbsoluteTimeGetCurrent() - startRequestedAt) * 1000.0
            latestMetrics.hardwareSampleRate = sr
            latestMetrics.gumMs = gumMs
            onDiagnostic?("WebMic live @\(sr)Hz (gum=\(Int(gumMs))ms)")

        case "chunk":
            let rid = (body["rid"] as? Int) ?? -1
            guard isRecording, rid == recordingSessionId else { return }
            let level = Float((body["level"] as? Double) ?? 0.0)
            onAudioLevel?(level)

            if let b64 = body["pcm"] as? String, let chunk = Data(base64Encoded: b64), !chunk.isEmpty {
                if !recordedFirstChunk {
                    recordedFirstChunk = true
                    startTimeoutTimer?.invalidate()
                    startTimeoutTimer = nil
                    latestMetrics.firstChunkMs = (CFAbsoluteTimeGetCurrent() - startRequestedAt) * 1000.0
                    let summary = latestMetrics.summary
                    SharedStore.shared.lastDiagnostic = summary
                    onDiagnostic?(summary)
                    onRecordingLive?(latestMetrics)
                }
                pcmBuffer.append(chunk)
                onPCMChunk?(chunk, level)
            }

        case "error":
            let rid = (body["rid"] as? Int) ?? recordingSessionId
            guard rid == recordingSessionId else { return }
            let name = (body["name"] as? String) ?? "Error"
            let message = (body["message"] as? String) ?? "Unknown microphone error"
            cancelRecording()
            onDiagnostic?("WebMic error: \(name) - \(message)")
            if name == "NotAllowedError" || name == "PermissionDeniedError" {
                onError?(.permissionDenied)
            } else {
                onError?(.micUnavailable("\(name): \(message)"))
            }

        case "stopped":
            let reason = (body["reason"] as? String) ?? "stop"
            onDiagnostic?("WebMic stopped (\(reason))")

        default:
            break
        }
    }

    // MARK: - Inline HTML/JS Audio Capture Engine

    private static let captureHTML: String = """
    <!DOCTYPE html>
    <html>
    <head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
    <body>
    <script>
    (function() {
      const TARGET_SR = 16000;
      const BUFFER_SIZE = 4096;
      const WATCHDOG_MS = 3200;

      let stream = null;
      let audioCtx = null;
      let source = null;
      let processor = null;
      let muteGain = null;
      let watchdog = null;
      let running = false;
      let activeRid = 0;
      let lastPing = 0;
      let phase = 0;
      let prevSample = 0;

      function post(msg) {
        try {
          window.webkit.messageHandlers.audioBridge.postMessage(msg);
        } catch (e) {}
      }

      function int16ToBase64(int16Arr) {
        const bytes = new Uint8Array(int16Arr.buffer, int16Arr.byteOffset, int16Arr.byteLength);
        let binary = "";
        const chunk = 0x8000;
        for (let i = 0; i < bytes.length; i += chunk) {
          binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
        }
        return btoa(binary);
      }

      function downsampleTo16k(input, inputRate) {
        if (inputRate === TARGET_SR) {
          const out = new Int16Array(input.length);
          for (let i = 0; i < input.length; i++) {
            const s = Math.max(-1, Math.min(1, input[i]));
            out[i] = s < 0 ? (s * 32768) | 0 : (s * 32767) | 0;
          }
          return out;
        }

        const ratio = inputRate / TARGET_SR;
        const maxOut = Math.ceil(input.length / ratio) + 1;
        const out = new Int16Array(maxOut);
        let outIdx = 0;

        while (phase < input.length) {
          const i0 = Math.floor(phase);
          const frac = phase - i0;
          const s0 = i0 < 0 ? prevSample : input[i0];
          const s1 = (i0 + 1) < input.length ? input[i0 + 1] : s0;
          const val = Math.max(-1, Math.min(1, s0 + (s1 - s0) * frac));
          out[outIdx++] = val < 0 ? (val * 32768) | 0 : (val * 32767) | 0;
          phase += ratio;
        }
        phase -= input.length;
        prevSample = input.length > 0 ? input[input.length - 1] : 0;
        return out.subarray(0, outIdx);
      }

      function cleanup(reason) {
        running = false;
        if (watchdog) {
          clearInterval(watchdog);
          watchdog = null;
        }
        try { if (processor) { processor.onaudioprocess = null; processor.disconnect(); } } catch (e) {}
        try { if (source) source.disconnect(); } catch (e) {}
        try { if (muteGain) muteGain.disconnect(); } catch (e) {}
        try {
          if (stream) {
            stream.getTracks().forEach(t => t.stop());
          }
        } catch (e) {}
        try {
          if (audioCtx && audioCtx.state !== "closed") {
            audioCtx.close();
          }
        } catch (e) {}

        processor = null;
        source = null;
        muteGain = null;
        stream = null;
        audioCtx = null;
        phase = 0;
        prevSample = 0;

        if (reason) {
          post({ type: "stopped", reason: reason });
        }
      }

      window.__pfPing = function() {
        lastPing = Date.now();
      };

      window.__pfStop = function(reason) {
        cleanup(reason || "stop");
      };

      window.__pfStart = async function(rid) {
        cleanup(null);
        activeRid = rid;
        lastPing = Date.now();

        if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
          post({ type: "error", rid: rid, name: "NotSupportedError", message: "getUserMedia unavailable in this WebView" });
          return;
        }

        try {
          stream = await navigator.mediaDevices.getUserMedia({
            audio: {
              channelCount: 1,
              echoCancellation: true,
              noiseSuppression: true,
              autoGainControl: true
            },
            video: false
          });

          if (activeRid !== rid) {
            cleanup("superseded");
            return;
          }

          const AudioCtx = window.AudioContext || window.webkitAudioContext;
          audioCtx = new AudioCtx();
          if (audioCtx.state === "suspended") {
            await audioCtx.resume();
          }

          source = audioCtx.createMediaStreamSource(stream);
          processor = audioCtx.createScriptProcessor(BUFFER_SIZE, 1, 1);
          muteGain = audioCtx.createGain();
          muteGain.gain.value = 0.0;

          const inputRate = audioCtx.sampleRate || 48000;
          phase = 0;
          prevSample = 0;
          running = true;

          post({ type: "live", rid: rid, sampleRate: inputRate });

          watchdog = setInterval(function() {
            if (running && (Date.now() - lastPing) > WATCHDOG_MS) {
              cleanup("watchdog");
            }
          }, 500);

          processor.onaudioprocess = function(ev) {
            if (!running || activeRid !== rid) return;
            const channel = ev.inputBuffer.getChannelData(0);

            let sumSq = 0;
            for (let i = 0; i < channel.length; i++) {
              const v = channel[i];
              sumSq += v * v;
            }
            const rms = Math.sqrt(sumSq / channel.length);
            const level = Math.min(1.0, Math.pow(rms * 7.5, 0.72));

            const pcm16 = downsampleTo16k(channel, inputRate);
            post({
              type: "chunk",
              rid: rid,
              level: level,
              samples: pcm16.length,
              pcm: int16ToBase64(pcm16)
            });
          };

          source.connect(processor);
          processor.connect(muteGain);
          muteGain.connect(audioCtx.destination);
        } catch (err) {
          cleanup(null);
          post({
            type: "error",
            rid: rid,
            name: (err && err.name) ? err.name : "Error",
            message: (err && err.message) ? err.message : String(err)
          });
        }
      };

      post({ type: "ready" });
    })();
    </script>
    </body>
    </html>
    """
}

extension WebViewAudioRecorder: WKUIDelegate, WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        if type == .microphone && origin.host == Self.secureOriginHost {
            decisionHandler(.grant)
        } else {
            decisionHandler(.deny)
        }
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isWebPageReady = false
        if isRecording {
            cancelRecording()
            onError?(.micUnavailable("Audio helper restarted — tap to try again"))
        }
        webView.loadHTMLString(Self.captureHTML, baseURL: Self.secureBaseURL)
    }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var delegate: WebViewAudioRecorder?

    init(delegate: WebViewAudioRecorder) {
        self.delegate = delegate
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        Task { @MainActor [weak delegate] in
            delegate?.receiveScriptMessage(body)
        }
    }
}

private extension WebViewAudioRecorder {
    func receiveScriptMessage(_ body: [String: Any]) {
        handleBridgeMessage(body)
    }
}
