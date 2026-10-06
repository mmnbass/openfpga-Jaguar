// Q6: confirm the SDRAM controller cycle counts asserted in
// docs/04-memory.md §4.3, which were derived by reading the FSM rather than
// simulated.
//
// Measures, at clk = 106.363636 MHz:
//   * 64-bit ch1 read turnaround, single chip   (ch1_64 = 1)
//   * 32-bit ch1 read turnaround, dual-chip mode(ch1_64 = 0)
//   * 64-bit ch1 write turnaround
//   * ch2 read turnaround
// and compares each against the Jaguar DRAM budget of one access per
// 26.590909 MHz cycle = 37.6 ns.
`timescale 1ns/1ps

module tb_sdram_ch1;

    // 106.363636 MHz -> 9.4017 ns period
    localparam real CLK_NS    = 9.40171;
    localparam real BUDGET_NS = 37.60684;   // 1 / 26.590909 MHz

    logic clk = 0;
    always #(CLK_NS/2.0) clk = ~clk;

    logic        init = 1;
    logic [15:0] dq;
    logic [12:0] sa;
    logic [1:0]  sba;
    logic        scs_n, sras_n, scas_n, swe_n, sdqml, sdqmh, scke, sclk;

    logic [10:3] ch1_addr  = '0;
    logic [12:0] ch1_caddr = '0;
    logic [63:0] ch1_dout, ch1_din = 64'h0;
    logic        ch1_reqr = 0, ch1_reqw = 0, ch1_ref = 0, ch1_act = 0, ch1_pch = 0;
    logic        ch1_rnw = 1, ch1_ready, ch1_64 = 1;
    logic [7:0]  ch1_be = 8'hFF;

    logic [23:1] ch2_addr = '0;
    logic        ch2_addr_ext = 0;
    logic [31:0] ch2_dout;
    logic [15:0] ch2_din = '0;
    logic        ch2_req = 0, ch2_rnw = 1, ch2_ready;
    logic [1:0]  ch2_be = 2'b11;

    logic        ram64;

    sdram dut (
        .init(init), .clk(clk),
        .SDRAM_DQ(dq), .SDRAM_A(sa), .SDRAM_DQML(sdqml), .SDRAM_DQMH(sdqmh),
        .SDRAM_BA(sba), .SDRAM_nCS(scs_n), .SDRAM_nWE(swe_n),
        .SDRAM_nRAS(sras_n), .SDRAM_nCAS(scas_n), .SDRAM_CKE(scke), .SDRAM_CLK(sclk),
        .ch1_addr(ch1_addr), .ch1_caddr(ch1_caddr), .ch1_dout(ch1_dout),
        .ch1_din(ch1_din), .ch1_reqr(ch1_reqr), .ch1_reqw(ch1_reqw),
        .ch1_ref(ch1_ref), .ch1_act(ch1_act), .ch1_pch(ch1_pch),
        .ch1_rnw(ch1_rnw), .ch1_be(ch1_be), .ch1_ready(ch1_ready), .ch1_64(ch1_64),
        .ch2_addr(ch2_addr), .ch2_addr_ext(ch2_addr_ext), .ch2_dout(ch2_dout),
        .ch2_din(ch2_din), .ch2_req(ch2_req), .ch2_rnw(ch2_rnw),
        .ch2_be(ch2_be), .ch2_ready(ch2_ready),
        .ch3_addr(24'h0), .ch3_dout(), .ch3_din(32'h0), .ch3_req(1'b1),
        .ch3_rnw(1'b1), .ch3_ready(),
        .ram64(ram64), .self_refresh(1'b1)
    );

    sdram_model mem (
        .clk(sclk), .dq(dq), .a(sa), .ba(sba),
        .cs_n(scs_n), .ras_n(sras_n), .cas_n(scas_n), .we_n(swe_n)
    );

    // ---- measurement ------------------------------------------------------
    // ch1_ready is NOT a busy flag for reads: STATE_IDLE asserts it every
    // cycle and the ch1 read path never clears it. (This is consistent with
    // Jaguar.sv deriving ram_rdy as a "latency kludge" rather than using
    // ch1_ready.) So measure the SDRAM command bus instead, which is what
    // actually bounds bandwidth.
    int cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    wire [2:0] cmd  = {sras_n, scas_n, swe_n};
    wire is_read    = (!scs_n) && (cmd == 3'b101);
    wire is_write   = (!scs_n) && (cmd == 3'b100);
    wire is_act     = (!scs_n) && (cmd == 3'b011);
    wire is_ref     = (!scs_n) && (cmd == 3'b001);

    // Collect inter-command gaps for whichever command we are watching.
    int  gap[0:63];      // histogram of gaps, clamped to 63
    int  nobs;
    int  last;

    task automatic watch_reset();
        int i;
        for (i = 0; i < 64; i++) gap[i] = 0;
        nobs = 0; last = -1;
    endtask

    // Returns the most common gap (the steady-state, refresh-free value).
    function automatic int modal_gap();
        int i, best, bestn;
        best = 0; bestn = 0;
        for (i = 1; i < 64; i++) if (gap[i] > bestn) begin bestn = gap[i]; best = i; end
        return best;
    endfunction

    function automatic int sum_gap_pairs();
        // For ch1_64=1 a 64-bit access is TWO reads: gaps alternate
        // (intra-access, inter-access). The access period is their sum, which
        // is the sum of the two most common gaps.
        int i, a, an, b, bn;
        a = 0; an = 0; b = 0; bn = 0;
        for (i = 1; i < 64; i++) begin
            if (gap[i] > an)      begin b = a; bn = an; a = i; an = gap[i]; end
            else if (gap[i] > bn) begin b = i; bn = gap[i]; end
        end
        return a + b;
    endfunction

    task automatic print_hist(string what);
        int i;
        $write("      %s gaps:", what);
        for (i = 1; i < 64; i++) if (gap[i] > 0) $write("  %0d cyc x%0d", i, gap[i]);
        $write("\n");
    endtask

    task automatic report(string name, int cycles);
        real ns;
        ns = cycles * CLK_NS;
        $display("  %-40s %2d cyc  %6.2f ns  %4.2fx budget  %s",
                 name, cycles, ns, ns / BUDGET_NS,
                 (ns <= BUDGET_NS) ? "OK" : "OVER");
    endtask

    // Sampler: run for `n` cycles recording gaps between asserted commands.
    task automatic sample(input int n, input int which);
        int i; logic hit;
        watch_reset();
        for (i = 0; i < n; i++) begin
            @(posedge clk);
            #0;
            hit = (which == 0) ? is_read : (which == 1) ? is_write : is_act;
            if (hit) begin
                if (last >= 0) begin
                    int d; d = cyc - last;
                    if (d > 63) d = 63;
                    gap[d]++; nobs++;
                end
                last = cyc;
            end
        end
    endtask

    int c_r64, c_r32, c_w64, c_ch2, nref;

    initial begin
        repeat (8) @(posedge clk);
        init = 0;
        $display("waiting for controller self-init (sdram_startup_cycles = 12100)...");
        repeat (14000) @(posedge clk);
        $display("init complete at cycle %0d; controller probed ram64 = %b", cyc, ram64);
        $display("");
        $display("clk = %.4f MHz (%.5f ns). Jaguar DRAM budget = %.2f ns per 64-bit access.",
                 1000.0/CLK_NS, CLK_NS, BUDGET_NS);
        $display("");

        // Open a page. One ch1_act opens BA0 (STATE_IDLE) and BA1 (STATE_ACT2),
        // which is what the 64-bit read path needs.
        ch1_caddr = 13'h0010;
        @(negedge clk); ch1_act = 1; @(negedge clk); ch1_act = 0;
        repeat (16) @(posedge clk);
        ch1_addr = 8'h20;

        $display("ch1 sustained turnaround, request permanently pending:");

        // --- 64-bit read, single chip -------------------------------------
        ch1_64 = 1; ch1_rnw = 1;
        @(negedge clk); ch1_reqr = 1;
        sample(3000, 0);
        @(negedge clk); ch1_reqr = 0;
        c_r64 = sum_gap_pairs();
        print_hist("64-bit read (2 READ cmds per access)");
        report("64-bit read, single chip  (ch1_64=1)", c_r64);
        repeat (20) @(posedge clk);

        // --- 32-bit read, dual-chip mode ----------------------------------
        ch1_64 = 0;
        @(negedge clk); ch1_reqr = 1;
        sample(3000, 0);
        @(negedge clk); ch1_reqr = 0;
        c_r32 = modal_gap();
        print_hist("32-bit read (1 READ cmd per access)");
        report("32-bit read, dual-chip    (ch1_64=0)", c_r32);
        repeat (20) @(posedge clk);

        // --- 64-bit write --------------------------------------------------
        ch1_64 = 1; ch1_rnw = 0; ch1_din = 64'h1122_3344_5566_7788;
        @(negedge clk); ch1_reqw = 1;
        sample(3000, 1);
        @(negedge clk); ch1_reqw = 0; ch1_rnw = 1;
        // A 64-bit write is 4 WRITE commands (IDLE, RW2, RW3, RW4).
        c_w64 = 0;
        begin int i; for (i = 1; i < 64; i++) if (gap[i] > 0) c_w64 += i * gap[i];
              if (nobs > 0) c_w64 = (c_w64 * 4) / nobs; end
        print_hist("64-bit write (4 WRITE cmds per access)");
        report("64-bit write, single chip (ch1_64=1)", c_w64);
        repeat (20) @(posedge clk);

        // --- ch2 read -------------------------------------------------------
        $display("");
        $display("ch2 (cart ROM / BIOS) sustained turnaround:");
        ch2_addr = 23'h001234; ch2_rnw = 1;
        @(negedge clk); ch2_req = 1;
        sample(3000, 2);     // one ACTIVE per ch2 access
        @(negedge clk); ch2_req = 0;
        c_ch2 = modal_gap();
        print_hist("ch2 read (1 ACTIVE cmd per access)");
        report("ch2 read (ACTIVE + auto-precharge)", c_ch2);

        $display("");
        $display("=== versus docs/04-memory.md table 4.3 ===");
        $display("  predicted : 64b 1-chip read 7, 32b 2-chip read 5, ch2 read 6");
        $display("  measured  : 64b 1-chip read %0d, 32b 2-chip read %0d, ch2 read %0d",
                 c_r64, c_r32, c_ch2);
        if (c_r64 == 7 && c_r32 == 5 && c_ch2 == 6)
            $display("  RESULT: table CONFIRMED");
        else
            $display("  RESULT: table NEEDS CORRECTION -> use the measured values");
        $display("");
        $display("  sustained ch1 read bandwidth, single chip : %6.1f MB/s",
                 8.0 / (c_r64 * CLK_NS * 1e-9) / 1e6);
        $display("  sustained ch1 read bandwidth, dual chip   : %6.1f MB/s",
                 8.0 / (c_r32 * CLK_NS * 1e-9) / 1e6);
        $display("  Jaguar DRAM demand                        :  212.7 MB/s");
        $finish;
    end

    initial begin
        #8_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
