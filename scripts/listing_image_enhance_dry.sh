#!/usr/bin/env bash
# Dry-run listing image enhance pipeline (does NOT attach back to Active Storage).
#
#   analyze → exposure/histogram/WB → darktable develop → adaptive ImageMagick
#   → Real-ESRGAN 2× on bosgame (Windows) → WebP + JPEG + JSON report
#
# Usage:
#   scripts/listing_image_enhance_dry.sh --from-storage
#   BOK_ID=BOK-1056491 scripts/listing_image_enhance_dry.sh --from-storage
#   scripts/listing_image_enhance_dry.sh /path/to/image.jpg
#   SKIP_ESRGAN=1 scripts/listing_image_enhance_dry.sh --from-storage
#   SKIP_DARKTABLE=1 ESRGAN_MODEL=realesr-animevideov3 scripts/listing_image_enhance_dry.sh …
#
# Requires: magick, identify, python3
# Optional: darktable-cli; SSH Host bosgame with Real-ESRGAN installed
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_ROOT="${OUT_DIR:-$ROOT/tmp/image_enhance_dry_$STAMP}"
WORK="$OUT_ROOT/work"
REPORT="$OUT_ROOT/report.json"

MAGICK_BIN="${MAGICK_BIN:-$(command -v magick || true)}"
IDENTIFY_BIN="${IDENTIFY_BIN:-$(command -v identify || true)}"
DT_BIN="${DT_BIN:-$(command -v darktable-cli || true)}"
SSH_HOST="${SSH_HOST:-bosgame}"
ESRGAN_REMOTE_DIR="${ESRGAN_REMOTE_DIR:-%USERPROFILE%/tools/realesrgan-ncnn-vulkan}"
# VRAM-safe on bosgame Radeon iGPU (realesrgan-x4plus OOMs there).
ESRGAN_MODEL="${ESRGAN_MODEL:-realesr-animevideov3}"
ESRGAN_SCALE="${ESRGAN_SCALE:-2}"
ESRGAN_TILE="${ESRGAN_TILE:-64}"
SKIP_ESRGAN="${SKIP_ESRGAN:-0}"
SKIP_DARKTABLE="${SKIP_DARKTABLE:-0}"

export PATH="/usr/bin:${HOME}/.local/share/mise/shims:${HOME}/.local/bin:${PATH}"

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

need python3
[[ -n "$MAGICK_BIN" ]] || die "magick not found"
[[ -n "$IDENTIFY_BIN" ]] || die "identify not found"

resolve_input() {
  local arg="${1:-}"
  PROPERTY_META=""

  if [[ "$arg" == "--from-storage" || -z "$arg" ]]; then
    [[ -x "$ROOT/bin/rails" ]] || die "bin/rails not found for --from-storage"
    eval "$(mise activate bash 2>/dev/null || true)"
    local runner_out meta path
    runner_out="$(
      cd "$ROOT" && BOK_ID="${BOK_ID:-}" bin/rails runner '
bok = ENV["BOK_ID"].presence
scope = Property.joins(:gallery_images_attachments).distinct
scope = scope.where(bok_id: bok) if bok
p = scope.order(updated_at: :desc).first
abort "no hosted gallery property" unless p
img = p.hosted_gallery_images.first || p.gallery_images_attachments.includes(:blob).first
abort "no gallery attachment" unless img
blob = img.blob
path = ActiveStorage::Blob.service.path_for(blob.key)
abort "missing blob file #{path}" unless File.exist?(path)
dst = Rails.root.join("tmp", "enhance_src_#{p.id}_#{blob.id}_#{blob.filename}")
FileUtils.mkdir_p(dst.dirname)
FileUtils.cp(path, dst)
src = PropertyGalleryIngestor.source_urls_for(blob).first
puts "META\t#{p.id}\t#{p.bok_id}\t#{blob.id}\t#{blob.filename}\t#{src}"
puts dst
'
    )"
    PROPERTY_META="$(echo "$runner_out" | awk '/^META\t/{print; exit}')"
    INPUT_PATH="$(echo "$runner_out" | awk '!/^META\t/ && NF{print}' | tail -n1)"
    [[ -f "$INPUT_PATH" ]] || die "could not copy storage blob (got: ${INPUT_PATH:-empty})"
  else
    INPUT_PATH="$arg"
    [[ -f "$INPUT_PATH" ]] || die "input not found: $INPUT_PATH"
  fi
}

