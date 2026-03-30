#!/usr/bin/env bash
set -euo pipefail

# Program ECP5 SPI flash (non-volatile) using openFPGALoader.
# Usage:
#   BOARD=ulx3s ./flow/program_ecp5_flash.sh build/ecp5_top.bit
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
  exec openFPGALoader -b "$BOARD" -f "$BITFILE"
elif [[ -n "$CABLE" ]]; then
  exec openFPGALoader -c "$CABLE" -f "$BITFILE"
else
  echo "ERROR: set BOARD=<board> or CABLE=<cable>."
  echo "Example: BOARD=ulx3s ./flow/program_ecp5_flash.sh $BITFILE"
  exit 1
fi
