# run_sim.tcl — ModelSim or Vivado xsim simulation script
#
# ModelSim usage:
#   vsim -do scripts/run_sim.tcl
#
# Vivado xsim: compile RTL with xvlog, then:
#   xsim tb_aes128_core -runall

set RTL {
    ../rtl/aes_sbox.v
    ../rtl/aes_mixcol.v
    ../rtl/aes_key_expand.v
    ../rtl/aes_round.v
    ../rtl/aes_final_round.v
    ../rtl/aes128_core.v
    ../rtl/aes128_axi.v
}

set TB_CORE  ../sim/tb_aes128_core.v
set TB_AXI   ../sim/tb_aes128_axi.v

proc compile_all {rtl_list tb} {
    foreach f $rtl_list { vlog -quiet $f }
    vlog -quiet $tb
}

# Run core testbench
puts "\n=== Compiling and running tb_aes128_core ==="
vlib work
compile_all $RTL $TB_CORE
vsim -quiet tb_aes128_core
run -all

# Run AXI testbench
puts "\n=== Compiling and running tb_aes128_axi ==="
compile_all $RTL $TB_AXI
vsim -quiet tb_aes128_axi
run -all

quit
