#!/usr/bin/env python3
"""bin2bytehex.py
Convert a raw binary file into a $readmemh-friendly hex text file.

- Input:  firmware.bin  (raw bytes)
- Output: program.hex   (one byte per line, 2 hex chars)

Usage:
  python3 tools/bin2bytehex.py firmware.bin program.hex
"""

import sys
from pathlib import Path

def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: bin2bytehex.py <input.bin> <output.hex>")
        return 2

    in_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2])

    data = in_path.read_bytes()
    with out_path.open("w") as f:
        for b in data:
            f.write(f"{b:02x}\n")
    print(f"Wrote {len(data)} bytes -> {out_path}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
