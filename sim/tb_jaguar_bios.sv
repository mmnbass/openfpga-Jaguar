// Run the real Jaguar boot ROM in simulation.
//
// Needs a BIOS image, which is NOT in this repository. Supply it with
//   +bios=/path/to/jagboot.rom
//
// The image is PRELOADED into the SDRAM model rather than written through the
// loader, for two reasons: it is far faster than ~650k cycles of bus writes,
// and the model's bus-write path is known to corrupt data (see
// sim/sdram_model.sv). The loader path's byte order is covered separately by
// tb_jaguar_boot.
//
// The ch2 BIOS address mapping below is not guessed -- it was read out of
// sdram_dual.sv and then CONFIRMED against the addresses the controller
// actually drove when the loader wrote through the bus (bank 3, row 0x1F80,
// columns 0x201..0x203 for words 1..3).
`timescale 1ns/1ps

module tb_jaguar_bios;

    localparam real CLK_NS = 9.40171;          // 106.363636 MHz

    logic clk = 0;
    always #(CLK_NS/2.0) clk = ~clk;

    logic reset = 1;

    wire [12:0] dram_a;
    wire [1:0]  dram_ba, dram_dqm;
    wire [15:0] dram_dq;
    wire        dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n;
    wire [7:0]  vga_r, vga_g, vga_b;
    wire        vga_hs, vga_vs, jag_hblank, jag_vblank, vid_ce, interlaced;
    wire [15:0] aud_l, aud_r;

jaguar_top dut (
    .clk_sys(clk), .clk_ram(clk), .pll_locked(1'b1), .reset(reset),
    .cart_wr(1'b0), .cart_addr(25'd0), .cart_data(16'd0),
    .bios_wr(1'b0), .bios_addr(25'd0), .bios_data(16'd0),
    .download_active(1'b0),
    .dram_a(dram_a), .dram_ba(dram_ba), .dram_dq(dram_dq), .dram_dqm(dram_dqm),
    .dram_clk(dram_clk), .dram_cke(dram_cke), .dram_ras_n(dram_ras_n),
    .dram_cas_n(dram_cas_n), .dram_we_n(dram_we_n),
    .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b),
    .vga_hs(vga_hs), .vga_vs(vga_vs),
    .hblank(jag_hblank), .vblank(jag_vblank),
    .vid_ce(vid_ce), .interlaced(interlaced),
    .aud_l(aud_l), .aud_r(aud_r),
    .joystick_0(32'd0), .joystick_1(32'd0),
    .cache_a_sel(tb_ca), .cache_b_sel(tb_cb), .cache_c_sel(tb_cc), .cache_d_sel(tb_cd),
    .sram_cache_en(tb_sram_en), .sram_bist_en(tb_bist),
    .sram_a(sr_a), .sram_dq(sr_dq), .sram_oe_n(sr_oe_n), .sram_we_n(sr_we_n),
    .sram_ub_n(sr_ub_n), .sram_lb_n(sr_lb_n)
);

    // ---- cache region selection and the external SRAM --
    // +ca= +cb= (BRAM regions, default 0/1), +cc= +cd= (SRAM regions, default
    // 4/5), +sram=0|1 (default 0, i.e. the configuration every earlier run used).
    reg [2:0] tb_ca = 3'd0, tb_cb = 3'd1, tb_cc = 3'd4, tb_cd = 3'd5;
    reg       tb_sram_en = 1'b0;
    reg       tb_bist    = 1'b0;      // +bist: run the SRAM write self-test
    initial if ($test$plusargs("bist")) tb_bist = 1'b1;
    always @(posedge dut.dbg_sram_bist_done) $display("[%0d] SRAM self-test done: W1,W2,W3,W6 = %h  W2 wrong words = %0d",
                                                     cyc, dut.dbg_sram_bist_err, dut.dbg_sram_bist_w2);
    initial begin
        int v;
        if ($value$plusargs("ca=%d", v)) tb_ca = v[2:0];
        if ($value$plusargs("cb=%d", v)) tb_cb = v[2:0];
        if ($value$plusargs("cc=%d", v)) tb_cc = v[2:0];
        if ($value$plusargs("cd=%d", v)) tb_cd = v[2:0];
        if ($value$plusargs("sram=%d", v)) tb_sram_en = v[0];
        $display("caches: A=%0d B=%0d (BRAM)  C=%0d D=%0d (SRAM, %s)",
                 tb_ca, tb_cb, tb_cc, tb_cd, tb_sram_en ? "on" : "off");
    end
    wire [16:0] sr_a; wire [15:0] sr_dq; wire sr_oe_n, sr_we_n, sr_ub_n, sr_lb_n;
    // Async SRAM model: valid taa after the last address change (15 ns, faster
    // than the measured 19 ns pass), garbage before; writes on WE rising, per
    // byte lane. 128 Ki words, scrambled at power-up.
    reg  [15:0] sr_mem [0:131071];
    reg  [15:0] sr_q = 16'h0BAD;
    realtime    sr_tchg = 0;
    int         sr_nchg = 0;           // load-bearing: see tb_sram_probe
    // +sram_zero starts the SRAM at 0 like the SDRAM model: then any mismatch
    // is a lost or wrong write, not a read of never-written memory.
    initial foreach (sr_mem[i]) sr_mem[i] = $test$plusargs("sram_zero") ? 16'd0 : 16'(i * 40503 + 7);
    always @(sr_a) begin sr_tchg = $realtime; sr_nchg++; end
    always #0.5 sr_q = (($realtime - sr_tchg) >= 15.0) ? sr_mem[sr_a] : 16'h0BAD;
    // +sram_twp=<ns>: a WE-low pulse shorter than this is ignored, as a part
    // with that minimum write-pulse width might (the self-test must catch it).
    real     sr_twp = 0.0;
    realtime sr_wfall = 0;
    initial if (!$value$plusargs("sram_twp=%f", sr_twp)) sr_twp = 0.0;
    always @(negedge sr_we_n) sr_wfall = $realtime;
    always @(posedge sr_we_n) if (($realtime - sr_wfall) >= sr_twp) begin
        if (!sr_ub_n) sr_mem[sr_a][15:8] = sr_dq[15:8];
        if (!sr_lb_n) sr_mem[sr_a][7:0]  = sr_dq[7:0];
    end
    assign sr_dq = (!sr_oe_n && sr_we_n) ? sr_q : 16'bz;

    // Checker: every read served from the SRAM must equal the upper half the
    // SDRAM itself returns for that read (data_ready_delay1[0] = last beat).
    longint sc_hits = 0, sc_bad = 0, sc_chk = 0, sc_noq = 0, sc_dl_bad = 0, sc_dl_n = 0;
    longint sc_go = -1, sc_dl = -1;
    // At Tom's consumption deadline (8 clk after the read's dram_go_rd)
    // a hit read must select the SRAM copy -- the SDRAM's upper beats may not
    // have arrived. This is the check that matters; the last-beat check
    // below can trip on a legitimate write-after-read invalidation.
    always @(posedge clk) if (!reset) begin
        if (dut.ch1_reqr) sc_go = cyc;
        if (dut.ch1_req && dut.sram_hit) sc_dl = sc_go + 8;
        if (cyc == sc_dl) begin
            sc_dl_n++;
            if (!dut.sram_use_q) begin
                sc_dl_bad++;
                if (sc_dl_bad <= 10) $display("[%0d] DEADLINE: hit read not selecting SRAM copy, addr %05x", cyc, dut.sdram_addr);
            end
        end
    end
    bit     sc_pend = 0;
    always @(posedge clk) if (!reset) begin
        if (dut.ch1_req && dut.sram_hit) begin sc_hits++; sc_pend <= 1; end
        if (sc_pend && dut.sdram.data_ready_delay1[0]) sc_pend <= 0;
    end
    logic sc_last = 0;
    always @(posedge clk) begin
        sc_last <= sc_pend && dut.sdram.data_ready_delay1[0];
        if (sc_last) begin
            sc_chk++;
            // a hit means Tom was not stalled: the upper half must come from q
            if (!dut.sram_use_q) begin
                sc_noq++;
                if (sc_noq <= 3) $display("[%0d] (last beat) hit no longer selecting q, addr %05x", cyc, dut.sdram_addr);
            end
            if (dut.sram_q !== dut.ch1_dout[63:32]) begin
                sc_bad++;
                if (sc_bad <= 10)
                    $display("[%0d] SRAM CACHE MISMATCH addr %05x: sram %08x sdram %08x",
                             cyc, dut.sdram_addr, dut.sram_q, dut.ch1_dout[63:32]);
            end
        end
        if (cyc % (106364*250) == 0 && cyc > 0 && tb_sram_en)
            $display("  [%5d ms] SRAM cache: hits %0d checked %0d MISMATCHES %0d  at-deadline %0d BAD %0d  last-beat-no-q %0d  (dut: hits %0d fallbacks %0d qmax %0d disabled %0d)",
                     cyc / 106364, sc_hits, sc_chk, sc_bad, sc_dl_n, sc_dl_bad, sc_noq, dut.dbg_sram_hits, dut.dbg_sram_fallbacks,
                     dut.dbg_sram_qmax, dut.dbg_sram_disabled);
    end

sdram_model mem (
    .clk(dram_clk), .dq(dram_dq), .a(dram_a), .ba(dram_ba),
    .cs_n(1'b0), .ras_n(dram_ras_n), .cas_n(dram_cas_n), .we_n(dram_we_n)
);

    longint cyc = 0;   // 64-bit: a 32-bit int wraps at 20.2 s of clk_sys
    always @(posedge clk) cyc <= cyc + 1;

    // ---- the real APF video path -------------------------------------------
    // clk_vid is clk_sys/4 as a genuine divided clock (26.590909 MHz).
    logic [1:0] viddiv = 0;
    logic       clk_vid = 0;
    always @(posedge clk) begin
        viddiv <= viddiv + 1;
        if (viddiv == 2'd0) clk_vid <= 1;
        else if (viddiv == 2'd2) clk_vid <= 0;
    end

    wire [23:0] video_rgb;
    wire        video_de, video_skip, video_hs, video_vs, jv_fallback;

jaguar_video #(.PIPE(2)) jv (
    .clk_sys(clk), .vid_ce(vid_ce),
    .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b),
    .vga_hs(vga_hs), .vga_vs(vga_vs),
    .hblank(jag_hblank), .vblank(jag_vblank),
    .clk_vid(clk_vid),
    .video_rgb(video_rgb), .video_de(video_de), .video_skip(video_skip),
    .video_hs(video_hs), .video_vs(video_vs), .fallback(jv_fallback)
);

    // ---- 1. SOURCE timing, seen through jv's own counters --------------------
    // Where Tom puts active video relative to VS/HS: this is what V_START and
    // the horizontal handling have to fit around.
    int src_first = 9999, src_last = 0, src_lines_max = 0;
    int src_hstart_min = 9999, src_hstart_max = 0, src_hend_min = 9999, src_hend_max = 0;
    int src_px_min = 99999, src_px_max = 0, src_px = 0, src_hs_hcnt = 0;
    always @(posedge clk_vid) if (!reset && cyc > 2_000_000) begin
        if (jv.hbl_fall && !jv.s_vbl) begin
            if (jv.vline < src_first) src_first = jv.vline;
            if (jv.vline != 1023 && int'(jv.vline) > src_last) src_last = jv.vline;
            if (jv.hcnt < src_hstart_min) src_hstart_min = jv.hcnt;
            if (jv.hcnt > src_hstart_max) src_hstart_max = jv.hcnt;
            src_px = 0;
        end
        if (!jv.s_hbl && !jv.s_vbl && jv.new_px) src_px++;
        if (jv.s_hbl && !jv.p_hbl && !jv.s_vbl) begin
            if (jv.hcnt < src_hend_min) src_hend_min = jv.hcnt;
            if (jv.hcnt > src_hend_max) src_hend_max = jv.hcnt;
            if (src_px > 0 && src_px < src_px_min) src_px_min = src_px;
            if (src_px > src_px_max) src_px_max = src_px;
        end
        if (jv.hs_rise && jv.vline != 1023 && jv.vline + 1 > src_lines_max) src_lines_max = jv.vline + 1;
        if (jv.hs_rise) src_hs_hcnt = jv.hcnt;
    end

    // ---- 2. APF RULE CHECKS on what leaves jaguar_video ----------------------
    int  wr_line = 0, lines_frame = 0, frames = 0;
    int  w_min = 99999, w_max = 0, h_min = 99999, h_max = 0;
    int  err_sync_in_de = 0, err_rgb_when_idle = 0, err_hs_wide = 0, err_vs_wide = 0;
    logic pv_de = 0, pv_hs = 0, pv_vs = 0;
    always @(posedge clk_vid) if (!reset) begin
        if (video_de && !video_skip) wr_line <= wr_line + 1;
        if (!video_de && pv_de) begin
            if (wr_line < w_min) w_min <= wr_line;
            if (wr_line > w_max) w_max <= wr_line;
            lines_frame <= lines_frame + 1;
            wr_line <= 0;
        end
        if (video_vs) begin
            if (frames > 0) begin
                if (lines_frame < h_min) h_min <= lines_frame;
                if (lines_frame > h_max) h_max <= lines_frame;
            end
            frames <= frames + 1;
            lines_frame <= 0;
        end
        if ((video_hs || video_vs) && video_de) err_sync_in_de++;
        if (!video_de && video_rgb != 0)        err_rgb_when_idle++;
        if (video_hs && pv_hs) err_hs_wide++;
        if (video_vs && pv_vs) err_vs_wide++;
        pv_de <= video_de; pv_hs <= video_hs; pv_vs <= video_vs;
    end

    // ---- 3. POCKET SCALER MODEL: render what the screen would show ------------
    // VS starts a frame; each DE run is one row; a pixel lands only when
    // DE && !skip. Anything past 640x240 is dropped, as a fixed buffer would.
    logic [23:0] apf_fb [0:240*640-1];
    int  sx = 0, sy = 0, apf_from_ms = 0, apf_dumped = 0, apf_max = 4, apf_stride = 1, apf_vs = 0;
    initial begin
        if (!$value$plusargs("apf_stride=%d", apf_stride)) apf_stride = 1;
        if (!$value$plusargs("apf_from_ms=%d", apf_from_ms)) apf_from_ms = 0;
        if (!$value$plusargs("apf_frames=%d", apf_max))      apf_max = 4;
    end
    task automatic dump_apf(input int idx);
        int fd; string path;
        path = $sformatf("apf_%02d_%05dms.ppm", idx, int'(cyc / 106364));
        fd = $fopen(path, "wb");
        $fwrite(fd, "P6\n640 240\n255\n");
        for (int k = 0; k < 240*640; k++)
            $fwrite(fd, "%c%c%c", apf_fb[k][23:16], apf_fb[k][15:8], apf_fb[k][7:0]);
        $fclose(fd);
        $display("  wrote %s (rows seen last frame: %0d)", path, sy);
    endtask
    always @(posedge clk_vid) if (!reset) begin
        if (video_vs) begin
            if (apf_from_ms > 0 && cyc > longint'(apf_from_ms) * 106364 && apf_dumped < apf_max) begin
                if (apf_vs % apf_stride == 0) begin
                    dump_apf(apf_dumped);
                    apf_dumped++;
                end
                apf_vs++;
            end
            for (int k = 0; k < 240*640; k++) apf_fb[k] = 24'h202020;   // grey = never written
            sy = 0; sx = 0;
        end
        if (video_de && !video_skip) begin
            if (sx < 640 && sy < 240) apf_fb[sy*640 + sx] = video_rgb;
            sx++;
        end
        if (!video_de && pv_de) begin sy++; sx = 0; end
    end


    // ---- INPUT STABILITY at the moment sdram_dual consumes each input -------
    // In STATE_IDLE the controller reads raw request
    // strobes and addresses on the same clock ("trying to save one clock
    // cycle"). STA reports these paths from Tom/Jerry registers as single
    // cycle. For each consumption we record k = clocks the consumed value has
    // been stable (k=1: launched by the immediately preceding edge, i.e. truly
    // single-cycle). If k >= 2 always, a 2-cycle multicycle is functionally
    // justified for that input.
    typedef struct { logic [63:0] v; int last; int hist[6]; int n; } stab_t;
    stab_t st_caddr, st_addr, st_din, st_be, st_c2addr, st_c2din;
    task automatic stab_update(ref stab_t s, input logic [63:0] v);
        if (v !== s.v) begin s.v = v; s.last = cyc; end
    endtask
    task automatic stab_consume(ref stab_t s);
        int k; k = cyc - s.last + 1; s.n++;
        s.hist[(k > 5) ? 5 : k]++;
    endtask
    always @(posedge clk) if (!reset) begin
        // consumptions first (they see values launched by earlier edges)
        if (dut.sdram.ch1_act)  stab_consume(st_caddr);
        if (dut.sdram.ch1_reqr) stab_consume(st_addr);
        if (dut.sdram.ch1_reqw) begin stab_consume(st_din); stab_consume(st_be); end
        if (dut.sdram.ch2_req)  begin stab_consume(st_c2addr); stab_consume(st_c2din); end
        stab_update(st_caddr,  {51'd0, dut.sdram.ch1_caddr});
        stab_update(st_addr,   {56'd0, dut.sdram.ch1_addr});
        stab_update(st_din,    dut.sdram.ch1_din);
        stab_update(st_be,     {56'd0, dut.sdram.ch1_be});
        stab_update(st_c2addr, {41'd0, dut.sdram.ch2_addr});
        stab_update(st_c2din,  {48'd0, dut.sdram.ch2_din});
    end
    task automatic stab_report_one(string name, stab_t s);
        $display("  %-26s n=%9d  k=1:%9d  k=2:%9d  k=3:%9d  k=4:%9d  k>=5:%9d",
                 name, s.n, s.hist[1], s.hist[2], s.hist[3], s.hist[4], s.hist[5]);
    endtask
    task automatic report_stability();
        $display("");
        $display("====== SDRAM INPUT STABILITY AT CONSUMPTION (clk_sys cycles) ======");
        stab_report_one("ch1_act  -> ch1_caddr",  st_caddr);
        stab_report_one("ch1_reqr -> ch1_addr",   st_addr);
        stab_report_one("ch1_reqw -> ch1_din",    st_din);
        stab_report_one("ch1_reqw -> ch1_be",     st_be);
        stab_report_one("ch2_req  -> ch2_addr",   st_c2addr);
        stab_report_one("ch2_req  -> ch2_din",    st_c2din);
        $display("===================================================================");
    endtask


    // ---- FAILING-PATH SOURCE REGISTERS ----------------
    // For each register STA names as the source of a failing SDRAM/wrapper
    // path: how often it changes, and the fewest clocks between a change and
    // the next controller consumption event (any request strobe). min_gap >= 2
    // on every event means the 1-cycle STA requirement is never exercised.
    typedef struct { logic [63:0] v; int last; int changes; int min_gap; } src_t;
    src_t sr[12];
    string sr_name[12] = '{"tom abus dwid0","tom abus dwid1","tom abus cols0","tom abus aouti",
                           "tom abus cpu32_obuf","tom memwidth maskai","jerry jbus dsp16_",
                           "jerry jmisc joyen","m68k w158","jaguar xresetl","tom mem q7a","(unused)"};
    initial for (int i = 0; i < 12; i++) begin sr[i].last = -1000; sr[i].min_gap = 1 << 30; sr[i].changes = 0; end
    wire any_consume = dut.sdram.ch1_act | dut.sdram.ch1_reqr | dut.sdram.ch1_reqw |
                       dut.sdram.ch1_ref | dut.sdram.ch1_pch | dut.sdram.ch2_req;
    always @(posedge clk) if (!reset) begin
        logic [63:0] cur [11];
        cur[0]  = dut.jaguar_inst.tom_inst.abus_inst.dwid0;
        cur[1]  = dut.jaguar_inst.tom_inst.abus_inst.dwid1;
        cur[2]  = dut.jaguar_inst.tom_inst.abus_inst.cols0;
        cur[3]  = dut.jaguar_inst.tom_inst.abus_inst.aouti;
        cur[4]  = dut.jaguar_inst.tom_inst.abus_inst.cpu32_obuf;
        cur[5]  = dut.jaguar_inst.tom_inst.mem_inst.mw_inst.maskai;
        cur[6]  = dut.jaguar_inst.jerry_inst.jbus_inst.dsp16_;
        cur[7]  = dut.jaguar_inst.jerry_inst.jmisc_inst.joyen;
        cur[8]  = dut.jaguar_inst.m68k_inst.w158;
        cur[9]  = dut.jaguar_inst.xresetl;
        cur[10] = dut.jaguar_inst.tom_inst.mem_inst.q7a;
        for (int i = 0; i < 11; i++) begin
            if (any_consume && (cyc - sr[i].last + 1) < sr[i].min_gap) sr[i].min_gap = cyc - sr[i].last + 1;
            if (cur[i] !== sr[i].v) begin
                if (cyc > 20) sr[i].changes++;
                sr[i].v = cur[i]; sr[i].last = cyc;
            end
        end
    end
    task automatic report_sources();
        $display("");
        $display("====== FAILING-PATH SOURCES: change count / min clocks change->consume ======");
        for (int i = 0; i < 11; i++)
            $display("  %-22s changes %10d   min_gap %0d", sr_name[i], sr[i].changes, sr[i].min_gap);
        $display("==============================================================================");
    endtask

    logic jv_fb_old = 1;
    always @(posedge clk_vid) begin
        if (jv_fb_old && !jv_fallback) $display("[%0d ms] jaguar_video: fallback raster -> console video", cyc / 106364);
        if (!jv_fb_old && jv_fallback) $display("[%0d ms] jaguar_video: console video LOST -> fallback raster", cyc / 106364);
        jv_fb_old <= jv_fallback;
    end
    task automatic report_apf_video();
        $display("");
        $display("====== SOURCE (Tom) timing, relative to VS / HS ======");
        $display("  lines per frame (HS per VS)  : %0d", src_lines_max);
        $display("  first / last active line     : %0d / %0d  (%0d lines)", src_first, src_last, src_last-src_first+1);
        $display("  hblank falls at hcnt         : %0d .. %0d", src_hstart_min, src_hstart_max);
        $display("  hblank rises at hcnt         : %0d .. %0d", src_hend_min, src_hend_max);
        $display("  console pixels per line      : %0d .. %0d", src_px_min, src_px_max);
        $display("  jv V_START                   : %0d", jv.V_START);
        $display("====== WHAT APF RECEIVES (jaguar_video v2) ======");
        $display("  VS pulses                    : %0d", frames);
        $display("  written pixels per DE line   : %0d .. %0d   (want 640)", w_min, w_max);
        $display("  DE lines per frame           : %0d .. %0d   (want 240)", h_min, h_max);
        $display("  HS/VS while DE               : %0d   (want 0)", err_sync_in_de);
        $display("  rgb != 0 while DE low        : %0d   (want 0)", err_rgb_when_idle);
        $display("  HS / VS wider than 1 clock   : %0d / %0d   (want 0)", err_hs_wide, err_vs_wide);
        if (w_min == 640 && w_max == 640 && h_min == 240 && h_max == 240 &&
            err_sync_in_de == 0 && err_rgb_when_idle == 0 && err_hs_wide == 0 && err_vs_wide == 0)
            $display("  APF VIDEO: PASS");
        else
            $display("  APF VIDEO: FAIL");
        $display("=================================================");
    endtask

    // ---- BIOS preload ------------------------------------------------------
    // ch2 BIOS address = word_index | 0x7F0000 with addr_ext = 1, which the
    // controller maps to: bank 3, row {3'b111, 3'b111, wi[15:9]},
    // column {1'b1, wi[8:0]}.
    int bios_words = 0;
    task automatic load_bios(input string path);
        int fd, n;
        logic [7:0] hi, lo;
        logic [15:0] wi;
        fd = $fopen(path, "rb");
        if (fd == 0) begin
            $display("ERROR: cannot open BIOS image '%s'", path);
            $display("       pass it with +bios=/path/to/jagboot.rom");
            $finish;
        end
        wi = 0;
        forever begin
            n = $fgetc(fd); if (n < 0) break; hi = n[7:0];
            n = $fgetc(fd); if (n < 0) break; lo = n[7:0];
            // big-endian 68000 word, as the file stores it
            mem.preload(2'b11, {6'b111111, wi[15:9]}, {1'b1, wi[8:0]}, {hi, lo});
            bios_words++;
            wi++;
            if (wi == 0) break;            // 64K words = 128 KB
        end
        $fclose(fd);
        $display("loaded %0d BIOS words (%0d bytes)", bios_words, bios_words*2);
    endtask

    // ---- observation -------------------------------------------------------
    int hs_edges = 0, vs_edges = 0, vidce = 0, os_sel = 0, ras = 0;
    // Did the CPU ever fetch in the 0xE00000 BIOS window?
    int hit_e0 = 0;
    int de_pixels = 0, nonblack = 0;
    logic ph = 0, pv = 0, pr = 1, po = 1;
    logic [23:0] first_abus = 24'hFFFFFF;
    int  abus_seen = 0;

    always @(posedge clk) if (!reset) begin
        if (dut.abus_out[23:20] == 4'hE) hit_e0++;
        if ( vga_hs && !ph) hs_edges++;
        if ( vga_vs && !pv) vs_edges++;
        if (vid_ce) begin
            vidce++;
            if (!jag_hblank && !jag_vblank) begin
                de_pixels++;
                if (|{vga_r, vga_g, vga_b}) nonblack++;
            end
        end
        if (!dram_ras_n && pr) ras++;
        if (!dut.os_ce_n && po) begin
            os_sel++;
            if (abus_seen == 0) begin first_abus = dut.abus_out; abus_seen = 1; end
        end
        ph <= vga_hs; pv <= vga_vs; pr <= dram_ras_n; po <= dut.os_ce_n;
    end

`ifdef DQ_DEBUG
    // Is the CONTROLLER driving the wrong value, or is the bus resolution
    // wrong? Print its intended DQ next to what the model sees.
    int dbg = 0;
    always @(posedge dram_clk) begin
        if (!dram_cas_n && !dram_we_n && dbg < 12) begin
            $display("[dq] ctrl_drives=%04x  bus=%04x  %s",
                     dut.sdram.SDRAM_DQ, dram_dq,
                     (dut.sdram.SDRAM_DQ === dram_dq) ? "match" : "MISMATCH");
            dbg++;
        end
    end
