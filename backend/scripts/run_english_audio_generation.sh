#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h:h}"
cd "$PROJECT_ROOT"

PYTHON="backend/.local/kokoro-venv/bin/python"
GENERATOR="backend/scripts/generate_kokoro_word_audio.py"

echo "$(date '+%Y-%m-%d %H:%M:%S') English generation started"

# Resume KaoYan without replacing completed files.
LOGURU_LEVEL=WARNING "$PYTHON" "$GENERATOR" \
  --book KaoYan_2 \
  --progress-every 100

# Regenerate IELTS consistently; its first ten files came from an earlier test.
LOGURU_LEVEL=WARNING "$PYTHON" "$GENERATOR" \
  --book IELTS_9400 \
  --overwrite \
  --progress-every 100

echo "$(date '+%Y-%m-%d %H:%M:%S') English generation completed"
