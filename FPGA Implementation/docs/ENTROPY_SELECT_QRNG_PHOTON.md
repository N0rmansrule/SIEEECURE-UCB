Entropy-select key generation for SIEEECURE CPU/GPU
==================================================

Why this path exists
--------------------
The QRNG paper in the project references a practical diode-based approach using
 a reverse-biased Zener diode, a common-emitter amplifier, an 8-bit ADC at
25 MSa/s, and SHA-256 post-processing. The SE paper assumes a small trusted
hardware unit that consumes symmetric keys while keeping plaintext local.
This project's entropy-select path is a hardware-friendly bridge between those
ideas:

1) raw entropy arrives from one of two board-level sources
   - QRNG front-end (reverse-biased diode -> LNA/amplifier -> ADC)
   - photonic / photon-count entropy front-end
2) entropy_source_mux selects or mixes the source streams
3) entropy_conditioner collects 256 bits and produces key + seed
4) se_key_manager fans that key/seed into CPU SE units and the SE-aware GPU

Modules added
-------------
- rtl/se/entropy_source_mux.sv
- rtl/se/entropy_conditioner.sv
- rtl/se/se_key_manager.sv
- rtl/soc/soc_quad_secure_entropy_gpu_tetris_top.sv
- rtl/soc/ecp5_quad_entropy_gpu_tetris_top.sv

Selection control
-----------------
entropy_sel[1:0]
  00 manual/static key path
  01 QRNG-selected path
  10 photonic-selected path
  11 mixed QRNG^photonic path

Important implementation note
-----------------------------
The included entropy_conditioner is intentionally lightweight so it is easier to
fit into an ECP5-85K together with 4 CPU cores, caches, and the SE-GPU.
For production work, replace it with a stronger conditioner / health-test chain.