`endif

    // Where is it executing? Sample the address bus periodically; a tight loop
    // shows up as a narrow repeating range.
    int  trace_n = 0;
    always @(posedge clk) if (!reset) begin
        trace_n++;
        if (trace_n % 1064000 == 0)       // ~ every 10 ms
            $display("  [%2d ms] abus=%06x  os_ce_n=%b  hblank=%b vblank=%b  vmode_hs=%b",
                     trace_n / 106400, dut.abus_out, dut.os_ce_n,
                     jag_hblank, jag_vblank, vga_hs);
    end

`ifdef READ_DEBUG
    // Are BIOS reads returning data or zeros? This is the question that
    // distinguishes "the preload address is wrong" from "the core is broken".
    int rdbg = 0;
    // The BIOS chip select is romcsl_0 = rom[1] & rom[2] & rom[7] (active low),
    // with rom[7] the pre-MEMCON mirror that answers at ANY address while
    // mset=0, and rom[2] the 0xE00000 window that needs romhi. If mset is
    // already 1 at reset, the mirror never exists, 0xE00008 is undecoded, and
    // the 68000 bus-errors straight back into the vector table -- which is
    // exactly the observed loop. Measure it.
    logic p_mset = 1'bx, p_romhi = 1'bx, p_cfgen = 1'bx;
    int   cfgdbg = 0;
    always @(posedge clk) if (!reset) begin
        if (cfgdbg < 16 &&
            (dut.jaguar_inst.tom_inst.abus_inst.mset   !== p_mset ||
             dut.jaguar_inst.tom_inst.abus_inst.romhi  !== p_romhi ||
             dut.jaguar_inst.tom_inst.abus_inst.cfgen  !== p_cfgen)) begin
            $display("  [cfg] cyc=%0d mset=%b romhi=%b romlo=%b cfgen=%b memc1w=%b abus=%06x",
                     cyc,
                     dut.jaguar_inst.tom_inst.abus_inst.mset,
                     dut.jaguar_inst.tom_inst.abus_inst.romhi,
                     dut.jaguar_inst.tom_inst.abus_inst.romlo,
                     dut.jaguar_inst.tom_inst.abus_inst.cfgen,
                     dut.jaguar_inst.tom_inst.abus_inst.memc1w,
                     dut.abus_out);
            p_mset  <= dut.jaguar_inst.tom_inst.abus_inst.mset;
            p_romhi <= dut.jaguar_inst.tom_inst.abus_inst.romhi;
            p_cfgen <= dut.jaguar_inst.tom_inst.abus_inst.cfgen;
            cfgdbg++;
        end
    end

    // Is the 68000 being held or repeatedly reset?
    logic p_xresetl = 1'bx, p_rst = 1'bx, p_halt = 1'bx;
    int   rstdbg = 0;
    always @(posedge clk) if (!reset && rstdbg < 20) begin
        if (dut.jaguar_inst.xresetl !== p_xresetl
         || dut.jaguar_inst.fx68k_rst !== p_rst
         || dut.jaguar_inst.fx68k_halt !== p_halt) begin
            $display("  [rst] cyc=%0d xresetl=%b fx68k_rst=%b fx68k_halt=%b j_xresetl=%b",
                     cyc, dut.jaguar_inst.xresetl, dut.jaguar_inst.fx68k_rst,
                     dut.jaguar_inst.fx68k_halt, dut.jaguar_inst.j_xresetl);
            p_xresetl <= dut.jaguar_inst.xresetl;
            p_rst     <= dut.jaguar_inst.fx68k_rst;
            p_halt    <= dut.jaguar_inst.fx68k_halt;
            rstdbg++;
        end
    end

    // Trace the execution ADDRESS sequence: where does it leave the BIOS?
    logic [23:0] prev_abus = 24'hFFFFFF;
    always @(posedge clk) if (!reset && rdbg < 60) begin
        if (dut.abus_out !== prev_abus) begin
            $display("  [pc] cyc=%0d abus=%06x os_ce_n=%b cart_ce_n=%b qsc=%08x",
                     cyc, dut.abus_out, dut.os_ce_n, dut.cart_ce_n, dut.cart_qsc);
            prev_abus <= dut.abus_out;
            rdbg++;
        end
    end
