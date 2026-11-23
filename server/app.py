"""Local Apple Silicon Parakeet MLX transcription server for LocalWhisper iOS."""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import time
from contextlib import asynccontextmanager
from typing import Any

import mlx.core as mx
import numpy as np
from fastapi import (
    Body,
    Depends,
    FastAPI,
    File,
    Form,
    Header,
    HTTPException,
    Request,
    UploadFile,
    WebSocket,
    WebSocketDisconnect,
)
from fastapi.responses import JSONResponse
from parakeet_mlx import from_pretrained
from parakeet_mlx.audio import get_logmel
from parakeet_mlx.parakeet import (
    DecodingConfig,
    merge_longest_common_subsequence,
    merge_longest_contiguous,
    sentences_to_result,
    tokens_to_sentences,
)

from audio_decode import (
    TARGET_SAMPLE_RATE,
    decode_audio_bytes,
    is_effectively_silent,
    pcm_s16le_to_float32,
)
from dictionary_store import DictionaryStore
from postprocess import DictionaryEntry, clean_transcript

logging.basicConfig(
    level=os.environ.get("PARAKEET_LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("localwhisper")

MODEL_ID = os.environ.get("PARAKEET_MODEL", "mlx-community/parakeet-tdt-0.6b-v3")
API_KEY = os.environ.get("PARAKEET_API_KEY", "").strip()
MAX_AUDIO_SECONDS = float(os.environ.get("PARAKEET_MAX_SECONDS", "300"))
CHUNK_THRESHOLD_SECONDS = float(os.environ.get("PARAKEET_CHUNK_SECONDS", "90"))
KEEPWARM_INTERVAL_SECONDS = float(os.environ.get("PARAKEET_KEEPWARM_SECONDS", "180"))
DEBUG_LOG_TEXT = os.environ.get("PARAKEET_DEBUG_TEXT", "0") == "1"


class ParakeetEngine:
    """Thread-safe wrapper around a preloaded Parakeet MLX model."""

    def __init__(self, model_id: str) -> None:
        self.model_id = model_id
        self.model: Any = None
        self.started_at = time.time()
        self.last_used_at = time.time()
        self.ready = False
        self._lock = asyncio.Lock()

    def _warmup_sync(self) -> None:
        if self.model is None:
            return
        warmup_audio = mx.zeros((TARGET_SAMPLE_RATE // 4,), dtype=mx.float32)
        warmup_mel = get_logmel(warmup_audio, self.model.preprocessor_config)
        _ = self.model.generate(warmup_mel)

    def load_sync(self) -> None:
        t0 = time.perf_counter()
        logger.info("Loading Parakeet MLX model: %s", self.model_id)
        self.model = from_pretrained(self.model_id)
        t1 = time.perf_counter()
        self._warmup_sync()
        t2 = time.perf_counter()
        self.last_used_at = time.time()
        self.ready = True
        logger.info(
            "Parakeet ready (load=%.2fs, warmup=%.2fs, sr=%d)",
            t1 - t0,
            t2 - t1,
            self.model.preprocessor_config.sample_rate,
        )

    async def keepwarm_once(self) -> None:
        """Touch model weights & Metal pipeline when idle so macOS won't page them out."""
        if not self.ready:
            return
        if time.time() - self.last_used_at < max(30.0, KEEPWARM_INTERVAL_SECONDS * 0.8):
            return
        if self._lock.locked():
            return
        async with self._lock:
            t0 = time.perf_counter()
            await asyncio.to_thread(self._warmup_sync)
            self.last_used_at = time.time()
            logger.debug("Keep-warm pass completed in %.1fms", (time.perf_counter() - t0) * 1000.0)

    def _transcribe_samples_sync(self, samples: np.ndarray) -> str:
        if self.model is None:
            raise RuntimeError("Parakeet model is not loaded")

        sr = int(self.model.preprocessor_config.sample_rate)
        audio_mx = mx.array(samples, dtype=mx.float32)
        duration_sec = len(samples) / float(sr)

        if duration_sec <= CHUNK_THRESHOLD_SECONDS:
            mel = get_logmel(audio_mx, self.model.preprocessor_config)
            result = self.model.generate(mel)[0]
            return (result.text or "").strip()

        # Overlapping chunked decoding for long dictations (>90s)
        chunk_samples = int(CHUNK_THRESHOLD_SECONDS * sr)
        overlap_duration = 15.0
        overlap_samples = int(overlap_duration * sr)
        decoding_config = DecodingConfig()
        all_tokens = []

        for start in range(0, len(samples), chunk_samples - overlap_samples):
            end = min(start + chunk_samples, len(samples))
            if end - start < self.model.preprocessor_config.hop_length:
                break
            chunk_mel = get_logmel(audio_mx[start:end], self.model.preprocessor_config)
            chunk_result = self.model.generate(chunk_mel, decoding_config=decoding_config)[0]
            chunk_offset = start / float(sr)
            for sentence in chunk_result.sentences:
                for token in sentence.tokens:
                    token.start += chunk_offset
                    token.end = token.start + token.duration
            if all_tokens:
                try:
                    all_tokens = merge_longest_contiguous(
                        all_tokens,
                        chunk_result.tokens,
                        overlap_duration=overlap_duration,
                    )
                except RuntimeError:
                    all_tokens = merge_longest_common_subsequence(
                        all_tokens,
                        chunk_result.tokens,
                        overlap_duration=overlap_duration,
                    )
            else:
                all_tokens = chunk_result.tokens

        result = sentences_to_result(tokens_to_sentences(all_tokens, decoding_config.sentence))
        return (result.text or "").strip()

    async def transcribe(self, samples: np.ndarray) -> tuple[str, float]:
        if is_effectively_silent(samples):
            return "", 0.0
        async with self._lock:
            t0 = time.perf_counter()
            raw_text = await asyncio.to_thread(self._transcribe_samples_sync, samples)
            self.last_used_at = time.time()
            inference_ms = (time.perf_counter() - t0) * 1000.0
            return raw_text, inference_ms


engine = ParakeetEngine(MODEL_ID)
dictionary_store = DictionaryStore()


def _parse_dictionary(raw: str | list[dict[str, Any]] | None) -> list[DictionaryEntry]:
    if not raw:
        return []
    items: Any = raw
    if isinstance(raw, str):
        try:
            items = json.loads(raw)
        except json.JSONDecodeError:
            return []
    if not isinstance(items, list):
        return []
    entries: list[DictionaryEntry] = []
    for item in items:
        if isinstance(item, dict):
            spoken = str(item.get("spoken") or "").strip()
            replacement = str(item.get("replacement") or "")
            if spoken and replacement:
                entries.append(
                    DictionaryEntry(
                        spoken=spoken,
                        replacement=replacement,
                        case_sensitive=bool(item.get("case_sensitive", False)),
                    )
                )
        elif isinstance(item, str) and item.strip():
            word = item.strip()
            entries.append(DictionaryEntry(spoken=word, replacement=word))
    return entries


def _verify_auth(authorization: str | None = Header(default=None)) -> None:
    if not API_KEY:
        return
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing Bearer token")
    token = authorization.removeprefix("Bearer ").strip()
    if token != API_KEY:
        raise HTTPException(status_code=403, detail="Invalid API token")


async def _keepwarm_loop() -> None:
    if KEEPWARM_INTERVAL_SECONDS <= 0:
        return
    while True:
        await asyncio.sleep(KEEPWARM_INTERVAL_SECONDS)
        try:
            await engine.keepwarm_once()
        except Exception:
            logger.exception("Keep-warm pass failed")


@asynccontextmanager
async def lifespan(_: FastAPI):
    await asyncio.to_thread(engine.load_sync)
    keepwarm_task = asyncio.create_task(_keepwarm_loop())
    try:
        yield
    finally:
        keepwarm_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await keepwarm_task


app = FastAPI(
    title="LocalWhisper Transcription Server",
    version="1.0.0",
    lifespan=lifespan,
)


@app.get("/health")
async def health() -> dict[str, Any]:
    return {
        "status": "ok" if engine.ready else "loading",
        "ready": engine.ready,
        "model": engine.model_id,
        "sample_rate": TARGET_SAMPLE_RATE,
        "device": "apple-silicon-mlx",
        "auth_required": bool(API_KEY),
        "uptime_seconds": round(time.time() - engine.started_at, 1),
    }


@app.get("/v1/dictionary", dependencies=[Depends(_verify_auth)])
async def get_dictionary() -> dict[str, Any]:
    return dictionary_store.snapshot()


@app.put("/v1/dictionary", dependencies=[Depends(_verify_auth)])
async def put_dictionary(payload: dict[str, Any] = Body(...)) -> dict[str, Any]:
    entries = payload.get("entries")
    if not isinstance(entries, list):
        raise HTTPException(status_code=400, detail="Expected JSON object with 'entries' list")
    return dictionary_store.replace_all(entries)


@app.post("/v1/dictionary", dependencies=[Depends(_verify_auth)])
async def upsert_dictionary_entry(payload: dict[str, Any] = Body(...)) -> dict[str, Any]:
    try:
        return dictionary_store.upsert(payload)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.delete("/v1/dictionary/{entry_id}", dependencies=[Depends(_verify_auth)])
async def delete_dictionary_entry(entry_id: str) -> dict[str, Any]:
    return dictionary_store.delete(entry_id)


@app.post("/v1/transcribe", dependencies=[Depends(_verify_auth)])
async def transcribe_endpoint(
    request: Request,
    file: UploadFile | None = File(default=None),
    mode: str = Form(default="clean"),
    dictionary: str | None = Form(default=None),
    context: str | None = Form(default=None),
    smart_spacing: bool = Form(default=True),
) -> JSONResponse:
    t_total = time.perf_counter()
    if not engine.ready:
        raise HTTPException(status_code=503, detail="Parakeet model is still loading")

    content_type = request.headers.get("content-type", "")

    if file is not None:
        audio_bytes = await file.read()
        filename = file.filename or "audio.wav"
        audio_ct = file.content_type
        sample_rate = int(request.headers.get("x-sample-rate", TARGET_SAMPLE_RATE))
    else:
        # Raw audio body fast path (audio/wav or audio/pcm)
        audio_bytes = await request.body()
        filename = "audio.pcm" if "audio/pcm" in content_type.lower() else "audio.wav"
        audio_ct = content_type
        sample_rate = int(request.headers.get("x-sample-rate", TARGET_SAMPLE_RATE))
        mode = request.headers.get("x-mode", mode)
        context = request.headers.get("x-context", context)
        dictionary = request.headers.get("x-dictionary", dictionary)
        smart_spacing = request.headers.get("x-smart-spacing", "true").lower() != "false"

    if not audio_bytes:
        raise HTTPException(status_code=400, detail="Empty audio payload")

    try:
        samples = await asyncio.to_thread(
            decode_audio_bytes,
            audio_bytes,
            filename,
            audio_ct,
            sample_rate,
            TARGET_SAMPLE_RATE,
        )
    except Exception as exc:
        logger.exception("Audio decode error")
        raise HTTPException(status_code=400, detail=f"Could not decode audio: {exc}") from exc

    duration_seconds = len(samples) / float(TARGET_SAMPLE_RATE)
    if duration_seconds > MAX_AUDIO_SECONDS:
        raise HTTPException(
            status_code=413,
            detail=f"Audio exceeds maximum length of {int(MAX_AUDIO_SECONDS)}s",
        )

    raw_text, inference_ms = await engine.transcribe(samples)
    dict_entries = dictionary_store.merged_for_postprocess(_parse_dictionary(dictionary))
    cleaned = clean_transcript(
        raw_text,
        mode=mode,
        dictionary=dict_entries,
        context_before=context,
        smart_spacing=smart_spacing,
    )

    total_ms = (time.perf_counter() - t_total) * 1000.0
    if DEBUG_LOG_TEXT:
        logger.info(
            "HTTP transcribe dur=%.2fs inf=%.1fms total=%.1fms text=%r",
            duration_seconds,
            inference_ms,
            total_ms,
            cleaned,
        )
    else:
        logger.info(
            "HTTP transcribe dur=%.2fs inf=%.1fms total=%.1fms chars=%d mode=%s",
            duration_seconds,
            inference_ms,
            total_ms,
            len(cleaned),
            mode,
        )

    return JSONResponse(
        content={
            "text": cleaned,
            "raw_text": raw_text,
            "duration_seconds": round(duration_seconds, 3),
            "inference_ms": round(inference_ms, 1),
            "total_ms": round(total_ms, 1),
            "model": engine.model_id,
            "mode": mode,
        }
    )


@app.websocket("/v1/stream")
async def stream_endpoint(ws: WebSocket) -> None:
    """Streaming upload WebSocket: receive 16kHz Int16 PCM frames live while speaking,
    then run Parakeet immediately on 'stop' with zero post-stop upload latency."""
    if API_KEY:
        auth_header = ws.headers.get("authorization", "")
        query_token = ws.query_params.get("token", "")
        bearer = auth_header.removeprefix("Bearer ").strip() if auth_header.startswith("Bearer ") else ""
        if bearer != API_KEY and query_token != API_KEY:
            await ws.close(code=4401, reason="Unauthorized")
            return

    await ws.accept()

    pcm_buffer = bytearray()
    mode = "clean"
    context: str | None = None
    dictionary: list[DictionaryEntry] = []
    smart_spacing = True
    sample_rate = TARGET_SAMPLE_RATE
    max_bytes = int(MAX_AUDIO_SECONDS * TARGET_SAMPLE_RATE * 2)

    try:
        while True:
            msg = await ws.receive()
            if msg["type"] == "websocket.disconnect":
                return

            if msg.get("bytes") is not None:
                chunk = msg["bytes"]
                if len(pcm_buffer) + len(chunk) <= max_bytes:
                    pcm_buffer.extend(chunk)
                continue

            text_payload = msg.get("text")
            if not text_payload:
                continue

            try:
                event = json.loads(text_payload)
            except json.JSONDecodeError:
                await ws.send_json({"type": "error", "message": "Invalid JSON control frame"})
                continue

            event_type = event.get("type")
            if event_type == "start":
                pcm_buffer.clear()
                mode = str(event.get("mode", "clean"))
                context = event.get("context")
                dictionary = _parse_dictionary(event.get("dictionary"))
                smart_spacing = bool(event.get("smart_spacing", True))
                sample_rate = int(event.get("sample_rate", TARGET_SAMPLE_RATE))
                await ws.send_json({"type": "ready", "model": engine.model_id})

            elif event_type == "cancel":
                pcm_buffer.clear()
                await ws.send_json({"type": "cancelled"})
                await ws.close()
                return

            elif event_type == "stop":
                t_stop = time.perf_counter()
                if not engine.ready:
                    await ws.send_json({"type": "error", "message": "Parakeet model is still loading"})
                    await ws.close()
                    return

                samples = pcm_s16le_to_float32(bytes(pcm_buffer))
                if sample_rate != TARGET_SAMPLE_RATE and len(samples) > 1:
                    out_len = max(1, int(round(len(samples) * (TARGET_SAMPLE_RATE / float(sample_rate)))))
                    x_old = np.linspace(0.0, 1.0, num=len(samples), endpoint=False)
                    x_new = np.linspace(0.0, 1.0, num=out_len, endpoint=False)
                    samples = np.interp(x_new, x_old, samples).astype(np.float32)

                duration_seconds = len(samples) / float(TARGET_SAMPLE_RATE)
                raw_text, inference_ms = await engine.transcribe(samples)
                merged_dict = dictionary_store.merged_for_postprocess(dictionary)
                cleaned = clean_transcript(
                    raw_text,
                    mode=mode,
                    dictionary=merged_dict,
                    context_before=context,
                    smart_spacing=smart_spacing,
                )
                total_ms = (time.perf_counter() - t_stop) * 1000.0
                logger.info(
                    "WS transcribe dur=%.2fs inf=%.1fms total=%.1fms chars=%d mode=%s",
                    duration_seconds,
                    inference_ms,
                    total_ms,
                    len(cleaned),
                    mode,
                )
                await ws.send_json(
                    {
                        "type": "final",
                        "text": cleaned,
                        "raw_text": raw_text,
                        "duration_seconds": round(duration_seconds, 3),
                        "inference_ms": round(inference_ms, 1),
                        "total_ms": round(total_ms, 1),
                        "model": engine.model_id,
                        "mode": mode,
                    }
                )
                await ws.close()
                return

            elif event_type == "ping":
                await ws.send_json({"type": "pong"})

    except WebSocketDisconnect:
        return
    except Exception as exc:
        logger.exception("WebSocket transcription failed")
        try:
            await ws.send_json({"type": "error", "message": str(exc)})
            await ws.close()
        except Exception:
            pass


if __name__ == "__main__":
    import uvicorn

    host = os.environ.get("PARAKEET_HOST", "127.0.0.1")
    port = int(os.environ.get("PARAKEET_PORT", "43120"))
    uvicorn.run(app, host=host, port=port, log_level="info")
