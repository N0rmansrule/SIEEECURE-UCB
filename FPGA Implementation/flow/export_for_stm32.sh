#!/usr/bin/env bash
set -euo pipefail

# Export an ECP5 bitstream for use by an STM32-based board controller.
#
# This script assumes you already built a .bit using the OSS flow:
#   ./flow/build_ecp5_oss.sh
#
# It will:
#   1) copy the .bit into stm32/bitstream/
#   2) optionally generate a C header with a byte array (for embedding)
#
# Usage:
#   ./flow/export_for_stm32.sh build/soc_top.bit
#   EMBED=1 ./flow/export_for_stm32.sh build/soc_top.bit
#
BITFILE=${1:-build/soc_top.bit}
OUTDIR=stm32/bitstream
EMBED=${EMBED:-0}

if [[ ! -f "$BITFILE" ]]; then
  echo "ERROR: bitstream not found: $BITFILE" >&2
  exit 1
fi

mkdir -p "$OUTDIR"
cp -f "$BITFILE" "$OUTDIR/ecp5_image.bit"
echo "Copied -> $OUTDIR/ecp5_image.bit"

if [[ "$EMBED" == "1" ]]; then
  python3 tools/bin2carray.py "$OUTDIR/ecp5_image.bit" "$OUTDIR/ecp5_bitstream.h" ecp5_bitstream
  echo "Generated -> $OUTDIR/ecp5_bitstream.h"
else
  echo "Tip: set EMBED=1 to also generate a C header for embedding."
fi
