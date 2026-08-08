#!/usr/bin/env bash
# Remote Real-ESRGAN once-shot for macOS/Linux nodes (SSH fanout).
# Mirrors scripts/image_enhance/tt_enhance_once.ps1 CLI flags.
set -euo pipefail

Model="realesr-animevideov3"
Scale=2
Tile=64
Gpu=0
TimeoutSec=300
In=""
Out=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -Model) Model="${2:?}"; shift 2 ;;
    -Scale) Scale="${2:?}"; shift 2 ;;
    -Tile) Tile="${2:?}"; shift 2 ;;
    -Gpu) Gpu="${2:?}"; shift 2 ;;
    -TimeoutSec) TimeoutSec="${2:?}"; shift 2 ;;
    -In) In="${2:?}"; shift 2 ;;
    -Out) Out="${2:?}"; shift 2 ;;
    *)
      echo "UNKNOWN_ARG=$1"
      exit 1
      ;;
  esac
done

ROOT="${HOME}/tools/realesrgan-ncnn-vulkan"
EXE="${ROOT}/realesrgan-ncnn-vulkan"
MODELS="${ROOT}/models"

if [[ -z "${In}" ]]; then
  In="/tmp/tt_enhance_in.jpg"
fi
if [[ -z "${Out}" ]]; then
  Out="/tmp/tt_enhance_out.png"
fi

if [[ ! -x "${EXE}" ]]; then
  echo "MISSING_EXE"
  exit 1
fi
if [[ ! -f "${In}" ]]; then
  echo "MISSING_IN"
  exit 1
fi
rm -f "${Out}"

cd "${ROOT}"
# Polling watchdog avoids a long-lived sleep child that can keep SSH open
# after the enhance process exits (ControlMaster / Open3 hang).
"${EXE}" -i "${In}" -o "${Out}" -n "${Model}" -s "${Scale}" -t "${Tile}" -m "${MODELS}" -g "${Gpu}" -v &
pid=$!
elapsed=0
while kill -0 "${pid}" 2>/dev/null; do
  if [[ "${elapsed}" -ge "${TimeoutSec}" ]]; then
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
    if [[ -f "${Out}" ]]; then
      echo "RESULT=OK_AFTER_TIMEOUT"
      exit 0
    fi
    echo "RESULT=HANG"
    exit 2
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done
set +e
wait "${pid}"
rc=$?
set -e

if [[ ! -f "${Out}" ]]; then
  echo "RESULT=EXIT_${rc}"
  exit 3
fi

echo "RESULT=EXIT_${rc}"
exit 0
