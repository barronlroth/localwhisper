"""Unit tests for audio decoding and Wispr Flow–style post-processing."""

from __future__ import annotations

import io
import wave

import numpy as np

from audio_decode import decode_audio_bytes, is_effectively_silent, pcm_s16le_to_float32
from postprocess import DictionaryEntry, clean_transcript


def _make_wav(samples: np.ndarray, sample_rate: int = 16000) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        int16 = np.clip(samples * 32767.0, -32768, 32767).astype("<i2")
        wf.writeframes(int16.tobytes())
    return buf.getvalue()


def test_wav_fast_decode_roundtrip() -> None:
    t = np.linspace(0, 0.5, 8000, endpoint=False)
    sine = 0.25 * np.sin(2 * np.pi * 440 * t).astype(np.float32)
    wav_bytes = _make_wav(sine, sample_rate=16000)
    decoded = decode_audio_bytes(wav_bytes, filename="test.wav")
    assert decoded.shape == (8000,)
    assert np.allclose(decoded, sine, atol=1e-3)
    assert not is_effectively_silent(decoded)


def test_raw_pcm_decode_and_silence_detection() -> None:
    silence = np.zeros((16000,), dtype="<i2").tobytes()
    decoded = pcm_s16le_to_float32(silence)
    assert decoded.shape == (16000,)
    assert is_effectively_silent(decoded)


def test_filler_removal_and_stutters() -> None:
    raw = "Um, so I I was, uh, thinking we should ship it today."
    cleaned = clean_transcript(raw, mode="clean")
    assert cleaned == "So I was thinking we should ship it today."


def test_raw_mode_preserves_fillers() -> None:
    raw = "Um, I was thinking."
    assert clean_transcript(raw, mode="raw", smart_spacing=False) == "Um, I was thinking."


def test_personal_dictionary_and_context_spacing() -> None:
    entries = [
        DictionaryEntry(spoken="whisper flow", replacement="Wispr Flow"),
        DictionaryEntry(spoken="tail scale", replacement="Tailscale"),
    ]
    cleaned = clean_transcript(
        "Built like whisper flow over tail scale.",
        mode="clean",
        dictionary=entries,
        context_before="This app is",
    )
    assert cleaned == " built like Wispr Flow over Tailscale."


def test_context_keeps_sentence_capitalization_after_period() -> None:
    cleaned = clean_transcript(
        "Ready to test.",
        mode="clean",
        context_before="First sentence.",
    )
    assert cleaned == " Ready to test."


def test_context_protects_dictionary_brand_casing_mid_sentence() -> None:
    entries = [DictionaryEntry(spoken="tailscale", replacement="Tailscale")]
    cleaned = clean_transcript(
        "Tailscale handles the HTTPS tunnel.",
        mode="clean",
        dictionary=entries,
        context_before="Because",
    )
    assert cleaned == " Tailscale handles the HTTPS tunnel."


def test_spoken_line_breaks_and_notes_mode() -> None:
    cleaned = clean_transcript(
        "bullet buy milk next bullet call mom",
        mode="notes",
    )
    assert cleaned == "- Buy milk\n- Call mom"
