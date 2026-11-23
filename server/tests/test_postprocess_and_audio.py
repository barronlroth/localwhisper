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


def test_very_casual_keeps_commas_lowercases_and_drops_trailing_period() -> None:
    entries = [
        DictionaryEntry(spoken="whisper flow", replacement="Wispr Flow"),
        DictionaryEntry(spoken="nyc", replacement="NYC", case_sensitive=True),
    ]
    cleaned = clean_transcript(
        "Um, yeah, I'm on my way right now.",
        mode="very_casual",
        dictionary=entries,
    )
    assert cleaned == "yeah, i'm on my way right now"

    # Keeps question marks, exclamation points, and ellipsis
    assert clean_transcript("Wait, are you coming?", mode="very_casual") == "wait, are you coming?"
    assert clean_transcript("Let's go!", mode="very_casual") == "let's go!"
    assert clean_transcript("Hmm, maybe...", mode="very_casual") == "maybe..."

    # Applies spelling fix in lowercase for normal dictionary entries, preserves case_sensitive entries
    assert (
        clean_transcript("Testing whisper flow in nyc.", mode="very_casual", dictionary=entries)
        == "testing wispr flow in NYC"
    )


def test_very_casual_preserves_case_sensitive_dictionary_entry() -> None:
    entries = [DictionaryEntry(spoken="nyc", replacement="NYC", case_sensitive=True)]
    assert clean_transcript("Headed to nyc.", mode="very_casual", dictionary=entries) == "headed to NYC"


def test_casual_keeps_normal_casing_and_drops_trailing_period() -> None:
    cleaned = clean_transcript("Um, yeah, I'm on my way right now.", mode="casual")
    assert cleaned == "Yeah, I'm on my way right now"
    assert clean_transcript("Are you free tonight?", mode="casual") == "Are you free tonight?"


def test_dictionary_store_crud_and_hot_reload(tmp_path) -> None:
    import json
    from dictionary_store import DictionaryStore

    dict_file = tmp_path / "dictionary.json"
    store = DictionaryStore(path=dict_file)

    # First run seeds default entries and persists them to disk
    snap = store.snapshot()
    assert dict_file.exists()
    assert any(e["replacement"] == "Tailscale" for e in snap["entries"])

    # Upsert a new entry without clobbering existing ones
    snap = store.upsert({"id": "custom-1", "spoken": "super whisper", "replacement": "Superwhisper", "case_sensitive": False})
    assert any(e["id"] == "custom-1" and e["replacement"] == "Superwhisper" for e in snap["entries"])

    # Delete that entry
    snap = store.delete("custom-1")
    assert all(e["id"] != "custom-1" for e in snap["entries"])

    # Replace all with a single custom entry and verify merge precedence over client entries
    store.replace_all([{"id": "srv-1", "spoken": "local whisper", "replacement": "LocalWhisper", "case_sensitive": True}])
    merged = store.merged_for_postprocess([
        DictionaryEntry(spoken="local whisper", replacement="WrongName", case_sensitive=True),
        DictionaryEntry(spoken="ipad", replacement="iPad", case_sensitive=False),
    ])
    by_spoken = {e.spoken.lower(): e.replacement for e in merged}
    assert by_spoken["local whisper"] == "LocalWhisper"
    assert by_spoken["ipad"] == "iPad"

    # Manual disk edit hot-reloads without restarting server
    raw = json.loads(dict_file.read_text(encoding="utf-8"))
    raw["entries"].append({"id": "disk-1", "spoken": "xcode gen", "replacement": "XcodeGen", "case_sensitive": False})
    dict_file.write_text(json.dumps(raw), encoding="utf-8")
    # Bump mtime forward to guarantee stat change even on coarse filesystems
    import os
    st = dict_file.stat()
    os.utime(dict_file, ns=(st.st_atime_ns, st.st_mtime_ns + 1_000_000_000))
    assert any(e["replacement"] == "XcodeGen" for e in store.snapshot()["entries"])


