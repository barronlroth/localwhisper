"""Wispr Flow–style deterministic transcript cleanup, personal dictionary, and context spacing."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Iterable


@dataclass(frozen=True)
class DictionaryEntry:
    spoken: str
    replacement: str
    case_sensitive: bool = False


# Hesitation fillers that should be stripped in "clean" / "notes" modes.
_FILLER_WORDS = r"(?:um+|uh+|uhm+|erm+|hmm+|mm-?hmm)"

# Leading filler at start of sentence: "Um, let's go" -> "Let's go"
_LEADING_FILLER_RE = re.compile(
    rf"(^|[.!?]\s+|\n){_FILLER_WORDS}(?:[,\s]+|$)",
    flags=re.IGNORECASE,
)

# Mid-sentence filler: "I was, uh, thinking" -> "I was thinking"
_MID_FILLER_RE = re.compile(
    rf"(?:,\s*)?\b{_FILLER_WORDS}\b(?:,\s*|\s+)",
    flags=re.IGNORECASE,
)

# Immediate single-word stutter: "I I think" -> "I think"
_STUTTER_RE = re.compile(r"\b([A-Za-z']+)\s+\1\b", flags=re.IGNORECASE)
_ALLOWED_DOUBLES = {"had", "that", "is", "was", "do", "can", "will", "very", "really", "so"}

# Spoken line/paragraph breaks
_NEW_PARAGRAPH_RE = re.compile(r"\s*[,.]?\s*\bnew paragraph\b[.,]?\s*", flags=re.IGNORECASE)
_NEW_LINE_RE = re.compile(r"\s*[,.]?\s*\bnew line\b[.,]?\s*", flags=re.IGNORECASE)

# Punctuation & spacing cleanup
_SPACE_BEFORE_PUNCT_RE = re.compile(r"[ \t]+([,.;:!?])")
_DUP_COMMA_RE = re.compile(r",\s*,+")
_MULTI_SPACE_RE = re.compile(r"[ \t]{2,}")
_SENTENCE_START_RE = re.compile(r"(^|[.!?]\s+|\n)([a-z])")

_KEEP_CAPS_FIRST = {"I", "I'm", "I've", "I'll", "I'd"}


def _apply_dictionary(text: str, entries: Iterable[DictionaryEntry]) -> tuple[str, set[str]]:
    """Apply personal dictionary replacements longest-phrase-first.

    Returns (updated_text, protected_leading_words) so context-lowercasing won't undo
    explicitly cased dictionary replacements like "Tailscale" or "Parakeet".
    """
    sorted_entries = sorted(
        (e for e in entries if e.spoken.strip()),
        key=lambda e: len(e.spoken.strip()),
        reverse=True,
    )
    protected: set[str] = set()
    result = text

    for entry in sorted_entries:
        spoken = entry.spoken.strip()
        replacement = entry.replacement
        flags = 0 if entry.case_sensitive else re.IGNORECASE

        # Use word boundaries when the spoken phrase starts/ends with word chars.
        prefix = r"\b" if re.match(r"^\w", spoken) else ""
        suffix = r"\b" if re.search(r"\w$", spoken) else ""
        pattern = re.compile(f"{prefix}{re.escape(spoken)}{suffix}", flags=flags)

        if pattern.search(result):
            result = pattern.sub(lambda _: replacement, result)
            first_token = replacement.strip().split(" ", 1)[0]
            if first_token and any(c.isupper() for c in first_token):
                protected.add(first_token)

    return result, protected


def _remove_fillers(text: str) -> str:
    out = text
    # Strip leading fillers repeatedly ("Um, uh, so...")
    for _ in range(4):
        nxt = _LEADING_FILLER_RE.sub(r"\1", out)
        if nxt == out:
            break
        out = nxt
    out = _MID_FILLER_RE.sub(" ", out)
    out = _DUP_COMMA_RE.sub(",", out)
    out = _SPACE_BEFORE_PUNCT_RE.sub(r"\1", out)
    out = _MULTI_SPACE_RE.sub(" ", out).strip()
    # Fix stray leading comma/punctuation left after stripping a leading filler
    out = re.sub(r"^[,;:\s]+", "", out)
    return out


def _collapse_stutters(text: str) -> str:
    def _replace(match: re.Match[str]) -> str:
        word = match.group(1)
        if word.lower() in _ALLOWED_DOUBLES:
            return match.group(0)
        return word

    return _STUTTER_RE.sub(_replace, text)


def _format_notes(text: str) -> str:
    """Convert spoken 'bullet ...' / 'next bullet ...' into clean markdown dashes."""
    out = re.sub(r"\s*(?:next\s+)?bullet(?:\s+point)?\s*[:,-]?\s*", "\n- ", text, flags=re.IGNORECASE)
    out = out.strip()
    if out.startswith("- "):
        lines = [line.strip() for line in out.splitlines() if line.strip()]
        out = "\n".join(
            f"- {line[2:][0].upper() + line[2:][1:]}" if line.startswith("- ") and len(line) > 2 else line
            for line in lines
        )
    return out


def _apply_context_awareness(
    text: str,
    context_before: str | None,
    protected_words: set[str],
    smart_spacing: bool = True,
) -> str:
    if not text or not context_before:
        return text

    ctx = context_before
    trimmed_ctx = ctx.rstrip(" \t")

    # Determine if cursor is mid-sentence (preceded by non-terminal text)
    if trimmed_ctx:
        last_non_space = trimmed_ctx[-1]
        is_mid_sentence = last_non_space not in ".!?\n\r([{—–"
    else:
        is_mid_sentence = False

    out = text

    # If mid-sentence, lowercase a standard sentence-initial word unless it's protected/acronym/I
    if is_mid_sentence and out:
        m = re.match(r"^([A-Za-z']+)(.*)", out, flags=re.DOTALL)
        if m:
            first_word, rest = m.group(1), m.group(2)
            is_acronym = len(first_word) >= 2 and first_word.isupper()
            is_camel_brand = any(c.isupper() for c in first_word[1:])
            if (
                first_word not in _KEEP_CAPS_FIRST
                and first_word not in protected_words
                and not is_acronym
                and not is_camel_brand
                and first_word[0].isupper()
            ):
                out = first_word[0].lower() + first_word[1:] + rest

    # Smart leading space if cursor is right against an existing word/punctuation
    if smart_spacing and ctx and not ctx[-1].isspace() and ctx[-1] not in "([{\"'\u201c\u2018/":
        if not out[0].isspace() and out[0] not in ".,!?;:)]}\"'":
            out = " " + out

    return out


def clean_transcript(
    raw_text: str,
    *,
    mode: str = "clean",
    dictionary: Iterable[DictionaryEntry] | None = None,
    context_before: str | None = None,
    smart_spacing: bool = True,
) -> str:
    """Clean and format a raw Parakeet transcription for direct insertion into iOS text fields."""
    text = (raw_text or "").strip()
    if not text:
        return ""

    normalized_mode = (mode or "clean").lower().strip()
    protected_words: set[str] = set()

    if normalized_mode != "raw":
        text = _NEW_PARAGRAPH_RE.sub("\n\n", text)
        text = _NEW_LINE_RE.sub("\n", text)
        text = _remove_fillers(text)
        text = _collapse_stutters(text)
        if normalized_mode == "notes":
            text = _format_notes(text)
        # Re-capitalize sentence starts after filler removal
        text = _SENTENCE_START_RE.sub(lambda m: m.group(1) + m.group(2).upper(), text)

    if dictionary:
        text, protected_words = _apply_dictionary(text, dictionary)

    text = _SPACE_BEFORE_PUNCT_RE.sub(r"\1", text)
    text = _MULTI_SPACE_RE.sub(" ", text)
    # Preserve intentional newlines while trimming outer horizontal whitespace
    text = "\n".join(line.strip() for line in text.splitlines()).strip()

    if normalized_mode != "raw" or smart_spacing:
        text = _apply_context_awareness(
            text,
            context_before=context_before,
            protected_words=protected_words,
            smart_spacing=smart_spacing,
        )

    return text
