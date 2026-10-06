// Unit test for target/pocket/jaguar_video.sv (v2: fixed raster + fallback).
//
// v2 converts the console's clock-enable video into a fixed raster the APF
// scaler accepts. The guarantees checked here, for all four clk_sys/clk_vid
// phase relationships (clk_vid is clk_sys/4 from the same PLL, phase unknown
// at design time) and for both console pixel rates:
//
//   1. every complete frame has exactly V_LINES lines, each exactly H_PIXELS
//      written pixels (DE && !skip) in ONE contiguous DE run;
//   2. VS and HS are single-clock pulses, and HS never occurs while DE is high;
//   3. RGB is 0 whenever DE is low (APF reads it as scaler commands then);
//   4. console pixels come out in order, and the padding after them is black;
//   5. at power-up the fallback raster obeys 1-3, and control passes to the
//      console at a frame boundary: no short or long frame at the handover.
//
// The geometry is shrunk (H_PIXELS 32, V_LINES 8) to keep the run short;
// the module is fully parameterised, so the same logic is exercised. The
// previous version of this bench tested v1's /1-/2 doubling behaviour and was
// left stale when v2 replaced it.
`timescale 1ns/1ps

module tb_jaguar_video;

    localparam real CLK_NS   = 9.40171;   // 106.363636 MHz
    localparam int  HPX      = 32;        // DUT H_PIXELS
    localparam int  VLN      = 8;         // DUT V_LINES
    localparam int  VST      = 2;         // DUT V_START
    // source raster, in xvclk periods (= clk_vid cycles) and lines
    localparam int  H_ACTIVE = 40;
    localparam int  H_TOTAL  = 64;
    localparam int  V_ACTIVE = 8;         // source lines 0..7 active: window lines 8-9 are vblank, emitted black
    localparam int  V_TOTAL  = 14;

    logic clk_sys = 0;
    always #(CLK_NS/2.0) clk_sys = ~clk_sys;

    int  phase;
    int  fails;

    // ---- clocks and console-side stimulus ----------------------------------
    logic [1:0] divcnt = 0;
    always @(posedge clk_sys) divcnt <= divcnt + 1;
    wire xvclk = (divcnt == 2'd3);

    logic clk_vid_r = 0;
    always @(posedge clk_sys)
        if (divcnt == phase[1:0]) clk_vid_r <= 1;
        else if (divcnt == ((phase[1:0] + 2) & 2'd3)) clk_vid_r <= 0;
    wire clk_vid = clk_vid_r;

    logic pix_half;                      // 1 = a console pixel every 2 xvclk
    logic halftog = 0;
    always @(posedge clk_sys) if (xvclk) halftog <= ~halftog;
    wire  vid_ce = pix_half ? (xvclk & halftog) : xvclk;

    logic [15:0] cnt = 16'd1;            // pixel value: {8'h80, cnt} is never 0
    logic hblank = 1, vblank = 1, vga_hs = 0, vga_vs = 0;
    logic run_src = 0;               // console video running
    logic chk_on  = 0;               // checker active

    // ---- DUT ---------------------------------------------------------------
    wire [23:0] video_rgb;
    wire        video_de, video_skip, video_hs, video_vs, fallback;

jaguar_video #(.PIPE(2), .H_PIXELS(HPX), .V_LINES(VLN), .V_START(VST)) dut (
    .clk_sys(clk_sys), .vid_ce(vid_ce),
    .vga_r(8'h80), .vga_g(cnt[15:8]), .vga_b(cnt[7:0]),
    .vga_hs(vga_hs), .vga_vs(vga_vs),
    .hblank(hblank), .vblank(vblank),
    .clk_vid(clk_vid),
    .video_rgb(video_rgb), .video_de(video_de), .video_skip(video_skip),
    .video_hs(video_hs), .video_vs(video_vs), .fallback(fallback)
);

    // source raster in the xvclk CE domain; VS at the start of line 0
    always begin
        @(posedge clk_sys iff (xvclk && run_src));
        begin : step
            static int x = 0, y = 0;
            hblank <= (x >= H_ACTIVE);
            vblank <= (y >= V_ACTIVE);
            vga_hs <= (x == H_TOTAL - 4);                 // late in the line, after DE completes
            vga_vs <= (y == V_TOTAL - 1) && (x >= H_ACTIVE + 4) && (x < H_ACTIVE + 12);
            if (x < H_ACTIVE && y < V_ACTIVE && vid_ce) cnt <= cnt + 1'b1;
            x = x + 1;
            if (x == H_TOTAL) begin x = 0; y = (y + 1) % V_TOTAL; end
        end
    end

    // ---- checker, sampling outputs on the falling edge of clk_vid ----------
    int  frames_ok = 0, frames_bad = 0, fb_frames = 0, con_frames = 0, rule_bad = 0, content_bad = 0;
    bit  frame_open;
    int  runs, cur_written, bad_widths;
    bit  in_run, prev_vs, prev_hs, frame_fb, frame_seen_fb_to_con;
    logic [15:0] last_val;
    bit  padding;

    task automatic close_frame();
        if (!frame_open) return;
        if (runs == VLN && bad_widths == 0) begin
            frames_ok++;
            if (frame_fb) fb_frames++; else con_frames++;
        end else begin
            frames_bad++;
            if (frames_bad <= 4)
                $display("    bad frame: %0d lines (want %0d), %0d with wrong width, fallback=%0b",
                         runs, VLN, bad_widths, frame_fb);
        end
    endtask

    always @(negedge clk_vid) if (chk_on) begin
        // rule 2: single-clock syncs, no HS during DE
        if (video_vs && prev_vs) rule_bad++;
        if (video_hs && prev_hs) rule_bad++;
        if (video_hs && video_de) rule_bad++;
        // rule 3: black outside DE
        if (!video_de && video_rgb != 24'h0) rule_bad++;
        prev_vs = video_vs; prev_hs = video_hs;

        if (video_vs) begin
            close_frame();
            frame_open = 1; frame_fb = fallback; runs = 0; bad_widths = 0; in_run = 0;
        end
        if (video_de && !in_run) begin
            in_run = 1; cur_written = 0; padding = 0; last_val = 16'hFFFF;
        end
        if (video_de && !video_skip) begin
            cur_written++;
            // rule 4 (console frames): ascending pixels, then black padding
            if (!frame_fb) begin
                if (video_rgb == 24'h0) padding = 1;
                else if (padding) content_bad++;                      // pixel after padding
                else if (video_rgb[23:16] != 8'h80) content_bad++;
                else begin
                    if (last_val != 16'hFFFF &&
                        video_rgb[15:0] != last_val + 16'd1 && video_rgb[15:0] != last_val + 16'd2)
                        content_bad++;                                // out of order (decimation skips 1)
                    last_val = video_rgb[15:0];
                end
            end
        end
        if (!video_de && in_run) begin
            in_run = 0;
            if (frame_open) begin
                runs++;
                if (cur_written != HPX) bad_widths++;
            end
        end
    end

    localparam int FB_FRAME = 1688 * 262;   // fallback raster, clk_vid per frame
    task automatic check(input string label, input bit half, input int ph);
        bit ok;
        int f0, b0, fb0, c0, r0, n0;
        phase = ph; pix_half = half;
        // Restart in fallback with the console silent, as at power-up; the
        // DUT's own watchdog is what normally gets it here.
        run_src = 0; chk_on = 0;
        force dut.fallback = 1'b1;  force dut.fb_exit = 1'b0;
        repeat (40) @(posedge clk_sys);
        release dut.fallback; release dut.fb_exit;
        f0 = frames_ok; b0 = frames_bad; fb0 = fb_frames; c0 = con_frames; r0 = rule_bad; n0 = content_bad;
        frame_open = 0; prev_vs = 0; prev_hs = 0; in_run = 0;
        chk_on = 1;
        // two and a half fallback frames with no console video ...
        repeat (4 * (FB_FRAME * 5 / 2)) @(posedge clk_sys);
        // ... then the console starts: handover at the next fallback frame
        // boundary, followed by many console frames
        run_src = 1;
        repeat (4 * (FB_FRAME + 40 * H_TOTAL * V_TOTAL)) @(posedge clk_sys);
        chk_on = 0; run_src = 0;
        f0 = frames_ok - f0;  b0 = frames_bad - b0;  fb0 = fb_frames - fb0;
        c0 = con_frames - c0; r0 = rule_bad - r0;    n0 = content_bad - n0;
        ok = (b0 == 0) && (r0 == 0) && (n0 == 0) && (fb0 >= 2) && (c0 >= 30);
        $display("  %-28s frames ok %0d (fallback %0d, console %0d), bad %0d, sync/black violations %0d, content %0d  %s",
                 label, f0, fb0, c0, b0, r0, n0, ok ? "PASS" : "FAIL");
        if (!ok) fails++;
    endtask

    initial begin
        fails = 0;
        $display("tb_jaguar_video: %0dx%0d raster from a %0dx%0d source", HPX, VLN, H_TOTAL, V_TOTAL);
        for (int ph = 0; ph < 4; ph++) check($sformatf("pixel every xvclk, phase %0d", ph), 0, ph);
        for (int ph = 0; ph < 4; ph++) check($sformatf("pixel every 2 xvclk, phase %0d", ph), 1, ph);
        if (fails == 0) $display("JAGUAR VIDEO: PASS");
        else            $display("JAGUAR VIDEO: %0d CONFIGURATION(S) FAILED", fails);
        $finish;
    end
endmodule
