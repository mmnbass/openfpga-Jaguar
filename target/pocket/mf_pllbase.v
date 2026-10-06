//
// Core PLL for the Pocket Jaguar build.
//
// Written as a direct altera_pll megafunction instantiation rather than an
// IP-Catalog-generated .qip, so it is plain readable Verilog in source control
// and needs no regeneration step. Same pattern Jaguar_MiSTer uses in
// rtl/pll/pll_0002.v and agg23/openfpga-SNES uses in
// target/pocket/mf_pllbase/mf_pllbase_0002.v.
//
// Reference is clk_74a. An earlier version used clk_74b, reasoning that a clock
// independent of the bridge would be cleaner. That was never checked against a
// working core, and the first hardware test failed with "Error in core setup":
// if the PLL does not lock, status_boot_done never asserts and the host's
// setup handshake times out. Analogue's core-template AND openfpga-SNES both
// use clk_74a, and there is no evidence clk_74b is driven on the board.
//
// Outputs (docs/03-clocks.md):
//   outclk_0  106.363636 MHz   clk_sys AND clk_ram
//   outclk_1   26.590909 MHz   clk_vid      -> video_rgb_clock
//   outclk_2   26.590909 MHz   clk_vid_90   -> video_rgb_clock_90  (+90 deg)
//
// WHY 106.363636 MHz EXACTLY: rtl/upstream/jaguar.v derives the four Jaguar
// clock-enable phases with a hard-coded 2-bit /4 counter, so clk_sys must be
// 4x the 26.590909 MHz Jaguar video clock. There is no slower-core fallback.
//
// WHY FRACTIONAL: 74.25 -> 106.363636 MHz is M/N = 520/363 (since
// 106.363636.. = 1170/11 MHz and 74.25 = 297/4 MHz). The smallest exact
// integer solution with the VCO in range is M=520, N=33, C=11 for a 1170 MHz
// VCO -- and M=520 exceeds the Cyclone V M-counter limit. So fractional mode
// is required. Record the achieved frequency and ppm error from the fitter's
// PLL Usage Summary.
//
// 90 degrees at 26.590909 MHz: period 37.60684 ns, quarter = 9.40171 ns
// = 9402 ps.
//
`timescale 1 ps / 1 ps

module mf_pllbase (
    input  wire  refclk,
    input  wire  rst,
    output wire  outclk_0,
    output wire  outclk_1,
    output wire  outclk_2,
    output wire  locked
);

    mf_pllbase_0002 pll_inst (
        .refclk   (refclk),
        .rst      (rst),
        .outclk_0 (outclk_0),
        .outclk_1 (outclk_1),
        .outclk_2 (outclk_2),
        .locked   (locked)
    );

endmodule


module mf_pllbase_0002 (
    input  wire refclk,
    input  wire rst,
    output wire outclk_0,
    output wire outclk_1,
    output wire outclk_2,
    output wire locked
);

    altera_pll #(
        .fractional_vco_multiplier  ("true"),
        .reference_clock_frequency  ("74.25 MHz"),
        .operation_mode             ("normal"),
        .number_of_clocks           (3),

        .output_clock_frequency0    ("106.363636 MHz"),
        .phase_shift0               ("0 ps"),
        .duty_cycle0                (50),

        .output_clock_frequency1    ("26.590909 MHz"),
        .phase_shift1               ("0 ps"),
        .duty_cycle1                (50),

        .output_clock_frequency2    ("26.590909 MHz"),
        .phase_shift2               ("9402 ps"),
        .duty_cycle2                (50),

        .output_clock_frequency3    ("0 MHz"), .phase_shift3 ("0 ps"), .duty_cycle3 (50),
        .output_clock_frequency4    ("0 MHz"), .phase_shift4 ("0 ps"), .duty_cycle4 (50),
        .output_clock_frequency5    ("0 MHz"), .phase_shift5 ("0 ps"), .duty_cycle5 (50),
        .output_clock_frequency6    ("0 MHz"), .phase_shift6 ("0 ps"), .duty_cycle6 (50),
        .output_clock_frequency7    ("0 MHz"), .phase_shift7 ("0 ps"), .duty_cycle7 (50),
        .output_clock_frequency8    ("0 MHz"), .phase_shift8 ("0 ps"), .duty_cycle8 (50),
        .output_clock_frequency9    ("0 MHz"), .phase_shift9 ("0 ps"), .duty_cycle9 (50),
        .output_clock_frequency10   ("0 MHz"), .phase_shift10("0 ps"), .duty_cycle10(50),
        .output_clock_frequency11   ("0 MHz"), .phase_shift11("0 ps"), .duty_cycle11(50),
        .output_clock_frequency12   ("0 MHz"), .phase_shift12("0 ps"), .duty_cycle12(50),
        .output_clock_frequency13   ("0 MHz"), .phase_shift13("0 ps"), .duty_cycle13(50),
        .output_clock_frequency14   ("0 MHz"), .phase_shift14("0 ps"), .duty_cycle14(50),
        .output_clock_frequency15   ("0 MHz"), .phase_shift15("0 ps"), .duty_cycle15(50),
        .output_clock_frequency16   ("0 MHz"), .phase_shift16("0 ps"), .duty_cycle16(50),
        .output_clock_frequency17   ("0 MHz"), .phase_shift17("0 ps"), .duty_cycle17(50),

        .pll_type                   ("General"),
        .pll_subtype                ("General")
    ) altera_pll_i (
        .rst        (rst),
        .outclk     ({outclk_2, outclk_1, outclk_0}),
        .locked     (locked),
        .fboutclk   ( ),
        .fbclk      (1'b0),
        .refclk     (refclk)
    );

endmodule
