#!/usr/bin/env bash
set -euo pipefail

# Optional helper to generate an ECP5 PLL wrapper with Project Trellis `ecppll`.
#
# Example:
#   ./flow/gen_pll_ecp5.sh 25 50
# (input 25 MHz -> output 50 MHz)
#
IN_MHZ=${1:-25}
OUT_MHZ=${2:-50}
OUTDIR=${OUTDIR:-rtl/soc}

if ! command -v ecppll >/dev/null 2>&1; then
  echo "ERROR: ecppll not found (comes with Project Trellis tools)."
  exit 1
fi

mkdir -p "$OUTDIR"
ecppll -i "$IN_MHZ" -o "$OUT_MHZ" -f "$OUTDIR/ecp5_pll.v"
echo "Generated: $OUTDIR/ecp5_pll.v"
