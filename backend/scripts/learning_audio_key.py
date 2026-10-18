#!/usr/bin/env python3
"""Shared Supabase-safe object-key conversion for learning audio."""

from __future__ import annotations

import re
import unicodedata
from pathlib import PurePosixPath


GERMAN_ASCII = str.maketrans({"ä": "ae", "ö": "oe", "ü": "ue", "ß": "ss"})


def safe_component(value: str) -> str:
    normalized = unicodedata.normalize("NFC", value).lower().translate(GERMAN_ASCII)
    normalized = re.sub(r"[^a-z0-9._-]+", "_", normalized)
    normalized = re.sub(r"_+", "_", normalized).strip("_.")
    return normalized or "audio"


def storage_key(relative_path: str) -> str:
    """Return an ASCII-only Storage key while preserving folder structure."""
    path = PurePosixPath(relative_path)
    return "/".join(safe_component(component) for component in path.parts)
