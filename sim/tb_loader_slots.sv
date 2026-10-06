// Regression test for the loader slot-select bug.
//
// jaguar_top inferred "which slot is being written" from a latch that only
// updated on the first write's own clock edge, so the FIRST word of each slot
// went to the other image's region. The BIOS's word 0 (68000 initial SSP) was
// never written and kept the SDRAM's power-up garbage. tb_jaguar_boot could
// not see this: its first word was 0000 into a zero-filled model.
//
// Here the SDRAM starts scrambled (power-up), a cart then a BIOS are loaded
// through the real loader ports in the Pocket's order (slot 1 then slot 2),
// every word distinct and non-zero, and then:
//   * BIOS word 0 and cart word 0 are checked directly in the model, and
//   * the post-load readback verifier must report zero difference for both.
`timescale 1ns/1ps
module tb_loader_slots;
    localparam real CLK_NS = 9.40171;
    logic clk = 0;
    always #(CLK_NS/2.0) clk = ~clk;
    logic        reset = 1;
    logic        cart_wr = 0, bios_wr = 0;
    logic [24:0] cart_addr = 0, bios_addr = 0;
    logic [15:0] cart_data = 0, bios_data = 0;
    logic        download_active = 0;
    wire [12:0] dram_a; wire [1:0] dram_ba, dram_dqm; wire [15:0] dram_dq;
    wire dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n;
    wire [7:0] vga_r, vga_g, vga_b;
    wire vga_hs, vga_vs, jag_hblank, jag_vblank, vid_ce, interlaced;
    wire [15:0] aud_l, aud_r;
    wire vf_done; wire [15:0] bios_diff, cart_diff;
    logic save_wr = 0; logic [9:0] save_waddr = 0, save_raddr = 0; logic [15:0] save_wdata = 0;
    wire [15:0] save_rdata;

jaguar_top dut (
    .clk_sys(clk), .clk_ram(clk), .pll_locked(1'b1), .reset(reset),
    .cart_wr(cart_wr), .cart_addr(cart_addr), .cart_data(cart_data),
    .bios_wr(bios_wr), .bios_addr(bios_addr), .bios_data(bios_data),
    .download_active(download_active),
    .dram_a(dram_a), .dram_ba(dram_ba), .dram_dq(dram_dq), .dram_dqm(dram_dqm),
    .dram_clk(dram_clk), .dram_cke(dram_cke), .dram_ras_n(dram_ras_n),
    .dram_cas_n(dram_cas_n), .dram_we_n(dram_we_n),
    .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b), .vga_hs(vga_hs), .vga_vs(vga_vs),
    .hblank(jag_hblank), .vblank(jag_vblank), .vid_ce(vid_ce), .interlaced(interlaced),
    .aud_l(aud_l), .aud_r(aud_r), .joystick_0(32'd0), .joystick_1(32'd0), .cache_a_sel(3'd0), .cache_b_sel(3'd1), .cache_c_sel(3'd4), .cache_d_sel(3'd5), .sram_cache_en(1'b0), .sram_bist_en(1'b0),
    .dbg_os_seen(), .dbg_vf_done(vf_done), .dbg_bios_diff(bios_diff), .dbg_cart_diff(cart_diff),
    .save_wr(save_wr), .save_waddr(save_waddr), .save_wdata(save_wdata),
    .save_raddr(save_raddr), .save_rdata(save_rdata)
);
sdram_model mem (.clk(dram_clk), .dq(dram_dq), .a(dram_a), .ba(dram_ba),
    .cs_n(1'b0), .ras_n(dram_ras_n), .cas_n(dram_cas_n), .we_n(dram_we_n));

    localparam int NW = 8192;               // words per image: enough pairs to hit refreshes
    function automatic [15:0] cart_val(input int i); cart_val = 16'(32'hC000 + i * 7 + 1); endfunction
    function automatic [15:0] bios_val(input int i); bios_val = 16'(32'hB000 + i * 13 + 1); endfunction

    // data_loader emits {B1,B0} for file bytes B0,B1; jaguar_top swaps back.
    // Timing as the real data_loader produces it: each
    // 32-bit APF bridge word becomes TWO 16-bit writes about 5 clk_sys apart
    // (WRITE_MEM_CLOCK_DELAY = 4), and APF delivers a 32-bit word about every
    // 107 clk_sys. The original test spaced every word 100 cycles apart, which
    // hid the lost-write race against sdram_dual's single pending ch2 slot.
    task automatic write_pair(input bit is_bios, input int byte_addr, input [15:0] w0, input [15:0] w1);
        @(negedge clk);
        if (is_bios) begin bios_addr = byte_addr;   bios_data = {w0[7:0], w0[15:8]}; bios_wr = 1; end
        else         begin cart_addr = byte_addr;   cart_data = {w0[7:0], w0[15:8]}; cart_wr = 1; end
        @(negedge clk); bios_wr = 0; cart_wr = 0;
        repeat (4) @(negedge clk);
        if (is_bios) begin bios_addr = byte_addr+2; bios_data = {w1[7:0], w1[15:8]}; bios_wr = 1; end
        else         begin cart_addr = byte_addr+2; cart_data = {w1[7:0], w1[15:8]}; cart_wr = 1; end
        @(negedge clk); bios_wr = 0; cart_wr = 0;
        repeat (101) @(posedge clk);
    endtask

    // Model locations, same mapping as tb_jaguar_bios load_bios / load_cart.
    function automatic [15:0] bios_at(input int wi);
        logic [15:0] w = 16'(wi);
        bios_at = mem.mem[{2'b11, 6'b111111, w[15:9], 1'b1, w[8:0]}];
    endfunction
    function automatic [15:0] cart_at(input int wi);
        logic [23:0] o = 24'(wi * 2);
        cart_at = mem.mem[{1'b1, o[23], o[22:20], o[19:10], 1'b0, o[9:1]}];
    endfunction

    int fails = 0;
    initial begin
        mem.scramble(7);                    // power-up garbage

        // EEPROM save RAM, port B: unwritten words must
        // read erased (FFFF); written words must round-trip.
        begin
            int bad = 0;
            @(negedge clk); save_raddr = 10'd77; @(negedge clk); @(negedge clk);
            if (save_rdata !== 16'hFFFF) begin bad++; $display("  save RAM unwritten word reads %04x, want FFFF", save_rdata); end
            for (int i = 0; i < 16; i++) begin
                @(negedge clk); save_waddr = 10'(i * 61); save_wdata = 16'(16'h5A00 + i * 257); save_wr = 1;
                @(negedge clk); save_wr = 0;
            end
            for (int i = 0; i < 16; i++) begin
                @(negedge clk); save_raddr = 10'(i * 61); @(negedge clk); @(negedge clk);
                if (save_rdata !== 16'(16'h5A00 + i * 257)) begin bad++; $display("  save RAM word %0d reads %04x", i*61, save_rdata); end
            end
            $display("save RAM port B: %s", bad == 0 ? "OK (erased=FFFF, 16 words round-trip)" : "BAD");
            fails += bad;
        end
        repeat (50000) @(posedge clk);      // controller init: 32,768 power-up hold + 12,100 startup
        download_active = 1;
        for (int i = 0; i < NW; i += 2) write_pair(0, i*2, cart_val(i), cart_val(i+1));   // slot 1: cart
        for (int i = 0; i < NW; i += 2) write_pair(1, i*2, bios_val(i), bios_val(i+1));   // slot 2: BIOS
        download_active = 0;
        wait (!dut.ld_busy);                // loader write queue drained
`ifdef POCKET_DIAG
        wait (vf_done);