analyze_image() {
  local src="$1" json_out="$2"
  "$MAGICK_BIN" "$src" -colorspace sRGB -format '%[fx:mean],%[fx:maxima],%[fx:minima],%[fx:standard_deviation]' info: >"$WORK/stats_global.txt"
  "$MAGICK_BIN" "$src" -colorspace RGB -format '%[fx:mean.r],%[fx:mean.g],%[fx:mean.b]' info: >"$WORK/stats_rgb.txt"
  "$IDENTIFY_BIN" -format '%w %h %m %[colorspace] %b' "$src" >"$WORK/identify.txt"
  "$MAGICK_BIN" "$src" -colorspace Gray -format '%[fx:mean]' info: >"$WORK/hist_mean.txt"

  python3 - "$src" "$json_out" "$WORK/stats_global.txt" "$WORK/stats_rgb.txt" "$WORK/identify.txt" "$WORK/hist_mean.txt" <<'PY'
import json, sys
src, out, gpath, rgbpath, idpath, hpath = sys.argv[1:7]
mean, maxima, minima, stddev = open(gpath).read().strip().split(",")
r, g, b = open(rgbpath).read().strip().split(",")
ident = open(idpath).read().strip().split()
w, h, fmt = int(ident[0]), int(ident[1]), ident[2]
hist_mean = float(open(hpath).read().strip() or "0.5")
mean_f, r_f, g_f, b_f = float(mean), float(r), float(g), float(b)
target = 0.48
exposure_ev = max(-1.25, min(1.25, (target - mean_f) * 2.4))
eps = 1e-6
ref = max(g_f, eps)
wb_r = max(0.85, min(1.18, ref / max(r_f, eps)))
wb_b = max(0.85, min(1.18, ref / max(b_f, eps)))
contrast = 1.0
if float(stddev) < 0.12:
    contrast = 1.12
elif float(stddev) > 0.28:
    contrast = 0.94
sharpen = 0.55 if float(stddev) < 0.18 else 0.35
notes = []
if mean_f < 0.35:
    notes.append("underexposed")
elif mean_f > 0.62:
    notes.append("bright")
if abs(wb_r - 1) > 0.04 or abs(wb_b - 1) > 0.04:
    notes.append("wb_cast")
decision = {
    "source": src,
    "width": w,
    "height": h,
    "format": fmt,
    "mean": mean_f,
    "min": float(minima),
    "max": float(maxima),
    "stddev": float(stddev),
    "hist_luma_mean": hist_mean,
    "rgb_mean": {"r": r_f, "g": g_f, "b": b_f},
    "exposure_ev": round(exposure_ev, 3),
    "wb_gains": {"r": round(wb_r, 4), "g": 1.0, "b": round(wb_b, 4)},
    "contrast": round(contrast, 3),
    "sharpen_radius": round(sharpen, 3),
    "notes": notes,
}
json.dump(decision, open(out, "w"), indent=2)
print(json.dumps(decision, indent=2))
PY
}

run_darktable() {
  local src="$1" dst="$2"
  if [[ "$SKIP_DARKTABLE" == "1" ]]; then
    log "darktable skipped (SKIP_DARKTABLE=1)"
    cp -f "$src" "$dst"
    echo skipped >"$WORK/darktable_status.txt"
    return 0
  fi
  if [[ -z "$DT_BIN" ]]; then
    log "darktable-cli missing — copy through"
    cp -f "$src" "$dst"
    echo missing >"$WORK/darktable_status.txt"
    return 0
  fi

  # Real style ships in-repo; darktable-cli resolves --style from data.db (not the file alone).
  local style_args=()
  local shipped="$ROOT/scripts/image_enhance/styles/tt_realty_listing.dtstyle"
  local installer="$ROOT/scripts/image_enhance/install_style.py"
  if [[ -f "$shipped" ]] && rg -q '<plugin>' "$shipped"; then
    if [[ -f "$installer" ]]; then
      python3 "$installer" --style "$shipped" >"$WORK/style_install.log" 2>&1 \
        || log "style install warning (see style_install.log)"
    else
      mkdir -p "${HOME}/.config/darktable/styles"
      cp -f "$shipped" "${HOME}/.config/darktable/styles/tt_realty_listing.dtstyle"
    fi
    style_args=(--style tt_realty_listing --style-overwrite)
  fi

  set +e
  "$DT_BIN" "$src" "$dst" "${style_args[@]}" --hq true >"$WORK/darktable.log" 2>&1
  local rc=$?
  set -e
  if [[ $rc -ne 0 || ! -s "$dst" ]]; then
    log "darktable style/develop failed (rc=$rc) — retry without style"
    rm -f "$dst"
    set +e
    "$DT_BIN" "$src" "$dst" --hq true >"$WORK/darktable_fallback.log" 2>&1
    rc=$?
    set -e
  fi
  if [[ ! -s "$dst" ]]; then
    log "darktable produced no file — copy through"
    cp -f "$src" "$dst"
    echo fallback_copy >"$WORK/darktable_status.txt"
  else
    echo ok >"$WORK/darktable_status.txt"
  fi
}

