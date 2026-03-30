RISCV_PREFIX ?= riscv64-unknown-elf
CC      := $(RISCV_PREFIX)-gcc
OBJCOPY := $(RISCV_PREFIX)-objcopy

CFLAGS  := -march=rv64im -mabi=lp64 -nostdlib -nostartfiles -ffreestanding -O2
LDFLAGS := -T link.ld -nostdlib -nostartfiles

all: program.hex

demo.elf: demo.S link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ demo.S

demo.bin: demo.elf
	$(OBJCOPY) -O binary $< $@

program.hex: demo.bin
	python3 ../tools/bin2bytehex.py demo.bin program.hex

clean:
	rm -f demo.elf demo.bin program.hex

.PHONY: all clean
