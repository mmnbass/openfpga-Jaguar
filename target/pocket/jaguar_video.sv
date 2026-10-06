//
// jaguar_video -- convert the Jaguar core's clock-enable video into a stream
// the Pocket's scaler accepts.
//
// v2, after the first hardware test. v1 passed the
// console's signals straight through, which broke three APF rules and gave a
// striped screen on hardware:
//
//   1. HS/VS must be ONE-clock pulses (core-template core_top.v, SNES
//      scanline_filler). v1 passed through multi-cycle sync levels.
//   2. Each line must write exactly the width video.json declares. v1 held DE
//      for the whole Jaguar active period at 26.59 MHz, about 1287 clocks,
//      doubling the console's 13.3 MHz pixels, against a declared 640. The
//      line count also varied from 221 to 230.
//   3. video_rgb must be 0 while DE is low, because APF reads it as scaler
//      commands then (the SNES core selects scaler slots that way). v1 put the
//      Jaguar border colour there.
//
// v2 produces a fixed raster: one VS pulse, then exactly V_LINES lines per
// frame, each exactly H_PIXELS written pixels.
//
//   * Horizontal. A line starts where Tom's hblank falls. A pixel is written
//     only on a clk_vid edge that carries a new console pixel (vid_ce);
//     otherwise video_skip is raised with DE held high, so DE is one
//     contiguous run per line. If the console gives fewer than H_PIXELS
//     pixels, the line is padded with black at the full clock rate; if more,
//     it is cropped. In the rare /1 pixel mode (about 1287 pixels per line)
//     every other pixel is written, decided from the previous line.
//   * Vertical. Lines are counted from VS. Lines V_START .. V_START+V_LINES-1
//     are emitted. Lines in that window where the console is in vblank are
//     emitted black, starting at the hblank-fall position learned from the
//     last active line. So the frame is always exactly V_LINES lines, wherever
//     the game puts its VDB/VDE.
//   * Fallback. If the console produces no VS for ~75 ms (in reset, or hung
//     before the BIOS programs Tom), a free-running blank raster with the same
//     geometry is emitted instead, so the Pocket always gets valid frames.
//     Without it a dead console leaves the scaler showing stale memory
//     (white/black stripes on hardware), which hides every diagnostic.
//
// CLOCKING is unchanged from v1. clk_vid is an exact /4 of clk_sys from the
// same PLL, so this is a synchronous transfer with a fixed phase that is not
// known at design time. It is not a CDC. Values are latched in clk_sys and
// held PIPE cycles before clk_vid samples them. A new console pixel is marked
// with a toggle rather than a pulse, so clk_vid sees it whichever clk_sys
// phase its edge lands on.
//
`default_nettype none

module jaguar_video #(
    parameter int PIPE     = 2,
    parameter int H_PIXELS = 640,
    parameter int V_LINES  = 240,
    parameter int V_START  = 17     // first emitted line after VS. BIOS active lines are 23..251 of 261-262, so 17..256 centres them (6 above, 5 below)
) (
    // ---- clk_sys (106.363636 MHz) domain -----------------------------------
    input  wire        clk_sys,
    input  wire        vid_ce,        // jaguar.v: xvclk & pix_pp
    input  wire [7:0]  vga_r,
    input  wire [7:0]  vga_g,
    input  wire [7:0]  vga_b,
    input  wire        vga_hs,
    input  wire        vga_vs,
    input  wire        hblank,
    input  wire        vblank,

    // ---- clk_vid (26.590909 MHz) domain ------------------------------------
    input  wire        clk_vid,
    output reg  [23:0] video_rgb  = 24'h0,
    output reg         video_de   = 1'b0,
    output reg         video_skip = 1'b0,
    output reg         video_hs   = 1'b0,
    output reg         video_vs   = 1'b0,
    output reg         fallback   = 1'b1    // 1 = console gives no sync; own blank raster
);

    // ---- capture in clk_sys -------------------------------------------------
    reg [23:0] px_hold = 0;
    reg        px_tog  = 0;
    always @(posedge clk_sys)
        if (vid_ce) begin
            px_hold <= {vga_r, vga_g, vga_b};
            px_tog  <= ~px_tog;
        end

    reg [23:0] px_pipe  [0:PIPE-1];
    reg [PIPE-1:0] tog_pipe = 0, hs_pipe = 0, vs_pipe = 0, hbl_pipe = 0, vbl_pipe = 0;
    integer i;
    always @(posedge clk_sys) begin
        px_pipe[0] <= px_hold;
        for (i = 1; i < PIPE; i = i + 1) px_pipe[i] <= px_pipe[i-1];
        tog_pipe <= {tog_pipe[PIPE-2:0], px_tog};
        hs_pipe  <= {hs_pipe [PIPE-2:0], vga_hs};
        vs_pipe  <= {vs_pipe [PIPE-2:0], vga_vs};
        hbl_pipe <= {hbl_pipe[PIPE-2:0], hblank};
        vbl_pipe <= {vbl_pipe[PIPE-2:0], vblank};
    end

    // ---- clk_vid: register the source once ----------------------------------
    reg [23:0] s_px  = 0;
    reg        s_tog = 0, s_hs = 0, s_vs = 0, s_hbl = 1, s_vbl = 1;
    reg        p_tog = 0, p_hs = 0, p_vs = 0, p_hbl = 1;
    always @(posedge clk_vid) begin
        s_px  <= px_pipe [PIPE-1];
        s_tog <= tog_pipe[PIPE-1];
        s_hs  <= hs_pipe [PIPE-1];
        s_vs  <= vs_pipe [PIPE-1];
        s_hbl <= hbl_pipe[PIPE-1];
        s_vbl <= vbl_pipe[PIPE-1];
        p_tog <= s_tog;  p_hs <= s_hs;  p_vs <= s_vs;  p_hbl <= s_hbl;
    end

    wire new_px  = s_tog ^ p_tog;
    wire hs_rise = s_hs & ~p_hs;
    wire vs_rise = s_vs & ~p_vs;
    wire hbl_fall = ~s_hbl & p_hbl;

    // ---- raster state -------------------------------------------------------
    localparam [1:0] IDLE = 2'd0, ACTIVE = 2'd1, PAD = 2'd2;
    reg [1:0]  st       = IDLE;
    reg [10:0] hcnt     = 0;      // clk_vid cycles since the source HS
    reg [10:0] h_start  = 11'd300;// learned hblank-fall position
    reg [9:0]  vline    = 10'h3FF;// source line index since VS (saturates)
    reg [9:0]  wcount   = 0;      // pixels written this line
    reg        line_done = 0;     // this line already emitted
    reg        line_blank = 0;    // emitting a vblank (black) line
    reg        fast_cur = 0, fast_next = 0, decim = 0;
    reg        new_px_d = 0;
    reg        vs_pend  = 0;
    reg [1:0]  hs_dly   = 0;      // HS goes out 3 clocks after VS
    reg        hs_pend  = 0;

    reg [20:0] wd = 0;            // clk_vid cycles since the last source VS
    reg [10:0] fh = 0;            // fallback raster counters
    reg [8:0]  fv = 0;
    reg        fb_exit = 0;       // console sync is back; leave at the frame boundary

    wire in_window = (vline >= V_START) && (vline < V_START + V_LINES);

    always @(posedge clk_vid) begin
        video_vs   <= 1'b0;
        video_hs   <= 1'b0;
        video_de   <= 1'b0;
        video_skip <= 1'b0;
        video_rgb  <= 24'h0;
        new_px_d   <= new_px;

        hcnt <= (hcnt == 11'h7FF) ? hcnt : hcnt + 1'b1;

        // ---- sync ----
        if (vs_rise) vs_pend <= 1'b1;
        if (hs_rise) begin
            hcnt      <= 0;
            line_done <= 1'b0;
            fast_cur  <= fast_next;
            fast_next <= 1'b0;
            if (vs_pend) begin
                // New frame: VS now, HS three clocks later, as core-template does.
                vs_pend  <= 1'b0;
                vline    <= 0;
                hs_dly   <= 2'd3;
            end else begin
                vline    <= (vline == 10'h3FF) ? vline : vline + 1'b1;
                hs_pend  <= 1'b1;
            end
        end
        if (hs_dly != 0) begin
            hs_dly <= hs_dly - 1'b1;
            if (hs_dly == 2'd3) video_vs <= 1'b1;
            if (hs_dly == 2'd1) hs_pend  <= 1'b1;
        end
        // HS never while DE is high: hold it until the line has finished.
        if (hs_pend && st == IDLE && hs_dly == 0) begin
            video_hs <= 1'b1;
            hs_pend  <= 1'b0;
        end

        // /1 pixel mode shows up as new pixels on consecutive clocks.
        if (~s_hbl && new_px && new_px_d) fast_next <= 1'b1;

        // learn where active video starts, from real lines
        if (hbl_fall && ~s_vbl) h_start <= hcnt;

        // ---- line state machine ----
        case (st)
        IDLE: begin
            if (in_window && ~line_done && ~hs_pend && hs_dly == 0) begin
                if (~s_vbl && hbl_fall) begin
                    st <= ACTIVE; line_blank <= 1'b0;
                    wcount <= 0; decim <= 1'b0; line_done <= 1'b1;
                end else if (s_vbl && hcnt == h_start) begin
                    st <= PAD; line_blank <= 1'b1;
                    wcount <= 0; line_done <= 1'b1;
                end
            end
        end
        ACTIVE: begin
            video_de <= 1'b1;
            if (s_hbl || hs_rise) begin
                // source line ended: pad the remainder (or stop on a new HS)
                video_skip <= 1'b1;
                st <= hs_rise ? IDLE : PAD;
            end else if (new_px && (~fast_cur || ~decim)) begin
                video_rgb <= s_px;
                wcount    <= wcount + 1'b1;
                if (wcount == H_PIXELS-1) st <= IDLE;
            end else begin
                video_skip <= 1'b1;
            end
            if (new_px) decim <= ~decim;
        end
        PAD: begin
            if (wcount < H_PIXELS && ~hs_rise) begin
                video_de <= 1'b1;
                wcount   <= wcount + 1'b1;
                if (wcount == H_PIXELS-1) st <= IDLE;
            end else begin
                st <= IDLE;
            end
        end
        default: st <= IDLE;
        endcase

        // ---- fallback raster ----
        // Watchdog on the source VS. 2^21 clk_vid = 79 ms, well over one
        // 16.7 ms field. Any source VS returns control to the console.
        // Leaving the fallback waits for the end of its current frame, so the
        // scaler never sees a short frame when the console starts up.
        if (vs_rise) begin
            wd <= 0;
            if (fallback) fb_exit <= 1'b1;
        end else if (~&wd) begin
            wd <= wd + 1'b1;
        end else begin
            fallback <= 1'b1;
            fb_exit  <= 1'b0;
        end
        fh <= (fh == 11'd1687) ? 11'd0 : fh + 1'b1;
        if (fh == 11'd1687) fv <= (fv == 9'd261) ? 9'd0 : fv + 1'b1;
        if (fallback && fb_exit && fv == 9'd0 && fh == 11'd0) begin
            // frame boundary: hand over; the next console VS starts a frame
            fallback   <= 1'b0;
            fb_exit    <= 1'b0;
            vs_pend    <= 1'b0;
            video_vs   <= 1'b0;
            video_hs   <= 1'b0;
            video_de   <= 1'b0;
            video_skip <= 1'b0;
            video_rgb  <= 24'h0;
        end else if (fallback) begin
            st         <= IDLE;
            vs_pend    <= 1'b0;
            hs_pend    <= 1'b0;
            hs_dly     <= 2'd0;
            video_vs   <= (fv == 9'd0 && fh == 11'd0);
            video_hs   <= (fh == 11'd3);
            video_de   <= (fh >= 11'd326) && (fh < 11'd326 + H_PIXELS) &&
                          (fv >= V_START) && (fv < V_START + V_LINES);
            video_skip <= 1'b0;
            video_rgb  <= 24'h0;
        end
    end

endmodule

`default_nettype wire