run_imagemagick_adaptive() {
  local src="$1" dst="$2" analysis="$3"
  python3 - "$src" "$dst" "$analysis" "$MAGICK_BIN" <<'PY'
import json, subprocess, sys
src, dst, analysis, magick = sys.argv[1:5]
a = json.load(open(analysis))
ev = float(a["exposure_ev"])
brightness = max(-18.0, min(18.0, ev * 10.0))
contrast = int(round((float(a["contrast"]) - 1.0) * 100))
wb = a["wb_gains"]
sharpen = float(a["sharpen_radius"])
sig = 2.2 + (0.8 if "underexposed" in a["notes"] else 0.0)
cmd = [
    magick, src,
    "-colorspace", "sRGB",
    "-channel", "R", "-evaluate", "multiply", str(wb["r"]),
    "-channel", "B", "-evaluate", "multiply", str(wb["b"]),
    "+channel",
    "-brightness-contrast", f"{brightness:+.1f}x{contrast:+d}",
    "-sigmoidal-contrast", f"{sig:.1f}x50%",
    "-unsharp", f"0x{sharpen}+0.65+0.02",
    "-quality", "92",
    dst,
]
subprocess.check_call(cmd)
print(" ".join(cmd))
PY
}

run_esrgan_bosgame() {
  local src="$1" dst="$2"
  if [[ "$SKIP_ESRGAN" == "1" ]]; then
    log "ESRGAN skipped"
    cp -f "$src" "$dst"
    echo skipped >"$WORK/esrgan_status.txt"
    return 0
  fi
  if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$SSH_HOST" "echo ok" >/dev/null 2>&1; then
    log "SSH $SSH_HOST unavailable — skip ESRGAN"
    cp -f "$src" "$dst"
    echo ssh_unavailable >"$WORK/esrgan_status.txt"
    return 0
  fi

  local job_id="dry_${SSH_HOST}_g${ESRGAN_GPU:-0}_$$_$(date +%s)"
  local remote_in="tt_enhance_in_${job_id}.jpg"
  local remote_out="tt_enhance_out_${job_id}.png"
  scp -q -o BatchMode=yes -o ConnectTimeout=8 "$src" \
    "${SSH_HOST}:AppData/Local/Temp/${remote_in}"
  scp -q -o BatchMode=yes -o ConnectTimeout=8 "$ROOT/scripts/image_enhance/tt_enhance_once.ps1" \
    "${SSH_HOST}:tools/realesrgan-ncnn-vulkan/tt_enhance_once.ps1"

  set +e
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$SSH_HOST" \
    "powershell -NoProfile -ExecutionPolicy Bypass -File %USERPROFILE%\\tools\\realesrgan-ncnn-vulkan\\tt_enhance_once.ps1 -Model ${ESRGAN_MODEL} -Scale ${ESRGAN_SCALE} -Tile ${ESRGAN_TILE} -Gpu ${ESRGAN_GPU:-0} -In %TEMP%\\${remote_in} -Out %TEMP%\\${remote_out}" \
    | tee "$WORK/esrgan_remote.log"
  local rc=${PIPESTATUS[0]}
  set -e

  set +e
  scp -q -o BatchMode=yes -o ConnectTimeout=8 \
    "${SSH_HOST}:AppData/Local/Temp/${remote_out}" "$dst"
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_HOST" \
    "del /q %TEMP%\\${remote_in} %TEMP%\\${remote_out} 2>nul" >/dev/null 2>&1 || true
  set -e

  if [[ -s "$dst" ]]; then
    echo ok >"$WORK/esrgan_status.txt"
  else
    log "ESRGAN remote failed (rc=${rc:-?}) — copy through"
    cp -f "$src" "$dst"
    echo failed >"$WORK/esrgan_status.txt"
  fi
}

