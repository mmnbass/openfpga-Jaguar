// Unit test for target/pocket/sram_probe.sv: an async
// SRAM model with a chosen access time and size must produce the expected
// error pattern -- errors only at short latencies for a slow part, errors at
// every latency for a part half the size.
`timescale 1ns/1ps
module tb_sram_probe;
    localparam real CLK_NS = 9.40171;
    reg clk = 0;
    always #(CLK_NS/2) clk = ~clk;

    real   taa;      // access time from address change
    int    words;    // part size in words

    wire [16:0] a; wire [15:0] dq; wire oe_n, we_n, ub_n, lb_n;
    wire done; wire [31:0] nib; wire [15:0] lo, hi;
    sram_probe dut (.clk(clk), .rst(1'b0), .start(1'b1), .done(done), .err_nib(nib), .err_lo(lo), .err_hi(hi),
        .sram_a(a), .sram_dq(dq), .sram_oe_n(oe_n), .sram_we_n(we_n),
        .sram_ub_n(ub_n), .sram_lb_n(lb_n));

    reg [15:0] mem [0:131071];
    reg [15:0] q = 16'hDEAD;
    wire [16:0] ai = (words == 65536) ? {1'b0, a[15:0]} : a;
    always @(posedge we_n) mem[ai] = dq;                  // write on WE rising
    // Data is valid only once taa has elapsed since the last address change;
    // before that the bus shows garbage. (A delay line misbehaves once the
    // read period is shorter than taa: it reported false passes.)
    realtime t_chg = 0;
    // The counter is load-bearing: as a bare one-statement block Verilator
    // 5.050 treated this as combinational and t_chg never advanced.
    int n_chg = 0;
    always @(a) begin t_chg = $realtime; n_chg++; end
    always #0.5 q = (($realtime - t_chg) >= taa) ? mem[ai] : 16'h0BAD;
    assign dq = (!oe_n && we_n) ? q : 16'bz;

    initial begin
        if (!$value$plusargs("taa=%f", taa)) taa = 12.0;
        if (!$value$plusargs("words=%d", words)) words = 131072;
        wait (done);
        $display("taa=%.1f ns words=%0d : L2,3,4,5,6,8,10,14 = %h  L14 lower %0d upper %0d",
                 taa, words, nib, lo, hi);
        $finish;
    end
endmodule
