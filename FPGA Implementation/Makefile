# Simple simulation makefile (requires a SystemVerilog simulator).
#
# Examples:
#   make sim TB=tb/tb_soc.sv
#   ./simv +MEMHEX=program.hex
#
#   make sim TB=tb/tb_alu.sv
#   ./simv
#
# Example with iverilog:
#   make sim IVERILOG=iverilog VVP=vvp TB=tb/tb_soc.sv
#
# Example with verilator (not provided here):
#   use your own verilator invocation.

IVERILOG ?= iverilog
VVP      ?= vvp

RTL_DIRS = rtl/bus rtl/cache rtl/core rtl/fpu rtl/mem rtl/se rtl/soc rtl/util rtl/bp rtl/gpu

# Compile-order sensitive packages/interfaces first (iverilog can be picky)
PRE_SV = rtl/core/rv64_pkg.sv rtl/se/se_pkg.sv rtl/gpu/gpu_pkg.sv rtl/bus/simple_mem_if.sv
ALL_SV = $(shell find $(RTL_DIRS) -name '*.sv')
VSRCS = $(PRE_SV) $(filter-out $(PRE_SV),$(ALL_SV))

RTL_SRCS = $(foreach d,$(RTL_DIRS),$(wildcard $(d)/*.sv))

TB ?= tb/tb_soc.sv

sim:
	$(IVERILOG) -g2012 -o simv $(RTL_SRCS) $(TB)

run: sim
	./simv +MEMHEX=program.hex

clean:
	rm -f simv simv.vvp *.vcd

.PHONY: sim run clean