encode_outputs() {
  local src="$1"
  "$MAGICK_BIN" "$src" -colorspace sRGB -strip -quality 88 "$OUT_ROOT/enhanced.jpg"
  "$MAGICK_BIN" "$src" -colorspace sRGB -strip -quality 82 "$OUT_ROOT/enhanced.webp"
}

write_report() {
  export PROPERTY_META="${PROPERTY_META:-}"
  export ESRGAN_MODEL ESRGAN_SCALE
  python3 - "$REPORT" "$OUT_ROOT" <<'PY'
import json, os, sys, time
report_path, out_root = sys.argv[1:3]
work = os.path.join(out_root, "work")
analysis = json.load(open(os.path.join(work, "analysis.json")))
def read(p, default=""):
    try:
        return open(p).read().strip()
    except FileNotFoundError:
        return default
meta = os.environ.get("PROPERTY_META", "")
property_info = None
if meta.startswith("META\t"):
    parts = meta.split("\t")
    if len(parts) >= 6:
        property_info = {
            "id": parts[1],
            "bok_id": parts[2],
            "blob_id": parts[3],
            "filename": parts[4],
            "source_url": parts[5],
        }
report = {
    "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "dry_run": True,
    "note": "Does not write back to Active Storage / listings.",
    "out_dir": out_root,
    "property": property_info,
    "pipeline": [
        "analyze_exposure_histogram_wb",
        "darktable_develop",
        "adaptive_imagemagick",
        "realesrgan_2x_bosgame",
        "encode_webp_jpeg",
    ],
    "analysis": analysis,
    "darktable_status": read(os.path.join(work, "darktable_status.txt"), "unknown"),
    "esrgan_status": read(os.path.join(work, "esrgan_status.txt"), "unknown"),
    "esrgan_model": os.environ.get("ESRGAN_MODEL"),
    "esrgan_scale": os.environ.get("ESRGAN_SCALE"),
    "outputs": {
        "jpeg": os.path.join(out_root, "enhanced.jpg"),
        "webp": os.path.join(out_root, "enhanced.webp"),
        "report": report_path,
    },
}
json.dump(report, open(report_path, "w"), indent=2)
print(json.dumps(report, indent=2))
PY
}

main() {
  local arg="${1:---from-storage}"
  resolve_input "$arg"
  mkdir -p "$WORK"
  log "OUT_DIR=$OUT_ROOT"
  log "INPUT=$INPUT_PATH"
  [[ -n "$PROPERTY_META" ]] && log "$PROPERTY_META"

  "$MAGICK_BIN" "$INPUT_PATH" -colorspace sRGB -quality 95 "$WORK/00_src.jpg"

  log "1/5 analyze (exposure / histogram / WB)"
  analyze_image "$WORK/00_src.jpg" "$WORK/analysis.json" | sed 's/^/  /'

  log "2/5 darktable develop / style"
  run_darktable "$WORK/00_src.jpg" "$WORK/01_darktable.jpg"

  log "3/5 adaptive ImageMagick"
  run_imagemagick_adaptive "$WORK/01_darktable.jpg" "$WORK/02_imagemagick.jpg" "$WORK/analysis.json" | sed 's/^/  /'

  log "4/5 Real-ESRGAN ${ESRGAN_SCALE}× via ${SSH_HOST} (${ESRGAN_MODEL}, tile=${ESRGAN_TILE})"
  # Cap long edge before ESRGAN so bosgame iGPU finishes within timeout on dry runs.
  "$MAGICK_BIN" "$WORK/02_imagemagick.jpg" -resize "${ESRGAN_MAX_EDGE:-1280}x${ESRGAN_MAX_EDGE:-1280}>" -quality 92 "$WORK/02b_esrgan_in.jpg"
  run_esrgan_bosgame "$WORK/02b_esrgan_in.jpg" "$WORK/03_esrgan.png"

  log "5/5 encode WebP + JPEG"
  encode_outputs "$WORK/03_esrgan.png"
  write_report >/dev/null

  log "done"
  echo
  echo "Report: $REPORT"
  echo "JPEG:   $OUT_ROOT/enhanced.jpg"
  echo "WebP:   $OUT_ROOT/enhanced.webp"
  echo
  "$IDENTIFY_BIN" "$WORK/00_src.jpg" "$OUT_ROOT/enhanced.jpg"
}

main "${1:---from-storage}"
