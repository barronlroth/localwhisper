import Foundation

public enum AudioWAVEncoder {
    /// Wraps raw 16-bit little-endian mono PCM bytes in a standard 44-byte RIFF/WAVE header.
    public static func encodePCM16ToWAV(
        pcmData: Data,
        sampleRate: UInt32 = 16_000,
        channels: UInt16 = 1
    ) -> Data {
        let bitsPerSample: UInt16 = 16
        let byteRate: UInt32 = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = channels * (bitsPerSample / 8)
        let dataSize: UInt32 = UInt32(pcmData.count)
        let riffSize: UInt32 = 36 + dataSize

        var header = Data(capacity: 44 + pcmData.count)
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        header.appendLittleEndian(riffSize)
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        header.appendLittleEndian(UInt32(16))               // Subchunk1Size (PCM)
        header.appendLittleEndian(UInt16(1))                // AudioFormat = PCM
        header.appendLittleEndian(channels)
        header.appendLittleEndian(sampleRate)
        header.appendLittleEndian(byteRate)
        header.appendLittleEndian(blockAlign)
        header.appendLittleEndian(bitsPerSample)
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        header.appendLittleEndian(dataSize)
        header.append(pcmData)
        return header
    }

    public static func durationSeconds(forPCM16Bytes byteCount: Int, sampleRate: Double = 16_000) -> Double {
        guard byteCount > 0, sampleRate > 0 else { return 0 }
        return Double(byteCount / 2) / sampleRate
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
