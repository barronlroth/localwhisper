import AVFoundation
import Foundation

/// Native AVAudioEngine recorder producing 16 kHz mono Int16 PCM chunks with live RMS metering.
/// Used inside the companion app's Dictation Playground and the optional fallback dictation sheet.
@MainActor
final class NativeAudioRecorder {
    var onPCMChunk: ((Data, Float) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onError: ((Error) -> Void)?

    private let engine = AVAudioEngine()
    private var pcmBuffer = Data()
    private(set) var isRecording = false

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    func startRecording() throws {
        guard !isRecording else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        pcmBuffer.removeAll(keepingCapacity: true)
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw NSError(domain: "NativeAudioRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "No audio input available"])
        }

        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw NSError(domain: "NativeAudioRecorder", code: -2, userInfo: [NSLocalizedDescriptionKey: "Could not create audio converter"])
        }

        inputNode.removeTap(onBus: 0)
        let targetFmt = self.targetFormat

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }

            let ratio = targetFmt.sampleRate / hwFormat.sampleRate
            let capacity = AVAudioFrameCount(max(1, Int(ceil(Double(buffer.frameLength) * ratio)) + 16))
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFmt, frameCapacity: capacity) else { return }

            var error: NSError?
            var didSupplyInput = false
            converter.convert(to: converted, error: &error) { _, outStatus in
                if didSupplyInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                didSupplyInput = true
                outStatus.pointee = .haveData
                return buffer
            }

            let frames = Int(converted.frameLength)
            guard error == nil, frames > 0, let int16Ptr = converted.int16ChannelData?.pointee else { return }

            var sumSq: Double = 0
            for i in 0..<frames {
                let norm = Double(int16Ptr[i]) / 32768.0
                sumSq += norm * norm
            }
            let rms = sqrt(sumSq / Double(frames))
            let level = Float(min(1.0, pow(rms * 7.5, 0.72)))
            let chunk = Data(bytes: int16Ptr, count: frames * MemoryLayout<Int16>.size)

            Task { @MainActor in
                guard self.isRecording else { return }
                self.pcmBuffer.append(chunk)
                self.onAudioLevel?(level)
                self.onPCMChunk?(chunk, level)
            }
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stopRecording() -> (pcmData: Data, durationSeconds: Double) {
        guard isRecording else { return (Data(), 0) }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let data = pcmBuffer
        pcmBuffer = Data()
        let duration = AudioWAVEncoder.durationSeconds(forPCM16Bytes: data.count, sampleRate: 16_000)
        return (data, duration)
    }

    func cancelRecording() {
        _ = stopRecording()
    }
}
