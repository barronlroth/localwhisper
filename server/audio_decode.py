"""Fast audio decoding with zero-subprocess fast paths for 16 kHz mono PCM/WAV."""

from __future__ import annotations

import io
import os
import shutil
import subprocess
import tempfile
import wave
from pathlib import Path

import numpy as np

TARGET_SAMPLE_RATE = 16_000


def pcm_s16le_to_float32(pcm_bytes: bytes) -> np.ndarray:
    """Convert raw little-endian 16-bit mono PCM bytes to normalized float32 [-1, 1]."""
    if not pcm_bytes:
        return np.zeros((0,), dtype=np.float32)
    usable = len(pcm_bytes) - (len(pcm_bytes) % 2)
    if usable <= 0:
        return np.zeros((0,), dtype=np.float32)
    samples = np.frombuffer(pcm_bytes[:usable], dtype="<i2").astype(np.float32)
    return samples / 32768.0


def try_decode_wav_fast(data: bytes, target_sr: int = TARGET_SAMPLE_RATE) -> np.ndarray | None:
    """Decode uncompressed 16-bit PCM WAV directly in memory without spawning ffmpeg."""
    if len(data) < 44 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        return None
    try:
        with wave.open(io.BytesIO(data), "rb") as wf:
            channels = wf.getnchannels()
            sample_width = wf.getsampwidth()
            sample_rate = wf.getframerate()
            comp_type = wf.getcomptype()
            if comp_type != "NONE" or sample_width != 2:
                return None
            frames = wf.readframes(wf.getnframes())
    except (wave.Error, EOFError):
        return None

    pcm = np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0
    if channels > 1:
        usable = len(pcm) - (len(pcm) % channels)
        pcm = pcm[:usable].reshape(-1, channels).mean(axis=1)

    if sample_rate == target_sr:
        return pcm

    # Fast linear resample for clean integer/common ratios if needed
    if sample_rate > 0 and len(pcm) > 1:
        ratio = target_sr / float(sample_rate)
        out_len = max(1, int(round(len(pcm) * ratio)))
        x_old = np.linspace(0.0, 1.0, num=len(pcm), endpoint=False)
        x_new = np.linspace(0.0, 1.0, num=out_len, endpoint=False)
        return np.interp(x_new, x_old, pcm).astype(np.float32)

    return None


def decode_audio_bytes(
    data: bytes,
    filename: str = "audio.wav",
    content_type: str | None = None,
    sample_rate: int = TARGET_SAMPLE_RATE,
    target_sr: int = TARGET_SAMPLE_RATE,
) -> np.ndarray:
    """Decode arbitrary audio bytes to 16 kHz mono float32 numpy array."""
    if not data:
        return np.zeros((0,), dtype=np.float32)

    ct = (content_type or "").lower()
    if "audio/pcm" in ct or filename.lower().endswith(".pcm"):
        audio = pcm_s16le_to_float32(data)
        if sample_rate != target_sr and len(audio) > 1:
            out_len = max(1, int(round(len(audio) * (target_sr / float(sample_rate)))))
            x_old = np.linspace(0.0, 1.0, num=len(audio), endpoint=False)
            x_new = np.linspace(0.0, 1.0, num=out_len, endpoint=False)
            return np.interp(x_new, x_old, audio).astype(np.float32)
        return audio

    fast = try_decode_wav_fast(data, target_sr=target_sr)
    if fast is not None:
        return fast

    ffmpeg_bin = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
    if not os.path.exists(ffmpeg_bin):
        raise RuntimeError("ffmpeg not found on PATH or /opt/homebrew/bin/ffmpeg")

    suffix = Path(filename).suffix.lower() or ".audio"
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
        tmp.write(data)
        tmp_path = tmp.name

    try:
        cmd = [
            ffmpeg_bin,
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            tmp_path,
            "-threads",
            "0",
            "-f",
            "s16le",
            "-ac",
            "1",
            "-acodec",
            "pcm_s16le",
            "-ar",
            str(target_sr),
            "-",
        ]
        proc = subprocess.run(cmd, capture_output=True, check=True)
        return pcm_s16le_to_float32(proc.stdout)
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"ffmpeg decode failed: {stderr}") from exc
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def is_effectively_silent(audio: np.ndarray, rms_threshold: float = 0.0015) -> bool:
    """Return True if audio is empty, too short (<80ms), or nearly pure digital silence."""
    if len(audio) < int(TARGET_SAMPLE_RATE * 0.08):
        return True
    rms = float(np.sqrt(np.mean(np.square(audio, dtype=np.float64))))
    return rms < rms_threshold
