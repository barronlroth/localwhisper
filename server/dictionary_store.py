"""File-backed personal dictionary store hosted on the Mac server.

All connected iOS/iPadOS/macOS clients share one canonical dictionary stored as
plain, human-editable JSON on the Mac (auto-reloaded if edited directly on disk).
"""

from __future__ import annotations

import json
import os
import threading
import time
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable

from postprocess import DictionaryEntry

DEFAULT_DICTIONARY_PATH = (
    Path.home() / "Library" / "Application Support" / "LocalWhisper" / "dictionary.json"
)

_SEED_ENTRIES = [
    ("whisper flow", "Wispr Flow", False),
    ("whisperflow", "Wispr Flow", False),
    ("tail scale", "Tailscale", False),
    ("parakeet", "Parakeet", False),
]


@dataclass
class StoredDictionaryEntry:
    id: str
    spoken: str
    replacement: str
    case_sensitive: bool = False

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    def to_postprocess(self) -> DictionaryEntry:
        return DictionaryEntry(
            spoken=self.spoken,
            replacement=self.replacement,
            case_sensitive=self.case_sensitive,
        )


def _normalize_item(item: dict[str, Any]) -> StoredDictionaryEntry | None:
    spoken = str(item.get("spoken") or "").strip()
    replacement = str(item.get("replacement") or "").strip()
    if not spoken or not replacement:
        return None
    raw_id = str(item.get("id") or "").strip()
    entry_id = raw_id if raw_id else str(uuid.uuid4())
    return StoredDictionaryEntry(
        id=entry_id,
        spoken=spoken,
        replacement=replacement,
        case_sensitive=bool(item.get("case_sensitive", False)),
    )


class DictionaryStore:
    """Thread-safe JSON-backed dictionary with mtime hot-reload."""

    def __init__(self, path: Path | str | None = None) -> None:
        env_path = os.environ.get("PARAKEET_DICTIONARY_PATH", "").strip()
        if path is not None:
            self.path = Path(path).expanduser()
        elif env_path:
            self.path = Path(env_path).expanduser()
        else:
            self.path = DEFAULT_DICTIONARY_PATH

        self._lock = threading.RLock()
        self._entries: list[StoredDictionaryEntry] = []
        self._updated_at: float = 0.0
        self._last_mtime_ns: int = -1
        self._ensure_loaded()

    def _ensure_loaded(self) -> None:
        with self._lock:
            if not self.path.exists():
                if self._last_mtime_ns == -1:
                    self._entries = [
                        StoredDictionaryEntry(
                            id=str(uuid.uuid5(uuid.NAMESPACE_DNS, f"localwhisper.{spoken}")),
                            spoken=spoken,
                            replacement=replacement,
                            case_sensitive=case_sensitive,
                        )
                        for spoken, replacement, case_sensitive in _SEED_ENTRIES
                    ]
                    self._updated_at = time.time()
                    self._save_locked()
                return

            try:
                stat = self.path.stat()
            except OSError:
                return

            if stat.st_mtime_ns == self._last_mtime_ns:
                return

            try:
                raw = json.loads(self.path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                return

            raw_entries = raw.get("entries", []) if isinstance(raw, dict) else (raw if isinstance(raw, list) else [])
            parsed: list[StoredDictionaryEntry] = []
            for item in raw_entries:
                if isinstance(item, dict):
                    entry = _normalize_item(item)
                    if entry is not None:
                        parsed.append(entry)

            self._entries = parsed
            if isinstance(raw, dict) and isinstance(raw.get("updated_at"), (int, float)):
                self._updated_at = float(raw["updated_at"])
            else:
                self._updated_at = stat.st_mtime
            self._last_mtime_ns = stat.st_mtime_ns

    def _save_locked(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "updated_at": round(self._updated_at, 3),
            "entries": [e.to_dict() for e in self._entries],
        }
        tmp_path = self.path.with_suffix(".json.tmp")
        tmp_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        os.replace(tmp_path, self.path)
        try:
            self._last_mtime_ns = self.path.stat().st_mtime_ns
        except OSError:
            self._last_mtime_ns = -1

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            self._ensure_loaded()
            return {
                "entries": [e.to_dict() for e in self._entries],
                "updated_at": round(self._updated_at, 3),
            }

    def replace_all(self, items: Iterable[dict[str, Any]]) -> dict[str, Any]:
        with self._lock:
            self._ensure_loaded()
            next_entries: list[StoredDictionaryEntry] = []
            seen_ids: set[str] = set()
            for item in items:
                entry = _normalize_item(item)
                if entry is None or entry.id in seen_ids:
                    continue
                seen_ids.add(entry.id)
                next_entries.append(entry)
            self._entries = next_entries
            self._updated_at = time.time()
            self._save_locked()
            return self.snapshot()

    def upsert(self, item: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            self._ensure_loaded()
            entry = _normalize_item(item)
            if entry is None:
                raise ValueError("Both 'spoken' and 'replacement' must be non-empty")

            replaced = False
            for idx, existing in enumerate(self._entries):
                if existing.id == entry.id or existing.spoken.lower() == entry.spoken.lower():
                    self._entries[idx] = entry
                    replaced = True
                    break
            if not replaced:
                self._entries.append(entry)

            self._updated_at = time.time()
            self._save_locked()
            return self.snapshot()

    def delete(self, entry_id: str) -> dict[str, Any]:
        with self._lock:
            self._ensure_loaded()
            self._entries = [e for e in self._entries if e.id != entry_id]
            self._updated_at = time.time()
            self._save_locked()
            return self.snapshot()

    def merged_for_postprocess(
        self,
        request_entries: Iterable[DictionaryEntry] | None = None,
    ) -> list[DictionaryEntry]:
        """Return server entries merged with any extra client-supplied entries.

        Server entries take precedence when the same spoken phrase appears in both.
        """
        with self._lock:
            self._ensure_loaded()
            merged: list[DictionaryEntry] = [e.to_postprocess() for e in self._entries]
            seen = {(e.spoken.strip().lower(), e.case_sensitive) for e in merged}

        if request_entries:
            for req_entry in request_entries:
                key = (req_entry.spoken.strip().lower(), req_entry.case_sensitive)
                if key not in seen:
                    seen.add(key)
                    merged.append(req_entry)
        return merged
