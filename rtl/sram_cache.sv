// Stage B: two more FAST_SDRAM cache regions in Pocket's external SRAM
// (docs/04 section 4.5).
//
// Upstream's FAST_SDRAM keeps the upper 32 bits of every 64-bit DRAM word of
// a 256 KB region in BRAM, so a read there need not wait for the 4-beat SDRAM
// burst (the ram_rdy "latency kludge"). Pocket's BRAM holds two such regions
// (A, B in jaguar_top). This module adds regions C and D in the 256 KB async
// SRAM: word address {C/D, sdram_addr[14:0], half}, 2 x 32 Ki x 2 x 16 bit.
//
// Measured inputs:
//   SRAM at 3.3-V LVTTL 8 mA reads clean 2 clk (19 ns) after the address
//   register's edge; Tom consumes the upper half 8 clk after dram_go_rd;
//   dram_go_rd -> CAS edge is always 5 clk; Tom's writes are >= 8 clk
//   apart.
//
// v2. v1 fed Tom's raw strobes and address (whose paths into this clock
// domain fail setup by ~7 ns) straight into the state machine's next-state
// logic on every clock. On silicon that left the one-hot state register in
// an illegal state -- the power-up self-test hung (0.0.19), and corrupted
// queue/hit state is the likely cause of 0.0.18's glitches. Simulation, with
// no wire delay, could not show it. Now:
//   * every raw input is captured once in an input register (_r) and only
//     the registered copies reach the state machine, queue and counters; a
//     late raw signal can at worst misplace one event;
//   * `hit` is cas AND a register computed from registers only -- the same
//     shape as upstream's ram_rdy = ~ch1_req || use_fastram;
//   * which upper half Tom gets (use_q) is a compare of registered addresses;
//   * the state register is a safe encoding: an illegal state recovers.
//
// Read, edges counted from E0 = the edge that samples dram_go_rd:
//   E1 start (go seen in rd_go_r): word 0 ([63:48]) address
//   E3 word 1 address               | din = word 0 (2 clk after E1)
//   E4 q[31:16] <= din              | E6 q[15:0] <= din, q valid
//   busy to E9, so q is not overwritten before Tom consumes it (by E8).
// Hit, asked while CAS is high (before E5): a read with this tag was started,
// and the cache is not disabled. A miss falls back to the SDRAM path, which
// always holds all 64 bits: the SRAM can only make a read faster.
//
// Write-through: every Tom write to C or D with any of be[7:4] set is queued
// (8 deep). Per 16-bit word: address/data/byte lanes, WE low 2 clk, 1 clk
// hold = 4 clk; a 64-bit write takes 8 clk, Tom's fastest write rate. Writes
// have priority over reads; OE is high while writing, with one turnaround
// clock either side. A queue overflow would lose coherence, so it sets a
// sticky disable (all reads fall back) until reset. A write to the address
// held in q invalidates q.
//
// Every SRAM-facing signal is a plain register driving its pin, for I/O-cell
// packing (sram_probe).

