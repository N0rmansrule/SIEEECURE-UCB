#!/usr/bin/env bash
set -euo pipefail

# Convert an ELF to program.hex (byte-per-line hex) for simple_ram.
#
# Usage:
#   RISCV_PREFIX=riscv64-unknown-elf ./tools/elf2hex.sh firmware/demo.elf program.hex
#
ELF=${1:-}
OUT=${2:-program.hex}
RISCV_PREFIX=${RISCV_PREFIX:-riscv64-unknown-elf}

if [[ -z "$ELF" ]]; then
  echo "Usage: $0 <in.elf> [out.hex]"
  exit 1
fi

OBJCOPY=${RISCV_PREFIX}-objcopy

if ! command -v "$OBJCOPY" >/dev/null 2>&1; then
  echo "ERROR: cannot find $OBJCOPY. Set RISCV_PREFIX to your toolchain prefix."
  exit 1
fi

TMPBIN=$(mktemp /tmp/fw.XXXXXX.bin)
"$OBJCOPY" -O binary "$ELF" "$TMPBIN"
python3 tools/bin2bytehex.py "$TMPBIN" "$OUT"
rm -f "$TMPBIN"

echo "Wrote: $OUT"
