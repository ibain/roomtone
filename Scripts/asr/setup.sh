#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
python3 -m venv .venv
source .venv/bin/activate
pip install -U pip
pip install -r requirements.txt
echo "ASR sidecar ready. Models download on first transcription."
