#!/usr/bin/env bash
set -euo pipefail

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: missing tool: $1"
    exit 1
  fi
}

echo "Checking required tools for ECP5 open-source flow..."
need yosys
need nextpnr-ecp5
need ecppack
echo "OK: yosys, nextpnr-ecp5, ecppack found."

echo ""
echo "Optional but recommended:"
if command -v openFPGALoader >/dev/null 2>&1; then
  echo "OK: openFPGALoader found."
else
  echo "WARN: openFPGALoader not found (needed to program via JTAG)."
fi

if command -v ecppll >/dev/null 2>&1; then
  echo "OK: ecppll found (optional PLL helper)."
else
  echo "INFO: ecppll not found (PLL generation optional)."
fi

echo ""
echo "Done."