`endif

    // ---- stall attribution -------------------------------------------------
    // Is the 3-4x throughput shortfall bandwidth (SDRAM saturated) or clocking
    // (the 68000 not being clocked at its expected 13.295 MHz)? Those point at
    // completely different fixes, so measure both.
    longint c_total, c_ramrdy_low, c_sdram_cmd, c_xvclk, c_m68kclk;
    longint n_ch1r, n_ch1w, n_ch1ref, n_ch2req, n_osrd, n_cartrd;
    logic   p_m68k = 0;

    wire sdram_cmd_active = ({dram_ras_n, dram_cas_n, dram_we_n} != 3'b111);

    always @(posedge clk) if (!reset) begin
        c_total++;
        if (!dut.ram_rdy)            c_ramrdy_low++;
        if (sdram_cmd_active)        c_sdram_cmd++;
        if (dut.jaguar_inst.xvclk)   c_xvclk++;
        if (dut.m68k_clk && !p_m68k) c_m68kclk++;
        if (dut.ch1_reqr)            n_ch1r++;
        if (dut.ch1_reqw)            n_ch1w++;
        if (dut.ch1_ref)             n_ch1ref++;
        if (dut.cart_ch2_req)        n_ch2req++;
        if (dut.os_rd_trig)          n_osrd++;
        if (dut.cart_rd_trig)        n_cartrd++;
        p_m68k <= dut.m68k_clk;
    end

    task automatic report_stalls();
        real ms;
        ms = c_total * CLK_NS / 1.0e6;
        $display("");
        $display("=========== STALL ATTRIBUTION over %.2f ms ===========", ms);
        $display("  clk_sys cycles            : %0d", c_total);
        $display("  xvclk pulses              : %0d  (%.0f/ms, expect 26591)",
                 c_xvclk, c_xvclk/ms);
        $display("  m68k_clk rising edges     : %0d  (%.0f/ms, expect 13295)",
                 c_m68kclk, c_m68kclk/ms);
        $display("");
        $display("  ram_rdy LOW               : %0d cycles  (%.1f%% -- Tom stalled by the kludge)",
                 c_ramrdy_low, 100.0*c_ramrdy_low/c_total);
        $display("  SDRAM command cycles      : %0d  (%.1f%% of cycles issue a command)",
                 c_sdram_cmd, 100.0*c_sdram_cmd/c_total);
        $display("");
        $display("  ch1 read requests         : %0d  (%.0f/ms)", n_ch1r, n_ch1r/ms);
        $display("  ch1 write requests        : %0d  (%.0f/ms)", n_ch1w, n_ch1w/ms);
        $display("  ch1 refresh requests      : %0d  (%.0f/ms)", n_ch1ref, n_ch1ref/ms);
        $display("  ch2 requests (ROM/BIOS)   : %0d  (%.0f/ms)", n_ch2req, n_ch2req/ms);
        $display("    of which BIOS reads     : %0d", n_osrd);
        $display("    of which cart reads     : %0d", n_cartrd);
        $display("=====================================================");
        $display("");
        if (c_m68kclk < 0.9 * 13295.0 * ms)
            $display("VERDICT: the 68000 is NOT being clocked at 13.295 MHz --");
        else
            $display("VERDICT: the 68000 IS clocked at ~13.295 MHz, so each bus");
        $display("         cycle is taking too many clocks, i.e. memory latency.");
        if (100.0*c_sdram_cmd/c_total < 15.0)
            $display("         SDRAM is mostly IDLE (%.1f%% command cycles), so raw",
                     100.0*c_sdram_cmd/c_total);
        else
            $display("         SDRAM is BUSY (%.1f%% command cycles), so bandwidth",
                     100.0*c_sdram_cmd/c_total);
        $display("");
    endtask

    // ---- ROM-cycle lateness ----------------------------
    // Tom's xwaitl is tied high, so a cart/BIOS ROM cycle ends after the fixed
    // ROMSPEED wait states whether or not SDRAM ch2 has delivered. Track each
    // ch2 read from its trigger to data_ready_delay2[0]; a ROM cycle that ends
    // (Tom mem q8b falls) while the read is still outstanding latched stale data.
    bit     rp_pend = 0;
    longint rp_t0, rp_lat, rp_max = 0, rp_n = 0, rp_late = 0, rp_over = 0;
    longint rp_h [0:7];
    logic   rp_q8b = 0;
    initial foreach (rp_h[i]) rp_h[i] = 0;
    always @(posedge clk) if (!reset) begin
        rp_q8b <= dut.jaguar_inst.tom_inst.mem_inst.q8b;
        if (rp_pend && dut.sdram.data_ready_delay2[0]) begin
            rp_lat = cyc - rp_t0;
            if (rp_lat > rp_max) rp_max = rp_lat;
            rp_h[(rp_lat >= 35) ? 7 : rp_lat / 5]++;
            rp_pend <= 0;
        end else if (rp_pend && rp_q8b && !dut.jaguar_inst.tom_inst.mem_inst.q8b)
            rp_late++;
        if (dut.os_rd_trig | dut.cart_rd_trig) begin
            if (rp_pend && !dut.sdram.data_ready_delay2[0]) rp_over++;
            rp_pend <= 1; rp_t0 = cyc; rp_n++;
        end
        if (cyc % (106364*250) == 0)
            $display("  [%5d ms] ROM reads %0d  LATE %0d  overrun %0d  max latency %0d clk  hist(5clk) %0d %0d %0d %0d %0d %0d %0d %0d",
                     cyc / 106364, rp_n, rp_late, rp_over, rp_max,
                     rp_h[0], rp_h[1], rp_h[2], rp_h[3], rp_h[4], rp_h[5], rp_h[6], rp_h[7]);
        if (cyc % (106364*250) == 0)
            $display("  [%5d ms] overlay probe: maxlat %0d  mincyc %0d  late %0d",
                     cyc / 106364, dut.dbg_rom_maxlat, dut.dbg_rom_mincyc, dut.dbg_rom_late);
    end

    // ---- Stage B design inputs -------------------------
    // (a) gaps between Tom DRAM writes (ch1_reqw): how fast must the SRAM
    //     write-through drain? (b) clocks from a read's dram_go_rd (ch1_reqr)
    //     to its CAS edge (ch1_req): how early does the SRAM read start?
    longint sb_lastw = -1, sb_lastr = -1, sb_wmin = 1000000, sb_nw = 0, sb_nr = 0, sb_norq = 0;
    longint sb_wgap [0:16];
    longint sb_rq   [0:16];
    initial begin foreach (sb_wgap[i]) sb_wgap[i] = 0; foreach (sb_rq[i]) sb_rq[i] = 0; end
    always @(posedge clk) if (!reset) begin
        if (dut.ch1_reqw) begin
            if (sb_lastw >= 0) begin
                if (cyc - sb_lastw < sb_wmin) sb_wmin = cyc - sb_lastw;
                sb_wgap[(cyc - sb_lastw > 16) ? 16 : cyc - sb_lastw]++;
            end
            sb_lastw = cyc; sb_nw++;
        end
        if (dut.ch1_reqr) sb_lastr = cyc;
        if (dut.ch1_req) begin
            sb_nr++;
            if (sb_lastr < 0 || cyc - sb_lastr > 16) sb_norq++;
            else sb_rq[cyc - sb_lastr]++;
        end
        if (cyc % (106364*250) == 0 && cyc > 0) begin
            $display("  [%5d ms] Tom writes %0d, min gap %0d clk; gaps 1..16+: %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                     cyc / 106364, sb_nw, sb_wmin, sb_wgap[1], sb_wgap[2], sb_wgap[3], sb_wgap[4], sb_wgap[5], sb_wgap[6],
                     sb_wgap[7], sb_wgap[8], sb_wgap[9], sb_wgap[10], sb_wgap[11], sb_wgap[12], sb_wgap[13], sb_wgap[14],
                     sb_wgap[15], sb_wgap[16]);
            $display("  [%5d ms] Tom reads %0d, go_rd->CAS clk 0..8: %0d %0d %0d %0d %0d %0d %0d %0d %0d; no go_rd within 16: %0d",
                     cyc / 106364, sb_nr, sb_rq[0], sb_rq[1], sb_rq[2], sb_rq[3], sb_rq[4], sb_rq[5], sb_rq[6], sb_rq[7], sb_rq[8], sb_norq);
        end
    end

    // ---- Tom DRAM speed (MEMCON1[6:5]) --------------------
    // +dspd=<0..3> forces it from reset; otherwise every change is printed.
    logic [1:0] dspd_p = 2'bxx;
    always @(posedge clk) begin
        if (dut.jaguar_inst.tom_inst.abus_inst.dspd_obuf !== dspd_p)
            $display("[%0d ms] Tom dspd (MEMCON1[6:5]) = %0d", cyc / 106364,
                     dut.jaguar_inst.tom_inst.abus_inst.dspd_obuf);
        dspd_p <= dut.jaguar_inst.tom_inst.abus_inst.dspd_obuf;
    end
    initial begin
        int v;
        if ($value$plusargs("dspd=%d", v)) begin
            force dut.jaguar_inst.tom_inst.abus_inst.dspd_obuf = v[1:0];
            $display("Tom dspd forced to %0d", v);
        end
    end

    // ---- SDRAM arrival vs Tom's deadline -----------------
    // For each read: A = clocks from dram_go_rd to the cycle the full 64-bit
    // word is valid (one after data_ready_delay1[0]). On time if A <= 8.
    // Split by I = clocks from go to the READ being issued (data_ready_delay1
    // bit 6 set): I = 1 means sdram_dual took the read at once.
    longint ar_go = -1, ar_iss = -1;
    bit     ar_idle = 0, ar_open = 0;
    longint ar_hi [0:20];
    initial foreach (ar_hi[i]) ar_hi[i] = 0;
    // Conditional stall: a read Tom was NOT stalled on and that no cache
    // served must have its full word by go + 8. Plus stall bookkeeping.
    bit     ar_unst = 0;
    longint cs_reads = 0, cs_stalls = 0, cs_late = 0, cs_unst = 0;
    longint ar_h_idle [0:20];
    longint ar_h_busy [0:20];
    initial begin foreach (ar_h_idle[i]) ar_h_idle[i] = 0; foreach (ar_h_busy[i]) ar_h_busy[i] = 0; end
    always @(posedge clk) if (!reset) begin
        if (dut.ch1_reqr) begin
            ar_go = cyc; ar_open = 1; ar_iss = -1;
        end
        if (ar_open && ar_iss < 0 && dut.sdram.data_ready_delay1[6]) begin
            ar_iss = cyc - ar_go;
            ar_hi[(ar_iss > 20) ? 20 : ar_iss]++;
            ar_idle = (ar_iss <= 1);
        end
        if (dut.ch1_req) begin
            cs_reads++;
            if (!dut.ram_rdy) cs_stalls++;
            ar_unst = dut.ram_rdy && !dut.use_fastram && !dut.sram_hit;
        end
        if (!dut.ch1_reqr && ar_open && dut.sdram.data_ready_delay1[0]) begin
            automatic longint a = cyc + 1 - ar_go;
            if (ar_unst) begin
                cs_unst++;
                if (a > 8) begin
                    cs_late++;
                    if (cs_late <= 10) $display("[%0d] LATE UNSTALLED READ: full word at go+%0d, addr %05x",
                                                cyc, a, dut.sdram_addr);
                end
            end
            if (a > 20) a = 20;
            if (ar_idle) ar_h_idle[a]++; else ar_h_busy[a]++;
            ar_open = 0;
        end
        if (cyc % (106364*250) == 0 && cyc > 0) begin
            $display("  [%5d ms] arrival A (idle at go), A=5..14: %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d  15+: %0d",
                cyc/106364, ar_h_idle[5], ar_h_idle[6], ar_h_idle[7], ar_h_idle[8], ar_h_idle[9], ar_h_idle[10],
                ar_h_idle[11], ar_h_idle[12], ar_h_idle[13], ar_h_idle[14],
                ar_h_idle[15]+ar_h_idle[16]+ar_h_idle[17]+ar_h_idle[18]+ar_h_idle[19]+ar_h_idle[20]);
            $display("  [%5d ms] Tom reads %0d, stalled %0d (%.1f%%); unstalled uncached %0d, LATE %0d",
                     cyc/106364, cs_reads, cs_stalls, 100.0*cs_stalls/(cs_reads ? cs_reads : 1), cs_unst, cs_late);
            $display("  [%5d ms] issue delay I=0..8: %0d %0d %0d %0d %0d %0d %0d %0d %0d  9+: %0d", cyc/106364,
                ar_hi[0], ar_hi[1], ar_hi[2], ar_hi[3], ar_hi[4], ar_hi[5], ar_hi[6], ar_hi[7], ar_hi[8],
                ar_hi[9]+ar_hi[10]+ar_hi[11]+ar_hi[12]+ar_hi[13]+ar_hi[14]+ar_hi[15]+ar_hi[16]+ar_hi[17]+ar_hi[18]+ar_hi[19]+ar_hi[20]);
            $display("  [%5d ms] arrival A (busy at go), A=5..14: %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d  15+: %0d",
                cyc/106364, ar_h_busy[5], ar_h_busy[6], ar_h_busy[7], ar_h_busy[8], ar_h_busy[9], ar_h_busy[10],
                ar_h_busy[11], ar_h_busy[12], ar_h_busy[13], ar_h_busy[14],
                ar_h_busy[15]+ar_h_busy[16]+ar_h_busy[17]+ar_h_busy[18]+ar_h_busy[19]+ar_h_busy[20]);
        end
    end

    // ---- read lanes of uncached reads -------------------
    // dram_oe_n[3:0] = which 16-bit lanes Tom reads. Lanes 0-1 = ch1_dout[31:0],
    // which lands at go+6 like the cached path; lanes 2-3 land at go+8.
    longint ln_n = 0, ln_lo = 0, ln_hi = 0, ln_ontime_lo = 0;
    longint ln_pat [0:15];
    initial foreach (ln_pat[i]) ln_pat[i] = 0;
    always @(posedge clk) if (!reset) begin
        if (dut.ch1_req && !dut.use_fastram) begin
            ln_n++;
            ln_pat[~dut.dram_oe_n]++;
            if ((~dut.dram_oe_n & 4'b1100) == 0) begin
                ln_lo++;
                if (dut.ch1_ontime) ln_ontime_lo++;
            end else ln_hi++;
        end
        if (cyc % (106364*250) == 0 && cyc > 0)
            $display("  [%5d ms] uncached reads %0d: lanes 0-1 only %0d (%.1f%%, on-time %0d), need lanes 2-3 %0d; oe patterns 1..F: %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                cyc/106364, ln_n, ln_lo, 100.0*ln_lo/(ln_n ? ln_n : 1), ln_ontime_lo, ln_hi,
                ln_pat[1], ln_pat[2], ln_pat[3], ln_pat[4], ln_pat[5], ln_pat[6], ln_pat[7], ln_pat[8],
                ln_pat[9], ln_pat[10], ln_pat[11], ln_pat[12], ln_pat[13], ln_pat[14], ln_pat[15]);
    end

    // ---- blitter load-path stability --------------------
    // The fast-corner failures concentrate on blitter registers loaded from
    // Tom's buses. For each load (enable high at an edge), count the edges
    // since the data input last changed: 1 = it changed in the previous cycle,
    // a genuinely single-cycle path; >= 2 = multicycle in practice.
    `define BLIT dut.jaguar_inst.tom_inst.gpu_inst.blit_inst
    longint st_h [0:3][1:6];
    longint st_last [0:3];
    logic [31:0] st_prev [0:3];
    initial foreach (st_h[i,j]) st_h[i][j] = 0;
    initial foreach (st_last[i]) st_last[i] = 0;
    function automatic logic [31:0] st_d(int i);
        case (i)
            0: st_d = `BLIT.data_inst.load_data_0;
            1: st_d = `BLIT.data_inst.load_data_0;
            2: st_d = {11'd0, `BLIT.address_inst.gpu_d_m21};
            default: st_d = {11'd0, `BLIT.address_inst.gpu_d_m21};
        endcase
    endfunction
    function automatic bit st_en(int i);
        case (i)
            0: st_en = `BLIT.data_inst.dstdldg[0];
            1: st_en = `BLIT.data_inst.dstzldg[0];
            2: st_en = `BLIT.address_inst.a1baseldg;
            default: st_en = `BLIT.address_inst.a2baseldg;
        endcase
    endfunction
    always @(posedge clk) if (!reset) begin
        for (int i = 0; i < 4; i++) begin
            automatic logic [31:0] d = st_d(i);
            if (st_en(i)) begin
                automatic longint n = (d !== st_prev[i]) ? 1 : (cyc - st_last[i] + 1);
                st_h[i][(n > 6) ? 6 : n]++;
            end
            if (d !== st_prev[i]) st_last[i] = cyc;
            st_prev[i] = d;
        end
        if (cyc % (106364*250) == 0 && cyc > 0)
            for (int i = 0; i < 4; i++)
                $display("  [%5d ms] blit load %s: edges since data change 1:%0d 2:%0d 3:%0d 4:%0d 5:%0d 6+:%0d",
                         cyc/106364, (i==0)?"dstd_0 ":(i==1)?"dstz_0 ":(i==2)?"a1_base":"a2_base",
                         st_h[i][1], st_h[i][2], st_h[i][3], st_h[i][4], st_h[i][5], st_h[i][6]);
    end

    // ---- self-selecting block cache checker -------------
    // For every read Tom is not stalled on because the block cache claims it:
    // capture the upper half Tom receives at its deadline (go + 8) and
    // compare with the SDRAM's own upper half when that read completes.
    longint bk_hits = 0, bk_bad = 0, bk_reads = 0, bk_go = -1, bk_dl = -1;
    logic [31:0] bk_seen = 0;
    bit     bk_pend = 0, bk_wait = 0;
    always @(posedge clk) if (!reset) begin
        if (dut.ch1_reqr) bk_go = cyc;
        if (dut.ch1_req) bk_reads++;
        if (dut.ch1_req && dut.use_fastram) begin bk_hits++; bk_dl = bk_go + 8; bk_pend = 1; end
        if (bk_pend && cyc == bk_dl) begin bk_seen = dut.dram_q[63:32]; bk_pend = 0; bk_wait = 1; end
        if (bk_wait && dut.ch1_rd_done) begin
            bk_wait = 0;
            if (bk_seen !== dut.ch1_dout[63:32]) begin
                bk_bad++;
                if (bk_bad <= 10) $display("[%0d] BLOCK CACHE MISMATCH addr %05x: Tom got %08x, SDRAM %08x",
                                            cyc, dut.sdram_addr, bk_seen, dut.ch1_dout[63:32]);
            end
        end
        if (cyc % (106364*250) == 0 && cyc > 0)
            $display("  [%5d ms] block cache: reads %0d, hits %0d (%.1f%%), MISMATCHES %0d, reassignments %0d, blocks %08x",
                     cyc/106364, bk_reads, bk_hits, 100.0*bk_hits/(bk_reads ? bk_reads : 1), bk_bad,
                     dut.dbg_reassign, dut.dbg_cached_blocks);
    end

    // ---- frame capture (re-armable) ----------------------------------------
    // Capturing ONE frame cannot distinguish "drawing is finished and the
    // output is incomplete" from "we caught it mid-draw". So make it
    // re-armable and take several consecutive frames.
    int  cap_ms, cap_frames;
    bit  cap_req = 0, cap_busy = 0, cap_valid = 0;
    int  cap_x = 0, cap_y = 0, cap_rows = 0;
    logic cp_vs = 0, cp_hb = 1;
    logic [23:0] fb [0:319][0:799];
    int  row_len [0:319];

    always @(posedge clk) if (!reset) begin
        if (cap_req && !cap_busy && !cap_valid && vga_vs && !cp_vs) begin
            cap_busy <= 1; cap_y <= 0; cap_x <= 0; cap_rows <= 0;
        end else if (cap_busy && vga_vs && !cp_vs) begin
            cap_busy <= 0; cap_valid <= 1;
        end

        if (cap_busy && vid_ce) begin
            if (!jag_vblank) begin
                if (!jag_hblank) begin
                    if (cap_x < 800 && cap_y < 320) fb[cap_y][cap_x] <= {vga_r, vga_g, vga_b};
                    if (cap_x < 800) cap_x <= cap_x + 1;
                end else if (cp_hb == 0) begin
                    if (cap_y < 320) begin row_len[cap_y] <= cap_x; cap_rows <= cap_y + 1; end
                    cap_y <= cap_y + 1;
                    cap_x <= 0;
                end
            end
            // cp_hb must be sampled under the same vid_ce gate as the edge test
            cp_hb <= jag_hblank;
        end
        cp_vs <= vga_vs;
        if (!cap_req) cap_valid <= 0;
    end

    // Previous frame, for change detection.
    logic [23:0] prev_fb [0:319][0:799];
    int  prev_w = 0, prev_h = 0;
    bit  have_prev = 0;

    task automatic grab_frame(input int idx);
        int x, y, w, h, nonblk, changed, fd;
        string path;
        cap_req = 1;
        wait (cap_valid);
        cap_req = 0;
        @(posedge clk);

        w = 0; h = cap_rows;
        for (y = 0; y < h; y++) if (row_len[y] > w) w = row_len[y];
        if (w == 0 || h == 0) begin
            $display("  frame %0d: nothing captured", idx);
            return;
        end
        nonblk = 0; changed = 0;
        for (y = 0; y < h; y++)
            for (x = 0; x < w; x++) begin
                logic [23:0] px;
                px = (x < row_len[y]) ? fb[y][x] : 24'h0;
                if (|px) nonblk++;
                if (have_prev && y < prev_h && x < prev_w && px !== prev_fb[y][x]) changed++;
            end

        path = $sformatf("frame_%02d.ppm", idx);
        fd = $fopen(path, "wb");
        if (fd != 0) begin
            $fwrite(fd, "P6\n%0d %0d\n255\n", w, h);
            for (y = 0; y < h; y++)
                for (x = 0; x < w; x++) begin
                    logic [23:0] px;
                    px = (x < row_len[y]) ? fb[y][x] : 24'h0;
                    $fwrite(fd, "%c%c%c", px[23:16], px[15:8], px[7:0]);
                end
            $fclose(fd);
        end

        if (have_prev)
            $display("  frame %0d: %0dx%0d  non-black %0d  CHANGED vs previous: %0d px",
                     idx, w, h, nonblk, changed);
        else
            $display("  frame %0d: %0dx%0d  non-black %0d  (first)", idx, w, h, nonblk);
        if (idx == 0)
            $display("      interlaced=%b  (so an every-other-frame change is %s)",
                     interlaced,
                     interlaced ? "ambiguous: could be field alternation"
                                : "a genuine 30 Hz update, not field alternation");

        for (y = 0; y < h; y++) for (x = 0; x < w; x++)
            prev_fb[y][x] = (x < row_len[y]) ? fb[y][x] : 24'h0;
        prev_w = w; prev_h = h; have_prev = 1;
    endtask

    // ---- cart preload (+cart=), same mapping the controller uses ------------
    // sdram_dual ch2, addr_ext = 0: bank = {1, ch_temp[3]},
    // row = {ch_temp[2:0], byte[19:10]}, column = {0, byte[9:1]}, where
    // ch_temp is the addr_ch3 nibble for 1 MB segment byte[23:20]. Preloaded at
    // the IDENTITY segment map (Butch's reset value). A build whose addr_ch3
    // differs will read the wrong rows -- which is the point of the test.
    int cart_words = 0;
    // +cart_off=<bytes> loads the image that far into cart space; +cart_hdr also
    // writes a minimal universal header at 0x400 (32-bit bus, entry 0x802000),
    // the way a headerless .rom dump must be presented.
    task automatic put_cart_word(input logic [23:0] o, input logic [15:0] w);
        logic [3:0] seg;
        seg = o[23:20];
        mem.preload({1'b1, seg[3]}, {seg[2:0], o[19:10]}, {1'b0, o[9:1]}, w);
    endtask
    task automatic load_cart(input string path);
        int fd, n, off; logic [7:0] hi, lo; logic [23:0] o; logic [3:0] seg;
        fd = $fopen(path, "rb");
        if (fd == 0) begin $display("ERROR: cannot open cart '%s'", path); $finish; end
        if (!$value$plusargs("cart_off=%d", off)) off = 0;
        if ($test$plusargs("cart_hdr")) begin
            put_cart_word(24'h400, 16'h0404); put_cart_word(24'h402, 16'h0404);
            put_cart_word(24'h404, 16'h0080); put_cart_word(24'h406, 16'h2000);
            $display("cart: synthesized universal header at 0x400");
        end
        o = off;
        forever begin
            n = $fgetc(fd); if (n < 0) break; hi = n[7:0];
            n = $fgetc(fd); if (n < 0) break; lo = n[7:0];
            seg = o[23:20];
            mem.preload({1'b1, seg[3]}, {seg[2:0], o[19:10]}, {1'b0, o[9:1]}, {hi, lo});
            cart_words++;
            o = o + 2;
        end
        $fclose(fd);
        $display("loaded %0d cart words (%0d bytes)", cart_words, cart_words*2);
    endtask

    // When does the 68000 reach the cart entry point, and where does it live
    // afterwards? Sampled once per ms: the address bus region.
    longint t_entry = -1;
    int  n_in_cart = 0, n_in_bios = 0, n_in_dram = 0, n_other = 0;
    always @(posedge clk) if (!reset) begin
        if (t_entry < 0 && dut.abus_out == 24'h802000 && !dut.cart_ce_n) begin
            t_entry = cyc;
            $display("[%0d ms] 68000 FETCHES THE CART ENTRY POINT 0x802000", cyc / 106364);
        end
        if (cyc % 106364 == 0) begin
            if      (!dut.cart_ce_n)                 n_in_cart++;
            else if (!dut.os_ce_n)                   n_in_bios++;
            else if (dut.abus_out[23:21] == 3'b000)  n_in_dram++;
            else                                     n_other++;
            if (cyc % (106364*250) == 0)
                $display("  [%5d ms] abus=%06x  samples: cart %0d  bios %0d  dram %0d  other %0d",
                         cyc / 106364, dut.abus_out, n_in_cart, n_in_bios, n_in_dram, n_other);
        end
    end

    string bios_path, cart_path;
    int    run_ms;

    initial begin
        if (!$value$plusargs("bios=%s", bios_path)) bios_path = "jagboot.rom";
        if (!$value$plusargs("ms=%d", run_ms))      run_ms = 40;

        $display("tb_jaguar_bios: %.4f MHz, running %0d ms of simulated time",
                 1000.0/CLK_NS, run_ms);
        begin
            int rseed;
            if ($value$plusargs("randinit=%d", rseed)) begin
                $display("SDRAM model: random power-up contents, seed %0d", rseed);
                mem.scramble(rseed);
            end
        end
        load_bios(bios_path);
        if ($value$plusargs("cart=%s", cart_path)) load_cart(cart_path);
        // The TB preloads SDRAM, bypassing the loader's header sniff, so the
        // headerless flag must be forced to test that path.
        if ($test$plusargs("headerless")) begin
            force dut.cart_headerless = 1'b1;
            $display("cart: headerless mode forced");
        end

        // let the controller self-initialise, then start the console
        repeat (50000) @(posedge clk);   // 32,768-cycle power-up hold + 12,100 startup
        $display("[%0d] sdram init done (ram64=%b), releasing reset", cyc, dut.ram64);
        reset = 0;

        if (!$value$plusargs("capture_ms=%d", cap_ms))   cap_ms = run_ms - 60;
        if (!$value$plusargs("frames=%d",     cap_frames)) cap_frames = 6;
        if (cap_ms < 1) cap_ms = 1;
        repeat (cap_ms) repeat (106364) @(posedge clk);   // nested: a single repeat count is 32-bit in Verilator and wrapped above ~20,000 ms
        $display("[%0d] capturing %0d consecutive frames from %0d ms",
                 cyc, cap_frames, cap_ms);
        for (int f = 0; f < cap_frames; f++) grab_frame(f);

        report_apf_video();
        mem.report();
        report_stability();
        report_sources();
        report_stalls();
        $display("================ RESULT after %0d ms ================", run_ms);
        $display("  BIOS chip selects   : %0d", os_sel);
        $display("  first BIOS address  : %06x   (reset vector is 0x00E00008)", first_abus);
        $display("  DRAM RAS asserts    : %0d", ras);
        $display("  vid_ce pulses       : %0d", vidce);
        $display("  hsync edges         : %0d", hs_edges);
        $display("  vsync edges         : %0d", vs_edges);
        if (vs_edges > 1)
            $display("  lines per frame     : %0d", hs_edges / vs_edges);
        $display("  active pixels        : %0d", de_pixels);
        $display("  non-black pixels     : %0d", nonblack);
        $display("  cycles with abus in 0xExxxxx : %0d  (0 = never fetched at the BIOS window)", hit_e0);
        $display("====================================================");
        $display("");
        if (hs_edges > 0 && vs_edges > 0)
            $display("VIDEO RUNNING: the BIOS programmed Tom's timing generator");
        else
            $display("NO SYNC: Tom's video timing was never programmed");
        if (nonblack > 0)
            $display("PIXELS: non-black output -- something is being drawn");
        else
            $display("PIXELS: all black");
        $finish;
    end

    // Guard must scale with the requested run, or it silently truncates it and
    // $finish beats the result display -- which is what happened on a 2000 ms
    // request with a fixed 900 ms guard.
    initial begin
        #1000;
        #(run_ms * 1_000_000.0 * 1.5);
        $display("WALL TIMEOUT (guard is 1.5x the requested %0d ms)", run_ms);
        $finish;
    end
endmodule