`endif
        repeat (10) @(posedge clk);

        $display("BIOS word 0 in SDRAM: %04x (want %04x)", bios_at(0), bios_val(0));
        $display("cart word 0 in SDRAM: %04x (want %04x)", cart_at(0), cart_val(0));
        if (bios_at(0) !== bios_val(0)) fails++;
        if (cart_at(0) !== cart_val(0)) fails++;
        begin
            int lost_b = 0, lost_c = 0;
            for (int i = 1; i < NW; i++) begin
                if (bios_at(i) !== bios_val(i)) begin lost_b++; if (lost_b <= 3) $display("  BIOS word %0d: %04x want %04x", i, bios_at(i), bios_val(i)); end
                if (cart_at(i) !== cart_val(i)) begin lost_c++; if (lost_c <= 3) $display("  cart word %0d: %04x want %04x", i, cart_at(i), cart_val(i)); end
            end
            $display("words wrong in SDRAM: BIOS %0d / %0d, cart %0d / %0d", lost_b, NW, lost_c, NW);
            fails += lost_b + lost_c;
        end
`ifdef POCKET_DIAG
        $display("verifier: done=%b bios_diff=%04x cart_diff=%04x", vf_done, bios_diff, cart_diff);
        if (bios_diff != 0 || cart_diff != 0) fails++;
`endif
        if (fails == 0) $display("LOADER SLOTS: PASS"); else $display("LOADER SLOTS: FAIL (%0d)", fails);
        $finish;
    end
    initial begin #(400_000_000); $display("TIMEOUT"); $finish; end
endmodule
