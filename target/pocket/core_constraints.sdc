#
# Core timing constraints for the Pocket Jaguar build.
#
# platform/pocket/apf_constraints.sdc already does:
#   create_clock for clk_74a, clk_74b, bridge_spiclk  (13.468 ns)
#   derive_pll_clocks
# so do NOT repeat those here. An earlier version of this file called
# `derive_pll_clocks -create_base_clocks`, which Quartus reported as
# "Warning (332189): derive_pll_clocks was called multiple times with
# different options. Repeated calls do not modify existing clocks." -- i.e. it
# was silently ignored.

derive_clock_uncertainty

# -----------------------------------------------------------------------------
# Clock groups
# -----------------------------------------------------------------------------
# clk_74a (APF bridge/host) is genuinely asynchronous to the core: ROM and BIOS
# data cross through data_loader's dcfifo and controller state through
# synch_3. Without this grouping, STA times those crossings as if they were
# synchronous.
#
# The PLL is referenced to clk_74a (as in core-template and openfpga-SNES), but
# its outputs still get their OWN async group, again matching openfpga-SNES:
# every crossing between clk_74a and the core goes through data_loader's dcfifo
# or synch_3, which are designed as asynchronous crossings.
#
# clk_sys and the two clk_vid outputs MUST stay in one group: they come from the
# same PLL at an exact /4 ratio and jaguar_video depends on that relationship
# (docs/06 section 6.3). Separating them would wrongly cut a transfer that has
# to be analysed.
set_clock_groups -asynchronous \
    -group { clk_74a } \
    -group { clk_74b } \
    -group { bridge_spiclk } \
    -group { ic|mp1|pll_inst|altera_pll_i|*[0].*|divclk \
             ic|mp1|pll_inst|altera_pll_i|*[1].*|divclk \
             ic|mp1|pll_inst|altera_pll_i|*[2].*|divclk }

# -----------------------------------------------------------------------------
# What is deliberately NOT constrained here, and why
# -----------------------------------------------------------------------------
# 1. EXTERNAL SDRAM I/O DELAYS.
#
#    No set_input_delay / set_output_delay on dram_*. This is a considered
#    omission, not an oversight:
#
#      * Writing them needs real board data -- trace lengths and the exact
#        SDRAM part's tAC/tOH -- which we do not have. Invented numbers would
#        force the fitter to retime the pins against a fiction.
#      * agg23/openfpga-SNES, which runs the same Pocket SDRAM at 85.9 MHz,
#        constrains no SDRAM I/O either. Neither does Jaguar_MiSTer.
#      * dram_clk is forwarded through the altddio_out instance inside
#        sdram_dual.sv, which is the known-good arrangement on this board.
#
#    So whether the SDRAM interface works at 106.4 MHz is an EMPIRICAL question
#    for Milestone 3, answered by the controller's own 32/64 MB probe
#    (sdram_dual.sv:239-275, exposed via `ram64`), not by a constraint.
#
# 2. MULTICYCLE PATHS FOR THE CE-GATED CONSOLE.
#
#    Milestone 2 measured -9.352 ns worst setup on clk_sys, and attributed
#    every one of 2,000 failing endpoints to logic inside `jaguar` -- all 50 of
#    the worst to the blitter address-generator carry chain. That logic is
#    xvclk-gated, so it has 4 x 9.4 = 37.6 ns in hardware against the 9.4 ns
#    STA measures it with: the path takes 18.75 ns, leaving ~18.8 ns of real
#    margin. See docs/08 section 8.8.
#
#    Nothing fails in the SDRAM controller, the wrapper, data_loader, sound_i2s
#    or APF -- nothing that genuinely runs every clk_ram cycle. Since there are
#    no real violations being masked, a multicycle exception here would make
#    the report readable without changing anything we know. Add one only if a
#    genuine single-cycle violation appears.
