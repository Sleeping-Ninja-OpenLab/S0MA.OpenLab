#!/usr/bin/env bash
set -euo pipefail

VENDOR_ROOT="/mnt/d/Sauce/S0MA/CAD/Vendor/goBILDA"
FREECAD_ROOT="/mnt/d/Sauce/S0MA/CAD/goBILDA"
LOG_FILE="${VENDOR_ROOT}/gobilda-convert-FCStd-errors.log"

FREECAD_CMD="/mnt/c/Program Files/FreeCAD 1.1/bin/freecadcmd.exe"

if [[ ! -f "$FREECAD_CMD" ]]; then
    echo "FreeCADCmd not found: $FREECAD_CMD"
    exit 1
fi

mkdir -p "$FREECAD_ROOT"

# Clean log every run.
cat > "$LOG_FILE" <<'EOF'
source_step	output_fcstd	error
EOF

TMP_DIR="$(mktemp -d)"
SAFE_TMP_DIR="${FREECAD_ROOT}/.convert-tmp"

mkdir -p "$SAFE_TMP_DIR"

cleanup() {
    rm -rf "$TMP_DIR"
    rm -rf "$SAFE_TMP_DIR"
}

trap cleanup EXIT

PY_SCRIPT="${TMP_DIR}/convert-step.py"

cat > "$PY_SCRIPT" <<'PY'
import sys
from pathlib import Path

import FreeCAD as App
import Import


def fail(message):
    print(f"ERROR:{message}")
    sys.exit(1)


if len(sys.argv) < 3:
    fail(f"unexpected argv: {sys.argv!r}")

src = Path(sys.argv[-2])
dst = Path(sys.argv[-1])

if not src.exists():
    fail(f"source does not exist: {src}")

dst.parent.mkdir(parents=True, exist_ok=True)

doc_name = "goBILDA_Import"
doc = None

try:
    doc = App.newDocument(doc_name)

    Import.insert(str(src), doc.Name)
    doc.recompute()

    if len(doc.Objects) == 0:
        fail("STEP import produced zero document objects")

    doc.saveAs(str(dst))

    if not dst.exists():
        fail("FCStd file was not created")

    if dst.stat().st_size == 0:
        fail("FCStd file is zero bytes")

    print(f"OK:{len(doc.Objects)}")

finally:
    try:
        if doc is not None:
            App.closeDocument(doc.Name)
    except Exception:
        pass
PY

echo "SOMA goBILDA FreeCAD converter"
echo "Vendor:   $VENDOR_ROOT"
echo "FreeCAD:  $FREECAD_ROOT"
echo "Command:  $FREECAD_CMD"
echo "Log:      $LOG_FILE"
echo

count_steps() {
    find "$VENDOR_ROOT" -type f \( -iname '*.step' -o -iname '*.stp' \) -print0 | \
        awk -v RS='\0' 'END { print NR }'
}

TOTAL="$(count_steps)"

converted=0
skipped=0
failed=0
deferred=0
processed=0

draw_bar() {
    local current="$1"
    local total="$2"
    local width=50

    if (( total <= 0 )); then
        printf '\r[%-*s] 0/0 100%%' "$width" ""
        return
    fi

    local percent=$(( current * 100 / total ))
    local filled=$(( current * width / total ))
    local empty=$(( width - filled ))

    printf '\r['
    printf '%*s' "$filled" '' | tr ' ' '#'
    printf '%*s' "$empty" '' | tr ' ' '-'
    printf '] %d/%d %3d%%' "$current" "$total" "$percent"
}

echo "STEP files currently visible: $TOTAL"
echo "Safe to run while gobilda-sync.sh is still downloading."
echo

while IFS= read -r -d '' step_file; do
    ((processed+=1))

    rel="${step_file#"$VENDOR_ROOT"/}"
    rel_dir="$(dirname "$rel")"

    filename="$(basename "$step_file")"
    stem="${filename%.*}"

    target_dir="$FREECAD_ROOT/$rel_dir"
    target_file="$target_dir/$stem.FCStd"

    # Matching FCStd already exists and is non-zero.
    if [[ -s "$target_file" ]]; then
        ((skipped+=1))
        draw_bar "$processed" "$TOTAL"
        continue
    fi

    mkdir -p "$target_dir"

    # Avoid touching a STEP that the crawler may still be writing.
    size1="$(stat -c '%s' "$step_file" 2>/dev/null || echo 0)"
    sleep 1
    size2="$(stat -c '%s' "$step_file" 2>/dev/null || echo 0)"

    if [[ "$size1" -eq 0 || "$size1" -ne "$size2" ]]; then
        ((deferred+=1))
        draw_bar "$processed" "$TOTAL"
        continue
    fi

    # FreeCADCmd on Windows can be awkward with Unicode/special characters
    # in command-line paths, so use boring ASCII temp filenames.
    safe_input="${SAFE_TMP_DIR}/input-${processed}.step"
    safe_output="${SAFE_TMP_DIR}/output-${processed}.FCStd"

    rm -f "$safe_input" "$safe_output"

    cp "$step_file" "$safe_input"

    step_win="$(wslpath -w "$safe_input")"
    target_win="$(wslpath -w "$safe_output")"
    py_win="$(wslpath -w "$PY_SCRIPT")"

    output="$(
        "$FREECAD_CMD" "$py_win" --pass \
            "$step_win" \
            "$target_win" \
            </dev/null \
            2>&1
    )" || true

    if grep -q '^OK:' <<< "$output" && [[ -s "$safe_output" ]]; then
        mv "$safe_output" "$target_file"
        rm -f "$safe_input"
        ((converted+=1))
    else
        ((failed+=1))

        printf '%s\t%s\t%s\n' \
            "$step_file" \
            "$target_file" \
            "$(tr '\r\n\t' '   ' <<< "$output")" \
            >> "$LOG_FILE"

        rm -f "$safe_input" "$safe_output"
    fi

    draw_bar "$processed" "$TOTAL"

done < <(
    find "$VENDOR_ROOT" -type f \( -iname '*.step' -o -iname '*.stp' \) -print0 | sort -z
)

echo
echo
echo "Pass complete"
echo "-------------"
echo "STEP files seen:      $TOTAL"
echo "Already converted:    $skipped"
echo "Converted this pass:  $converted"
echo "Deferred/still busy:  $deferred"
echo "Failures:             $failed"
echo

FCSTD_TOTAL="$(
    find "$FREECAD_ROOT" -type f -iname '*.FCStd' -print0 | \
        awk -v RS='\0' 'END { print NR }'
)"

echo "FCStd files total:    $FCSTD_TOTAL"

if (( failed > 0 )); then
    echo "Errors:               $LOG_FILE"
fi