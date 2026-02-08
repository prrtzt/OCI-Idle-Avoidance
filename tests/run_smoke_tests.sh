#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT_DIR"

bash -n scripts/load_controller.sh
python3 -m py_compile scripts/load_generator.py
python3 -m unittest discover -s tests -p 'test_*.py'
