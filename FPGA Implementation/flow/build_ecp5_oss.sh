#!/usr/bin/env bash
set -euo pipefail

# Open-source ECP5 build script.
#
# Target defaults:
#   - Device:  LFE5U-85F (ECP5-85K)   -> nextpnr flag: --85k
#   - Package: CABGA381
#   - Speed:   6
#
# Requires:
#   - yosys
#   - nextpnr-ecp5
#   - ecppack (Project Trellis)
#
# Optional:
#   - openFPGALoader (programming)
#
# Usage:
#   ./flow/build_ecp5_oss.sh
#   TOP=ecp5_top LPF=constraints/ecp5_bg381_minimal.lpf ./flow/build_ecp5_oss.sh
#
TOP=${TOP:-soc_top}
DEVICE_FLAG=${DEVICE_FLAG:---85k}
PACKAGE=${PACKAGE:-CABGA381}
SPEED=${SPEED:-6}
LPF=${LPF:-constraints/ecp5_bg381_template.lpf}

BUILD_DIR=build
mkdir -p "${BUILD_DIR}"

# Some tools are order-sensitive for SystemVerilog packages/interfaces.
PRE_SRCS=(
  rtl/core/rv64_pkg.sv
  rtl/se/se_pkg.sv
  rtl/gpu/gpu_pkg.sv
  rtl/bus/simple_mem_if.sv
)

# Collect RTL sources (sorted), excluding PRE_SRCS to avoid double-reads.
ALL_SRCS=$(find rtl -name '*.sv' | sort)
RTL_SRCS=""
while IFS= read -r f; do
  skip=0
  for p in "${PRE_SRCS[@]}"; do
    if [[ "$f" == "$p" ]]; then
      skip=1
    fi
  done
  if [[ $skip -eq 0 ]]; then
    RTL_SRCS+="$f "
  fi
done <<< "$ALL_SRCS"

PRE_ONE="${PRE_SRCS[*]}"

echo "[1/3] Synthesis (yosys)"
yosys -p "read_verilog -sv -D SYNTHESIS ${PRE_ONE} ${RTL_SRCS}; synth_ecp5 -top ${TOP} -abc9 -json ${BUILD_DIR}/${TOP}.json"

echo "[2/3] Place & Route (nextpnr-ecp5)"
nextpnr-ecp5 ${DEVICE_FLAG} --package ${PACKAGE} --speed ${SPEED}       --json ${BUILD_DIR}/${TOP}.json       --lpf ${LPF}       --textcfg ${BUILD_DIR}/${TOP}.config       --report ${BUILD_DIR}/${TOP}_report.json

echo "[3/3] Bitstream pack (ecppack)"
ecppack ${BUILD_DIR}/${TOP}.config ${BUILD_DIR}/${TOP}.bit

echo "Done: ${BUILD_DIR}/${TOP}.bit"
echo ""
echo "To program SRAM (example):"
echo "  BOARD=<your_board> ./flow/program_ecp5_sram.sh ${BUILD_DIR}/${TOP}.bit"
echo "To program SPI flash (example):"
echo "  BOARD=<your_board> ./flow/program_ecp5_flash.sh ${BUILD_DIR}/${TOP}.bit"