`default_nettype none

module sram_cache (
    input  wire        clk,
    input  wire        rst,

    input  wire [2:0]  reg_c,            // region held in SRAM half 0
    input  wire [2:0]  reg_d,            // region held in SRAM half 1 (ignored if == reg_c)

    // read request: dram_go_rd, with {ras_latch, dram_addressp[10:3]} (raw)
    input  wire        rd_go,
    input  wire [17:0] rd_addr,
    // CAS edge of a read (raw), and the true address (sdram_addr, registers)
    input  wire        cas,
    input  wire [17:0] cas_addr,
    output wire        hit,              // cas AND hit_pre: keep Tom from stalling
    output wire        use_q,            // q holds the upper half for cas_addr
    output reg  [31:0] q,                // upper 32 bits [63:32]

    // write: ch1_reqw, with {ras_latch, dram_a[7:0]} (raw)
    input  wire        wr_go,
    input  wire [17:0] wr_addr,
    input  wire [31:0] wr_data,          // ch1_din[63:32]
    input  wire [3:0]  wr_be,            // ch1_be[7:4], active high, [3] = bits 63:56

    // Power-up write self-test, diag builds. Runs once,
    // independent of rst, before the cache serves anything: for WE-low widths
    // W = 1, 2, 3, 6 clk (the cache uses 2), fill all 128 Ki words with the
    // cache's own write sequence (1 clk setup, W clk WE low, 1 clk hold,
    // back-to-back words), then read every word back at a safe L = 4 clk.
    input  wire        bist_en,
    input  wire        bist_start,       // level (pll locked)
    output reg         bist_done,
    output reg  [15:0] bist_err,         // {W1,W2,W3,W6} wrong words, 4-bit saturating
    output reg  [15:0] bist_err_w2,      // W = 2 wrong words, 16-bit saturating

    // statistics (diagnostic overlay)
    output reg         disabled,
    output reg  [15:0] n_hit,
    output reg  [15:0] n_fallback,
    output reg  [3:0]  q_max,

    output reg  [16:0] sram_a,
    inout  wire [15:0] sram_dq,
    output reg         sram_oe_n,
    output reg         sram_we_n,
    (* preserve *) output reg sram_ub_n,
    (* preserve *) output reg sram_lb_n
);
    initial begin
        q = 32'd0; disabled = 1'b0; n_hit = 16'd0; n_fallback = 16'd0; q_max = 4'd0;
        bist_done = 1'b0; bist_err = 16'd0; bist_err_w2 = 16'd0;
        sram_a = 17'd0; sram_oe_n = 1'b0; sram_we_n = 1'b1; sram_ub_n = 1'b0; sram_lb_n = 1'b0;
    end

    // ---- SRAM data pins -----------------------------------------------------
    reg  [15:0] dout = 16'd0;
    (* preserve *) reg [15:0] dq_oe = 16'd0;
    reg  [15:0] din = 16'd0;
    genvar g;
    generate for (g = 0; g < 16; g = g + 1) begin : dq
        assign sram_dq[g] = dq_oe[g] ? dout[g] : 1'bZ;
    end endgenerate
    always @(posedge clk) din <= sram_dq;

    // ---- input registers: the only logic that sees Tom's raw signals --------
    reg         rd_go_r = 1'b0, wr_go_r = 1'b0, cas_r = 1'b0;
    reg  [17:0] rd_addr_r = 18'd0, wr_addr_r = 18'd0;
    reg  [31:0] wr_data_r = 32'd0;
    reg  [3:0]  wr_be_r = 4'd0;
    always @(posedge clk) begin
        rd_go_r <= rd_go;  rd_addr_r <= rd_addr;
        wr_go_r <= wr_go;  wr_addr_r <= wr_addr;  wr_data_r <= wr_data;  wr_be_r <= wr_be;
        cas_r   <= cas;
    end

    wire d_ok = (reg_d != reg_c);
    function in_cd(input [17:0] a);
        in_cd = (a[17:15] == reg_c) || (d_ok && a[17:15] == reg_d);
    endfunction
    function sel_of(input [17:0] a);
        sel_of = !(a[17:15] == reg_c);          // 0 = C, 1 = D
    endfunction

    // ---- write queue: {sel, a[14:0], be[3:0], data[31:0]} -------------------
    localparam QW = 1 + 15 + 4 + 32;
    reg  [QW-1:0] wq [0:7];
    reg  [2:0]    wq_r = 3'd0, wq_w = 3'd0;
    reg  [3:0]    wq_n = 4'd0;
    wire          wq_empty = (wq_n == 4'd0);
    wire          wq_full  = (wq_n == 4'd8);
    wire          wq_push  = wr_go_r && in_cd(wr_addr_r) && (|wr_be_r);
    reg           wq_pop = 1'b0;

    // ---- engine -------------------------------------------------------------
    localparam S_IDLE = 3'd0, S_RD = 3'd1, S_WPRE = 3'd2, S_WR = 3'd3, S_TURN = 3'd4,
               S_BW   = 3'd5, S_BR = 3'd6, S_BN   = 3'd7;
    (* syn_encoding = "safe" *) reg [2:0] st = S_IDLE;
    reg  [3:0]  ph = 4'd0;
    reg  [17:0] tag = 18'd0;
    reg         tag_ok = 1'b0;          // a read with this tag was started
    reg         hit_pre = 1'b0;         // registered: tag_ok && tag == cas_addr
    reg         hit_d = 1'b0;
    reg  [17:0] q_tag = 18'd0;
    reg         q_valid = 1'b0;
    reg  [QW-1:0] cur = {QW{1'b0}};
    reg         word = 1'b0;            // 0 = [63:48], 1 = [47:32]

    // self-test
    reg  [1:0]  bv = 2'd0;              // variant: W = 1, 2, 3, 6
    reg  [16:0] ba = 17'd0;
    reg  [15:0] bcnt = 16'd0;
    reg         bist_busy = 1'b0;
    wire [3:0]  bw = (bv == 2'd0) ? 4'd1 : (bv == 2'd1) ? 4'd2 : (bv == 2'd2) ? 4'd3 : 4'd6;
    wire        bist_go = bist_en && bist_start && !bist_done && !bist_busy;
    function [15:0] bpat(input [16:0] a, input [1:0] v);
        bpat = a[15:0] ^ {a[16], 15'd0} ^ {a[7:0], a[15:8]} ^ {v, v, v, v, v, v, v, v} ^ 16'h3C5A;
    endfunction

    wire rd_start = wq_empty && !wq_push && rd_go_r && in_cd(rd_addr_r) && !disabled && !bist_busy;

    assign hit   = cas && hit_pre;
    assign use_q = q_valid && (q_tag == cas_addr) && !disabled;

    wire [1:0] be_w0 = cur[35:34], be_w1 = cur[33:32];

always @(posedge clk) begin
    wq_pop  <= 1'b0;
    hit_pre <= tag_ok && (tag == cas_addr) && !disabled;
    hit_d   <= hit;

    // queue bookkeeping
    if (wq_push) begin
        if (wq_full) disabled <= 1'b1;                       // overflow: coherence lost
        else begin
            wq[wq_w] <= {sel_of(wr_addr_r), wr_addr_r[14:0], wr_be_r, wr_data_r};
            wq_w <= wq_w + 1'b1;
        end
        if (wr_addr_r == q_tag) q_valid <= 1'b0;             // q no longer current
    end
    if (wq_push && !wq_full && !wq_pop) wq_n <= wq_n + 1'b1;
    else if (wq_pop && !(wq_push && !wq_full)) wq_n <= wq_n - 1'b1;
    if (wq_n > q_max) q_max <= wq_n;

    if (cas_r) begin
        tag_ok <= 1'b0;                                      // a tag answers one CAS only
        if (in_cd(cas_addr)) begin
            if (hit_d) begin if (~&n_hit) n_hit <= n_hit + 1'b1; end
            else       begin if (~&n_fallback) n_fallback <= n_fallback + 1'b1; end
        end
    end

    case (st)
    S_IDLE: begin
        sram_oe_n <= 1'b0; sram_we_n <= 1'b1; dq_oe <= 16'd0;
        sram_ub_n <= 1'b0; sram_lb_n <= 1'b0;
        if (bist_go) begin
            bist_busy <= 1'b1; bv <= 2'd0; ba <= 17'd0; ph <= 4'd0; bcnt <= 16'd0;
            sram_oe_n <= 1'b1;
            st <= S_BW;
        end else if (bist_busy) begin
            // not reached: the self-test only returns here when it is finished
        end else if (!wq_empty) begin
            cur  <= wq[wq_r]; wq_r <= wq_r + 1'b1; wq_pop <= 1'b1;
            word <= (wq[wq_r][35:34] == 2'b00);              // skip an untouched word
            sram_oe_n <= 1'b1;                               // SRAM stops driving first
            st <= S_WPRE;
        end else if (rd_start) begin
            sram_a  <= {sel_of(rd_addr_r), rd_addr_r[14:0], 1'b0};
            tag     <= rd_addr_r; tag_ok <= 1'b1;
            q_tag   <= rd_addr_r; q_valid <= 1'b0;
            st <= S_RD; ph <= 4'd1;
        end
    end
    // read: ph counts edges after the start edge E1
    S_RD: begin
        ph <= ph + 1'b1;
        if (ph == 4'd2) sram_a[0] <= 1'b1;                   // E3: word 1's address
        if (ph == 4'd3) q[31:16] <= din;                     // E4: word 0 (din from E3)
        if (ph == 4'd5) begin q[15:0] <= din; q_valid <= 1'b1; end   // E6: word 1
        if (ph == 4'd8) st <= S_IDLE;                        // E9: Tom has consumed q
    end
    S_WPRE: begin                                            // OE high one clk before driving
        ph <= 4'd0;
        st <= S_WR;
    end
    // One 16-bit word in 4 clk. Edge ph0: address, data, byte lanes out.
    // ph1: WE low. ph3: WE high, and the next word or write is chosen, so its
    // address/data change at the following edge -- 1 clk of hold after WE
    // rises. Back-to-back writes skip S_WPRE: 8 clk per 64-bit write.
    S_WR: begin
        ph <= ph + 1'b1;
        if (ph == 4'd0) begin
            sram_a    <= {cur[51], cur[50:36], word};
            dout      <= word ? cur[15:0] : cur[31:16];
            sram_ub_n <= word ? !be_w1[1] : !be_w0[1];
            sram_lb_n <= word ? !be_w1[0] : !be_w0[0];
            dq_oe     <= 16'hFFFF;
        end
        if (ph == 4'd1) sram_we_n <= 1'b0;
        if (ph == 4'd3) begin
            sram_we_n <= 1'b1;
            ph <= 4'd0;
            if (!word && be_w1 != 2'b00) word <= 1'b1;       // second word of this write
            else if (!wq_empty) begin                        // next queued write, OE stays high
                cur  <= wq[wq_r]; wq_r <= wq_r + 1'b1; wq_pop <= 1'b1;
                word <= (wq[wq_r][35:34] == 2'b00);
            end else begin
                st <= S_TURN;                                // data held this clk, then released
            end
        end
    end
    S_TURN: begin dq_oe <= 16'd0; st <= S_IDLE; end         // OE goes low only in S_IDLE
    // ---- self-test: write pass, same per-word sequence as S_WR ----
    S_BW: begin
        sram_oe_n <= 1'b1;
        ph <= ph + 1'b1;
        if (ph == 4'd0) begin
            sram_a <= ba; dout <= bpat(ba, bv); dq_oe <= 16'hFFFF;
            sram_ub_n <= 1'b0; sram_lb_n <= 1'b0;
        end
        if (ph == 4'd1) sram_we_n <= 1'b0;
        if (ph == 4'd1 + bw) begin
            sram_we_n <= 1'b1;
            ph <= 4'd0;
            if (&ba) begin ba <= 17'd0; st <= S_BN; end      // S_BN: release bus, then read
            else ba <= ba + 1'b1;
        end
    end
    // ---- self-test: read pass at L = 4 ----
    S_BR: begin
        sram_oe_n <= 1'b0; dq_oe <= 16'd0;
        if (ph == 4'd0) begin sram_a <= ba; ph <= 4'd1; end
        else if (ph == 4'd5) begin
            if (din != bpat(ba, bv) && ~&bcnt) bcnt <= bcnt + 1'b1;
            ph <= 4'd0;
            if (&ba) begin
                ba <= 17'd0;
                bist_err <= {bist_err[11:0], (bcnt > 16'd15) ? 4'hF : bcnt[3:0]};
                if (bv == 2'd1) bist_err_w2 <= bcnt;
                bcnt <= 16'd0;
                if (bv == 2'd3) begin
                    bist_busy <= 1'b0; bist_done <= 1'b1; st <= S_IDLE;
                end else begin
                    bv <= bv + 1'b1; sram_oe_n <= 1'b1; st <= S_BW;
                end
            end else ba <= ba + 1'b1;
        end else ph <= ph + 1'b1;
    end
    // between passes: drop the drivers one clk before OE goes low
    S_BN: begin dq_oe <= 16'd0; ph <= 4'd0; st <= S_BR; end
    default: st <= S_IDLE;
    endcase

    // the self-test runs through reset (the console is held in reset while
    // the cart loads, which is when it runs)
    if (rst && !bist_busy && !bist_go) begin
        st <= S_IDLE; ph <= 4'd0; tag_ok <= 1'b0; q_valid <= 1'b0; disabled <= 1'b0;
        wq_r <= 3'd0; wq_w <= 3'd0; wq_n <= 4'd0;
        n_hit <= 16'd0; n_fallback <= 16'd0; q_max <= 4'd0;
        sram_oe_n <= 1'b0; sram_we_n <= 1'b1; dq_oe <= 16'd0;
    end
end

endmodule

`default_nettype wire
