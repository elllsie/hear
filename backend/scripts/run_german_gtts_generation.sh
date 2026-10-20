#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h:h}"
cd "$PROJECT_ROOT"

PYTHON="backend/.venv/bin/python"
GENERATOR="backend/scripts/generate_word_audio_replacements.py"

echo "$(date '+%Y-%m-%d %H:%M:%S') German gTTS generation started"
echo "provider=gTTS language=de tld=de slow=false workers=1"

for book in 12yue A1 A2 B1; do
  echo "$(date '+%Y-%m-%d %H:%M:%S') book=$book started"
  "$PYTHON" "$GENERATOR" \
    --provider gtts \
    --word-book "$book" \
    --output-dir backend/generated/learning-audio \
    --workers 1 \
    --delay 0.2 \
    --retries 5 \
    --gtts-tld de
  echo "$(date '+%Y-%m-%d %H:%M:%S') book=$book completed"
done

echo "$(date '+%Y-%m-%d %H:%M:%S') German gTTS generation completed"
