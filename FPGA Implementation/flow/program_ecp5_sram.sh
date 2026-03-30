#!/usr/bin/env bash
set -euo pipefail

# Program ECP5 SRAM (volatile) using openFPGALoader.
# Usage:
#   ./flow/program_ecp5_sram.sh build/ecp5_top.bit
# or:
#   BOARD=ulx3s ./flow/program_ecp5_sram.sh build/ecp5_top.bit
#
# If your board is unknown to openFPGALoader, use CABLE=<cable>.
#
BITFILE=${1:-build/ecp5_top.bit}
BOARD=${BOARD:-}
CABLE=${CABLE:-}

if ! command -v openFPGALoader >/dev/null 2>&1; then
  echo "ERROR: openFPGALoader not found."
  exit 1
fi

if [[ ! -f "$BITFILE" ]]; then
  echo "ERROR: bitstream not found: $BITFILE"
  exit 1
fi

if [[ -n "$BOARD" ]]; then
  exec openFPGALoader -b "$BOARD" "$BITFILE"
elif [[ -n "$CABLE" ]]; then
  exec openFPGALoader -c "$CABLE" "$BITFILE"
else
  echo "ERROR: set BOARD=<board> or CABLE=<cable>."
  echo "Example: BOARD=ulx3s ./flow/program_ecp5_sram.sh $BITFILE"
  exit 1
fi
