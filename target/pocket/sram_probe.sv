// SRAM size and speed probe. TEMPORARY, diag builds only.
//
// docs/04 Stage B moves the FAST_SDRAM cache role into Pocket's external
// async SRAM, which no reference core uses. Its size (17 address pins say
// 128 Ki x 16 = 256 KB; apf_top's comment says "1mbit x16") and speed are
// unverified. A cache hit must deliver 32 bits (two 16-bit reads) within
// about 4-5 clk_sys of the read request.
//
// v1 (0.0.15-diag) wrote with a 1-clock WE pulse and read at L = 1..4 only;
// every word failed at every L, which cannot tell a slow part, a half-size
// part and a dead bus apart. v2:
//   1. write every word 0..0x1FFFF ONCE with pattern(addr), using a long,
//      conservative cycle (address setup 2 clk, WE low 8 clk = 75 ns, data
//      held 2 clk after WE rises), safe for a 70 ns part;
//   2. read every word back at latencies L = 2,3,4,5,6,8,10,14 clk_sys
//      (19..132 ns), counting mismatching words per L (4-bit saturating);
//   3. at L = 14, count errors in the lower half (A16 = 0) and the upper half
//      (A16 = 1) separately (16-bit saturating).
// A half-size part (A16 ignored) reads the upper half's pattern everywhere:
// lower half all wrong, upper half clean. A dead bus fails both halves. A
// slow part fails only the short latencies. Neighbouring words, and addr vs
// addr ^ 0x10000, always differ, so stale or aliased data cannot pass.
//
// Every SRAM-facing signal is a plain register driving its pin, so
// FAST_OUTPUT/INPUT_REGISTER can pack them into the I/O cells.

`default_nettype none

module sram_probe (
    input  wire        clk,
    input  wire        rst,            // synchronous; re-arms the probe
    input  wire        start,          // level; the probe runs once per reset
    output reg         done,
    output reg  [31:0] err_nib,        // L = 2,3,4,5,6,8,10,14, MSB nibble first, 4-bit saturating
    output reg  [15:0] err_lo,         // L = 14 errors with A16 = 0, 16-bit saturating
    output reg  [15:0] err_hi,         // L = 14 errors with A16 = 1

    output reg  [16:0] sram_a,
    inout  wire [15:0] sram_dq,
    output reg         sram_oe_n,
    output reg         sram_we_n,
    (* preserve *) output reg sram_ub_n,  // identical to lb_n; kept separate for I/O packing
    (* preserve *) output reg sram_lb_n
);
    // Initial values here, not on the port declarations: Quartus 21.1 dropped
    // the port-declaration form and swept the v1 probe away.
    // The explicit reset makes that impossible regardless.
    initial begin
        done = 1'b0; err_nib = 32'd0; err_lo = 16'd0; err_hi = 16'd0; sram_a = 17'd0;
        sram_oe_n = 1'b1; sram_we_n = 1'b1; sram_ub_n = 1'b1; sram_lb_n = 1'b1;
    end

    reg  [15:0] dout = 16'd0;
    (* preserve *) reg [15:0] dq_oe = 16'd0;   // one register per pin, kept unmerged for I/O packing
    reg  [15:0] din = 16'd0;
    genvar g;
    generate for (g = 0; g < 16; g = g + 1) begin : dq
        assign sram_dq[g] = dq_oe[g] ? dout[g] : 1'bZ;
    end endgenerate
    always @(posedge clk) din <= sram_dq;

    function [15:0] pattern(input [16:0] a);
        pattern = a[15:0] ^ {a[16], 15'd0} ^ {a[7:0], a[15:8]} ^ 16'h5A3C;
    endfunction

    // latency schedule
    function [3:0] lat_of(input [2:0] i);
        case (i)
            3'd0: lat_of = 4'd2;   3'd1: lat_of = 4'd3;   3'd2: lat_of = 4'd4;   3'd3: lat_of = 4'd5;
            3'd4: lat_of = 4'd6;   3'd5: lat_of = 4'd8;   3'd6: lat_of = 4'd10;  default: lat_of = 4'd14;
        endcase
    endfunction

    localparam S_IDLE = 3'd0, S_WR = 3'd1, S_RD = 3'd2, S_NEXT = 3'd3, S_DONE = 3'd4;
    reg [2:0]  st = S_IDLE;
    reg [2:0]  li = 3'd0;             // index into the latency schedule
    reg [3:0]  ph = 4'd0;
    reg [16:0] adr = 17'd0;
    reg [15:0] cnt = 16'd0, cnt_lo = 16'd0, cnt_hi = 16'd0;
    wire [3:0] lat = lat_of(li);

always @(posedge clk) begin
    if (rst) begin
        st <= S_IDLE; done <= 1'b0; err_nib <= 32'd0; err_lo <= 16'd0; err_hi <= 16'd0;
        sram_oe_n <= 1'b1; sram_we_n <= 1'b1; sram_ub_n <= 1'b1; sram_lb_n <= 1'b1;
        dq_oe <= 16'd0;
    end else
    case (st)
    S_IDLE: if (start && !done) begin
        st <= S_WR; li <= 3'd0; adr <= 0; ph <= 0;
        cnt <= 0; cnt_lo <= 0; cnt_hi <= 0;
        sram_ub_n <= 1'b0; sram_lb_n <= 1'b0;
    end
    // write: ph0 address+data, ph2 WE low, ph10 WE high, ph12 next word
    S_WR: begin
        sram_oe_n <= 1'b1;
        if (ph == 4'd0) begin sram_a <= adr; dout <= pattern(adr); dq_oe <= 16'hFFFF; end
        if (ph == 4'd2)  sram_we_n <= 1'b0;
        if (ph == 4'd10) sram_we_n <= 1'b1;
        if (ph == 4'd12) begin
            ph <= 4'd0;
            if (&adr) begin adr <= 0; st <= S_RD; dq_oe <= 16'd0; end
            else adr <= adr + 1'b1;
        end else ph <= ph + 1'b1;
    end
    // read: ph0 drives the address; din captures the pin every clock, so on
    // the cycle where ph == lat + 1, din holds the pin as it was lat clocks
    // after the address register changed.
    S_RD: begin
        sram_oe_n <= 1'b0;
        dq_oe     <= 16'd0;
        if (ph == 4'd0) begin sram_a <= adr; ph <= 4'd1; end
        else if (ph == lat + 4'd1) begin
            if (din != pattern(adr)) begin
                if (~&cnt) cnt <= cnt + 1'b1;
                if (li == 3'd7 && !adr[16] && ~&cnt_lo) cnt_lo <= cnt_lo + 1'b1;
                if (li == 3'd7 &&  adr[16] && ~&cnt_hi) cnt_hi <= cnt_hi + 1'b1;
            end
            ph <= 4'd0;
            if (&adr) st <= S_NEXT;
            else adr <= adr + 1'b1;
        end else ph <= ph + 1'b1;
    end
    S_NEXT: begin
        sram_oe_n <= 1'b1;
        err_nib <= {err_nib[27:0], (cnt > 16'd15) ? 4'hF : cnt[3:0]};
        cnt <= 0; adr <= 0; ph <= 0;
        if (li == 3'd7) begin
            err_lo <= cnt_lo; err_hi <= cnt_hi; st <= S_DONE;
        end else begin
            li <= li + 1'b1; st <= S_RD;
        end
    end
    default: begin
        done <= 1'b1;
        sram_oe_n <= 1'b1; sram_we_n <= 1'b1;
        sram_ub_n <= 1'b1; sram_lb_n <= 1'b1;
    end
    endcase
end

endmodule

`default_nettype wire
