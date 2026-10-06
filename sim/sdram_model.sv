// Behavioural SDR SDRAM model for rtl/mem/sdram_dual.sv.
// CAS latency 2, burst length 2 (read), single-location write (NO_WRITE_BURST).
//
// The address is {bank, row, column} = 2 + 13 + 10 = 25 bits, i.e. the full
// 32M x 16 part. An earlier version folded this to 16 bits to keep the array
// small, which aliased 8:1 and silently corrupted anything larger than 8K
// words -- including a 128 KB BIOS image.
//
// KNOWN LIMITATION: writes driven through the SDRAM_DQ bus come back OR'd with
// the previous cycle's value, because the controller declares SDRAM_DQ as an
// `inout reg` assigned 16'bZ and the simulator's tristate conversion does not
// resolve that against this model's driver. Reads are unaffected. Use
// `preload()` to place data rather than writing it through the bus.
`timescale 1ns/1ps
`default_nettype none

module sdram_model (
    input  wire        clk,
    inout  wire [15:0] dq,
    input  wire [12:0] a,
    input  wire [1:0]  ba,
    input  wire        cs_n,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n
);
    localparam CL = 2;

    localparam int unsigned DEPTH = 1 << 25;   // {ba[1:0], row[12:0], col[9:0]}
    logic [15:0] mem [0:DEPTH-1];
    logic [12:0] row [0:3];

    // ---- protocol checker -------------------------------
    // Real SDR SDRAM punishes protocol violations that this model used to
    // accept silently: RD/WR to a bank with no open row is ignored (a lost
    // write), ACT to an already-open bank is illegal, REF needs every bank
    // idle, and rows must not stay open beyond tRAS(max). Limits are generic
    // 512 Mbit SDR values at 9.40 ns (the Pocket's exact part is not known).
    // +sdram_strict makes violations BEHAVE like a real chip (writes to an idle
    // bank dropped, reads from one return garbage, ACT to an open bank
    // ignored); without it they are only counted.
    localparam int T_RCD = 2, T_RP = 2, T_RC = 7, T_RAS_MIN = 5, T_RFC = 7;
    localparam int T_RAS_MAX = 10636;                  // 100 us
    localparam int T_REFWIN  = 6807487;                // 64 ms
    logic        open_b [0:3];
    int          ap_cnt [0:3];        // auto-precharge countdown after RD/WR with A10=1
    longint      t_act  [0:3], t_pre [0:3];
    longint      mcyc = 0, t_ref = -1000, refwin_start = 0;
    int          refs_in_win = 0, refwin_min = 1 << 30, refwin_n = 0;
    int          v_rw_idle = 0, v_act_open = 0, v_ref_open = 0, v_rcd = 0, v_rp = 0,
                 v_rc = 0, v_ras_min = 0, v_ras_max = 0, v_rfc = 0, n_ref = 0, n_mrs = 0;
    longint      ras_max_seen = 0;
    logic [12:0] mrs_val = 0;
    bit          strict = 0, vprint = 1;
    int          vshown = 0;
    initial begin
        strict = $test$plusargs("sdram_strict");
        for (int b = 0; b < 4; b++) begin open_b[b] = 0; t_act[b] = -1000; t_pre[b] = -1000; ap_cnt[b] = 0; end
    end
    task automatic viol(input string what, input int b);
        if (vshown < 25) begin
            $display("[sdram_model %0d] VIOLATION %s bank %0d (open=%b row=%04x)", mcyc, what, b, open_b[b], row[b]);
            vshown++;
        end
    endtask
    task automatic report();
        $display("");
        $display("====== SDRAM PROTOCOL CHECK (%s) ======", strict ? "strict: violations behave like a real chip" : "count only");
        $display("  RD/WR to idle bank (lost write / garbage read) : %0d", v_rw_idle);
        $display("  ACT to an already-open bank                    : %0d", v_act_open);
        $display("  REF with a bank open                           : %0d", v_ref_open);
        $display("  tRCD / tRP / tRC / tRAS(min) / tRFC short      : %0d / %0d / %0d / %0d / %0d", v_rcd, v_rp, v_rc, v_ras_min, v_rfc);
        $display("  rows open longer than tRAS(max) 100 us         : %0d   (longest %0d cycles = %0.1f us)", v_ras_max, ras_max_seen, ras_max_seen * 0.0094017);
        $display("  REF commands                                   : %0d   (fewest in any complete 64 ms window: %0d, need 8192; %0d windows)",
                 n_ref, (refwin_n > 0) ? refwin_min : -1, refwin_n);
        $display("  MRS                                            : %0d, last value %04x (CL=%0d BL code=%0d)", n_mrs, mrs_val, mrs_val[6:4], mrs_val[2:0]);
        $display("=============================================");
    endtask

    // {ras,cas,we}
    wire [2:0] cmd = {ras_n, cas_n, we_n};
    localparam [2:0] C_ACT = 3'b011, C_RD = 3'b101, C_WR = 3'b100,
                     C_PRE = 3'b010, C_REF = 3'b001, C_MRS = 3'b000;

    function automatic [24:0] fold(input [1:0] b, input [12:0] r, input [9:0] c);
        fold = {b, r, c};
    endfunction

    // Place a word directly, bypassing the bus. Used to load ROM images.
    // Real SDRAM powers up holding garbage, not zeros. Seen on hardware:
    // the Jaguar core fails only on the first launch after power-on, which
    // points at something reading memory nobody wrote. Call this before any
    // preload to model a cold chip. Seeded, so a failing run is repeatable.
    task automatic scramble(input int seed);
        // seed -1: all ones; seed -2: all ones/zeros alternating by row
        // (real cells often power up uniform per array region, not random).
        logic [31:0] x = 32'(seed) | 32'h1;       // xorshift32
        for (int i = 0; i < DEPTH; i++) begin
            if (seed == -1)      mem[i] = 16'hFFFF;
            else if (seed == -2) mem[i] = i[10] ? 16'hFFFF : 16'h0000;
            else begin
                x ^= x << 13; x ^= x >> 17; x ^= x << 5;
                mem[i] = x[15:0];
            end
        end
    endtask

    task automatic preload(input [1:0] b, input [12:0] r, input [9:0] c,
                           input [15:0] d);
        mem[fold(b, r, c)] = d;
    endtask

    // Read pipeline: CL cycles of latency, then BL=2 consecutive words.
    logic        rd_v  [0:CL+2];
    logic        rd_bad[0:CL+2];
    logic [24:0] rd_a  [0:CL+2];
    logic        drive;
    logic [15:0] drive_d;

    // NOTE: a comment line here must not START with the word "Verilator" --
    // that is parsed as a lint pragma and errors with BADVLTPRAGMA.
    //
    // The simulator OR-resolves multiple drivers on an inout rather than
    // honouring 16'bz, so an idle `z` leaked the last read value onto the bus and
    // every controller write came back OR'd with it (0x0001 -> 0x0003,
    // 0x2000 -> 0x2003). Driving an explicit zero when idle makes the
    // OR-resolution behave correctly in both directions: the controller's data
    // passes through untouched on writes, and the model's data passes through
    // on reads because the controller drives 16'bZ (zero) then.
    assign dq = drive ? drive_d : 16'h0000;

    integer i;
    initial begin
        // mem is left at its default (0) rather than looped over: 33M entries.
        for (i = 0; i < 4; i = i + 1) row[i] = '0;
        for (i = 0; i <= CL+2; i = i + 1) begin rd_v[i] = 0; rd_a[i] = '0; rd_bad[i] = 0; end
        drive = 0; drive_d = '0;
    end

    always @(posedge clk) begin
        // shift the read pipe
        for (i = CL+2; i > 0; i = i - 1) begin
            rd_v[i] <= rd_v[i-1];
            rd_a[i] <= rd_a[i-1];
            rd_bad[i] <= rd_bad[i-1];
        end
        rd_v[0] <= 1'b0;

        mcyc <= mcyc + 1;
        // auto-precharge completes BL + tWR (~3 cycles) after the RD/WR
        for (int b = 0; b < 4; b++)
            if (ap_cnt[b] > 0) begin
                ap_cnt[b]--;
                if (ap_cnt[b] == 0) begin open_b[b] = 0; t_pre[b] = mcyc; end
            end
        // tRAS(max): rows left open too long
        for (int b = 0; b < 4; b++)
            if (open_b[b] && (mcyc - t_act[b]) > ras_max_seen) begin
                ras_max_seen = mcyc - t_act[b];
                if (mcyc - t_act[b] == T_RAS_MAX + 1) begin v_ras_max++; viol("tRAS(max) exceeded", b); end
            end
        if (mcyc - refwin_start >= T_REFWIN) begin
            if (refs_in_win < refwin_min) refwin_min = refs_in_win;
            refwin_n++; refs_in_win = 0; refwin_start = mcyc;
        end

        if (!cs_n) begin
            // ---- protocol checks ----
            case (cmd)
                C_ACT: begin
                    if (open_b[ba]) begin v_act_open++; viol("ACT to open bank", ba); end
                    if (mcyc - t_pre[ba] < T_RP) begin v_rp++; viol("tRP", ba); end
                    if (mcyc - t_act[ba] < T_RC) begin v_rc++; viol("tRC", ba); end
                    if (mcyc - t_ref < T_RFC) begin v_rfc++; viol("tRFC (ACT)", ba); end
                end
                C_RD, C_WR: begin
                    if (!open_b[ba]) begin v_rw_idle++; viol(cmd == C_RD ? "READ from idle bank" : "WRITE to idle bank", ba); end
                    else if (mcyc - t_act[ba] < T_RCD) begin v_rcd++; viol("tRCD", ba); end
                end
                C_PRE: for (int b = 0; b < 4; b++)
                    if ((a[10] || b == ba) && open_b[b] && (mcyc - t_act[b] < T_RAS_MIN)) begin v_ras_min++; viol("tRAS(min)", b); end
                C_REF: begin
                    for (int b = 0; b < 4; b++) if (open_b[b]) begin v_ref_open++; viol("REF with bank open", b); end
                    if (mcyc - t_ref < T_RFC) begin v_rfc++; viol("tRFC (REF)", 0); end
                    n_ref++; refs_in_win++; t_ref = mcyc;
                end
                C_MRS: begin n_mrs++; mrs_val = a; end
                default: ;
            endcase
            // ---- bank state ----
            case (cmd)
                C_ACT: if (!(strict && open_b[ba])) begin open_b[ba] = 1; t_act[ba] = mcyc; end
                C_PRE: for (int b = 0; b < 4; b++) if (a[10] || b == ba) begin open_b[b] = 0; t_pre[b] = mcyc; ap_cnt[b] = 0; end
                C_RD, C_WR: if (a[10] && open_b[ba]) ap_cnt[ba] = 3;
                default: ;
            endcase
        end

        if (!cs_n) begin
            case (cmd)
                C_ACT: if (!(strict && open_b[ba] && t_act[ba] != mcyc)) row[ba] <= a;
                C_RD: begin
                    // Burst of 2. ORDER MATTERS: entries shift from low index
                    // to high and `drive` samples rd_v[CL], so index 1 reaches
                    // CL after one shift and index 0 after two -- index 1 is
                    // delivered FIRST. Putting the first column in index 0
                    // returned the burst backwards, swapping the halves of
                    // every 32-bit ch2 read: the BIOS reset vector came out as
                    // 0x00000008 instead of 0x00E00008, so the 68000 ran off
                    // into low memory and executed zeros.
                    rd_v[1] <= 1'b1;
                    rd_bad[1] <= strict && !open_b[ba];
                    rd_bad[0] <= strict && !open_b[ba];
                    rd_a[1] <= fold(ba, row[ba], a[9:0]);           // first
                    rd_v[0] <= 1'b1;
                    rd_a[0] <= fold(ba, row[ba], a[9:0] + 10'd1);   // second
                end
                C_WR: begin
`ifdef SDRAM_MODEL_DEBUG
                    $display("[model] WR ba=%0d row=%04x col=%03x a12_11=%b%b dq=%04x",
                             ba, row[ba], a[9:0], a[12], a[11], dq);
`endif
                    // DQM is carried on a[12:11] by this controller; active-high mask
                    if (!(strict && !open_b[ba])) begin
                        if (!a[11]) mem[fold(ba, row[ba], a[9:0])][7:0]  <= dq[7:0];
                        if (!a[12]) mem[fold(ba, row[ba], a[9:0])][15:8] <= dq[15:8];
                    end
                end
                default: ;
            endcase
        end

        drive   <= rd_v[CL];
        drive_d <= rd_bad[CL] ? 16'(mcyc * 32'h9E3779B1 >> 7) : mem[rd_a[CL]];
    end
endmodule

`default_nettype wire
