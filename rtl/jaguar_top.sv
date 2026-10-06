//
// jaguar_top -- Pocket-side replacement for Jaguar_MiSTer's Jaguar.sv `emu`.
//
// Deliberately kept recognisable as a descendant of Jaguar.sv so upstream
// changes stay mergeable. Everything removed is listed in docs/02 and
// rtl/jaguar_pocket.qip; the pieces kept are the ones docs/09 section 9.3
// identifies as console-side rather than MiSTer-side:
//
//   * the ROM/BIOS loader address and sniffer logic   (Jaguar.sv:375-581, 1135-1251)
//   * the Tom RAS/CAS -> SDRAM ch1 glue              (Jaguar.sv:1062-1124)
//   * the ch2 cart/BIOS address generation            (Jaguar.sv:1441-1446)
//   * the 8/16/32-bit cart data steering              (Jaguar.sv:1200-1212)
//   * the single `sdram` instance                     (Jaguar.sv:1448-1500)
//
// MILESTONE 1 SCOPE: cart-only. Jaguar CD, Memory Track, saves, cheats and
// the on-screen keypad are out; see docs/10. Configuration that MiSTer took
// from status[] is compile-time here (parameters below), to be replaced by
// bridge registers at M6.
//
`default_nettype none

module jaguar_top #(
    // Values chosen to match the MiSTer defaults documented in docs/09 s9.3.
    parameter bit NTSC            = 1'b1,  // status[4]=0
    parameter bit MAX_COMPAT      = 1'b1,  // status[30]=0 -> max_compat = 1
    parameter bit ACTIVE_VIDEO    = 1'b1,  // status[87]=0
    parameter bit CD_LATENCY_EN   = 1'b1   // status[82]=0
) (
    input  wire        clk_sys,        // 106.363636 MHz -- see docs/03
    input  wire        clk_ram,        // 106.363636 MHz (same net; separate port for clarity)
    input  wire        pll_locked,
    input  wire        reset,

    // ---- ROM / BIOS loading, from the APF data_loaders (docs/05) ----------
    input  wire        cart_wr,
    input  wire [24:0] cart_addr,      // byte address within the slot
    input  wire [15:0] cart_data,
    input  wire        bios_wr,
    input  wire [24:0] bios_addr,
    input  wire [15:0] bios_data,
    input  wire        download_active,

    // ---- Pocket SDRAM -----------------------------------------------------
    output wire [12:0] dram_a,
    output wire [1:0]  dram_ba,
    inout  wire [15:0] dram_dq,
    output wire [1:0]  dram_dqm,
    output wire        dram_clk,
    output wire        dram_cke,
    output wire        dram_ras_n,
    output wire        dram_cas_n,
    output wire        dram_we_n,

    // ---- Video, in the clk_sys CE domain (docs/06) ------------------------
    output wire [7:0]  vga_r,
    output wire [7:0]  vga_g,
    output wire [7:0]  vga_b,
    output wire        vga_hs,
    output wire        vga_vs,
    output wire        hblank,
    output wire        vblank,
    output wire        vid_ce,
    output wire        interlaced,

    // ---- Audio ------------------------------------------------------------
    output wire [15:0] aud_l,
    output wire [15:0] aud_r,

    // ---- Controls (docs/07) ----------------------------------------------
    input  wire [31:0] joystick_0,
    input  wire [31:0] joystick_1,
    // FAST_SDRAM cache regions: which 256 KB of the 2 MB
    // DRAM each BRAM cache mirrors, as upstream's OSD FastRAM option. Taken
    // while the console is held in reset, so a change applies at next load.
    input  wire [2:0]  cache_a_sel,
    input  wire [2:0]  cache_b_sel,
    // Stage B: two more regions in the external SRAM.
    input  wire [2:0]  cache_c_sel,
    input  wire [2:0]  cache_d_sel,
    input  wire        sram_cache_en,     // 0 = SRAM idle, every read via SDRAM
    input  wire        sram_bist_en,      // power-up SRAM write self-test (diag)
    output wire [16:0] sram_a,
    inout  wire [15:0] sram_dq,
    output wire        sram_oe_n,
    output wire        sram_we_n,
    output wire        sram_ub_n,
    output wire        sram_lb_n,

    // Cartridge EEPROM save, port B of the backing RAM (clk_sys). Word
    // address; data is the 16-bit EEPROM word as the console sees it.
    // Written from the APF save slot at load, read back when APF unloads it.
    input  wire        save_wr,
    input  wire [9:0]  save_waddr,
    input  wire [15:0] save_wdata,
    input  wire [9:0]  save_raddr,
    output reg  [15:0] save_rdata,

    // TEMPORARY diagnostic: the 68000 has selected the
    // boot ROM at least once since reset was released.
    output reg         dbg_os_seen = 1'b0,
    // TEMPORARY diagnostic: after loading, every BIOS and
    // cart word is read back from SDRAM and summed; compared with the sum of
    // what the loader wrote. diff = read - written (0 = intact).
    output reg         dbg_vf_done = 1'b0,
    output wire [15:0] dbg_bios_diff,
    output wire [15:0] dbg_cart_diff,
    output wire        dbg_lq_ovf,         // loader queue overflowed (writes lost)
    // TEMPORARY diagnostic: ch2 ROM-read timing.
    output reg  [7:0]  dbg_rom_maxlat = 8'd0,   // longest trigger->data, clk_sys
    output reg  [7:0]  dbg_rom_mincyc = 8'hFF,  // shortest ROM cycle seen, clk_sys
    output reg  [15:0] dbg_rom_late   = 16'd0,  // reads whose data came within 2 clk of that
    // TEMPORARY diagnostic: DRAM read traffic by region.
    output wire        dbg_rd,                  // one pulse per Tom DRAM read
    output wire [4:0]  dbg_rd_region,           // its 64 KB block
    output wire        dbg_stall,               // ram_rdy low (the latency kludge)
    output wire [2:0]  dbg_cache_a,             // regions the caches hold now
    output wire [2:0]  dbg_cache_b,
    output wire [31:0] dbg_cached_blocks,       // 64 KB blocks the cache holds
    output wire [7:0]  dbg_reassign,            // block-cache slot reassignments
    output wire [2:0]  dbg_cache_c,
    output wire [2:0]  dbg_cache_d,
    output wire        dbg_sram_disabled,       // write queue overflowed (sticky)
    output wire [15:0] dbg_sram_hits,
    output wire [15:0] dbg_sram_fallbacks,
    output wire [3:0]  dbg_sram_qmax,
    output wire        dbg_sram_bist_done,
    output wire [15:0] dbg_sram_bist_err,       // {W1,W2,W3,W6} nibbles
    output wire [15:0] dbg_sram_bist_w2         // W2 (the cache's timing) full count
);

// =============================================================================
// Reset
// =============================================================================
// Jaguar.sv:588-592. The console must stay held while a ROM or BIOS image is
// being written into SDRAM, and `bootcopy` keeps it held a little longer after.
    reg  [31:0] vf_sum_bw = 0, vf_sum_cw = 0, vf_sum_br = 0, vf_sum_cr = 0;
    reg  [21:0] vf_nb = 0, vf_nc = 0, vf_idx = 0;
    reg         vf_busy = 0, vf_phase = 0, vf_req = 0;
    reg  [5:0]  vf_t = 0;
    reg         vf_dl_old = 0;
    wire        ld_busy;          // loader active or its write queue not yet drained
    wire        xresetlp        = !(reset | ld_busy | vf_busy);
    wire        sdram_xresetlp  = !(reset | ld_busy | vf_busy);
    wire        xresetl         = xresetlp && !(|bootcopy);
    reg  [18:0] bootcopy;


// =============================================================================
// Loader  (docs/05)
// =============================================================================
// The two data_loader instances replace hps_io's single ioctl stream. Their
// write_addr is already a byte offset within the slot and increments by
// OUTPUT_WORD_SIZE (2) per 16-bit word, which is exactly MiSTer's loader_addr,
// so that counter is not needed here.
    wire        loader_wr   = cart_wr | bios_wr;
    wire [24:0] loader_addr = cart_wr ? cart_addr : bios_addr;
    wire [15:0] loader_data = cart_wr ? cart_data : bios_data;
    wire        loader_en   = download_active;

// Which slot is being written. MiSTer's hps_io sets ioctl_index BEFORE a
// download starts; APF has no equivalent, so the slot is inferred from which
// data_loader is writing. The latch alone is NOT enough: it only updates on
// the first write's own clock edge, so that first write saw the PREVIOUS slot
// and went to the other image's region. BIOS word 0 (the 68000's initial SSP)
// was then never written and held whatever the SDRAM powered up with.
// Use the live write strobes; fall back to the latch
// between writes.
    reg         loading_cart = 0;
    reg         loading_bios = 0;
    wire        os_index     = bios_wr ? 1'b1 : cart_wr ? 1'b0 : loading_bios;
    wire        cart_index   = cart_wr ? 1'b1 : bios_wr ? 1'b0 : loading_cart;

// BYTE ORDER. APF is big-endian (bridge_endian_little = 0) and data_loader
// then emits, for file bytes B0 B1 B2 B3, the 16-bit words {B1,B0} then
// {B3,B2}. Jaguar ROMs are big-endian 68000 images, so the word wanted is
// {B0,B1} -- which is exactly what MiSTer's swap produces. Keeping it
// unchanged is therefore correct; the bios_m / cart_b sniffers below act as a
// runtime self-test of this (docs/05 section 5.3).
    wire [15:0] loader_data_bs = {loader_data[7:0], loader_data[15:8]};

// ---- Loader write queue ---------------------------------
// MiSTer paces ROM loading with ioctl_wait; the APF port dropped that on the
// argument of "9x headroom at one word per ~107 clk_sys". Wrong: data_loader
// splits each 32-bit APF word into TWO 16-bit writes ~5 clk_sys apart, and
// sdram_dual holds ONE pending ch2 request, served only from STATE_IDLE. When
// the first half arrived during a refresh (8 cycles, every 780 while loading)
// the second half overwrote it: ~0.3% of words silently never written, at
// random positions each launch. After power-on they held garbage (hang,
// garbled graphics, no music); after a previous launch they usually held the
// right value already, which is why relaunches got progressively better.
//
// Fix: queue the loader's writes and issue them to ch2 one per LQ_GAP clk_sys
// cycles, which covers a refresh plus a full write. 2 x 32 = 64 cycles per APF
// word against ~107 available. The console stays in reset, and the readback
// verifier waits, until the queue has drained (ld_busy).
    localparam int LQ_GAP = 32;
    reg  [39:0] lq_mem [0:63];               // {is_bios, word addr[23:1], data}
    reg  [5:0]  lq_w = 0, lq_r = 0;
    wire        lq_empty = (lq_w == lq_r);
    wire        lq_full  = (lq_w + 6'd1 == lq_r);
    reg  [39:0] lq_cur = 0;
    reg         lq_req = 0;
    reg  [5:0]  lq_t   = 0;
    reg         dbg_lq_ovf_r = 0;
    assign      dbg_lq_ovf = dbg_lq_ovf_r;
    assign      ld_busy = download_active | !lq_empty | (lq_t != 0);
always @(posedge clk_sys) begin
    lq_req <= 1'b0;
    if (loader_en && loader_wr) begin
        if (!lq_full) begin
            lq_mem[lq_w] <= {os_index, loader_addr[23:1], loader_data_bs};
            lq_w <= lq_w + 1'b1;
        end else dbg_lq_ovf_r <= 1'b1;
    end
    if (lq_t != 0) lq_t <= lq_t - 1'b1;
    else if (!lq_empty) begin
        lq_cur <= lq_mem[lq_r];
        lq_r   <= lq_r + 1'b1;
        lq_req <= 1'b1;
        lq_t   <= LQ_GAP[5:0] - 1'b1;
    end
end

// Cart size mask (Jaguar.sv:523-538). Track one past the last cart byte
// written, then classify when the transfer ends.
    reg  [24:0] cart_end_addr = 0;
    // Pass-through by default. Upstream only assigns this during a cart
    // download, so with no cart it would be X in simulation; 3'h7 is the
    // "not exact, don't modify" value upstream settles on for unknown sizes.
    reg  [22:20] cart_mask = 3'h7;
    reg         old_download = 0;
    reg         cart_headerless = 1'b0;
    reg  [15:0] hdr_w200 = 0;          // header sniff, filled in below
    reg         hdr_same = 0, hdr_valid = 1'b1;
    // a headerless image is the cart minus its first 8 KB
    wire [24:0] cart_size_eff = (!hdr_valid && cart_end_addr[15:0] == 16'hE000)
                              ? cart_end_addr + 25'h2000 : cart_end_addr;

always @(posedge clk_sys) begin
    old_download <= download_active;

    if (cart_wr) begin
        loading_cart  <= 1;
        loading_bios  <= 0;
        cart_end_addr <= cart_addr + 25'd2;
    end
    if (bios_wr) begin
        loading_bios <= 1;
        loading_cart <= 0;
    end

    // End of all transfers: size the cart and release the slot latches.
    if (old_download && !download_active) begin
        if (loading_cart) begin
            cart_mask[22:20] <= 3'h7;                       // "not exact, don't modify"
            // Headerless dump: no valid universal header
            // AND a size of 64 KB multiples minus 8 KB. Both, so a homebrew
            // .abs/.cof of arbitrary size is never shifted.
            cart_headerless <= !hdr_valid && (cart_end_addr[15:0] == 16'hE000);
            if (cart_size_eff[19:0] == 20'h0) begin
                if      (cart_size_eff[24:20] == 5'h1) cart_mask[22:20] <= 3'h0;  // 1 MB
                else if (cart_size_eff[24:20] == 5'h2) cart_mask[22:20] <= 3'h1;  // 2 MB
                else if (cart_size_eff[24:20] == 5'h4) cart_mask[22:20] <= 3'h3;  // 4 MB
            end
        end
        loading_cart <= 0;
        loading_bios <= 0;
    end
end

// BIOS K-vs-M detection and cart bus-width detection, sniffed out of the
// download stream exactly as Jaguar.sv:1140-1174 does.
    reg [1:0] cart_b = 0;
    reg [1:0] bios_b = 0;
    reg [1:0] addr_b = 0;
    reg       bios_m = 0;

always @(posedge clk_sys) begin
    if (cart_rd_trig) addr_b[1:0] <= abus_out[1:0];

    // 0x136E is the K BIOS checksum branch, 0x19C6 the M BIOS one.
    if (loader_addr[23:1] == 23'h0009B7 && loader_en && loader_wr && os_index)
        if (loader_data_bs[15:8] == 8'h67) bios_m <= 1'b0;
    if (loader_addr[23:1] == 23'h000CE3 && loader_en && loader_wr && os_index)
        if (loader_data_bs[15:8] == 8'h67) bios_m <= 1'b1;

    // Cart bus width from the universal header at word 0x200/0x201.
    if (loader_addr[23:1] == 23'h000200 && loader_en && loader_wr && cart_index)
        if      (loader_data_bs == 16'h0202) cart_b <= 2'b01;
        else if (loader_data_bs == 16'h0000) cart_b <= 2'b10;
        else                                 cart_b <= 2'b00;
    if (loader_addr[23:1] == 23'h000201 && loader_en && loader_wr && cart_index)
        if      (loader_data_bs == 16'h0202 && cart_b == 2'b01) cart_b <= 2'b01;
        else if (loader_data_bs == 16'h0000 && cart_b == 2'b10) cart_b <= 2'b10;
        else                                                    cart_b <= 2'b00;

    // Universal-header check for headerless dumps: a
    // real header repeats the bus-width byte at 0x400-0x403 and has a cart
    // entry point (0x0080xxxx) at 0x404.
    if (loader_addr[23:1] == 23'h000000 && loader_en && loader_wr && cart_index)
        hdr_valid <= 1'b0;
    if (loader_addr[23:1] == 23'h000200 && loader_en && loader_wr && cart_index)
        hdr_w200 <= loader_data_bs;
    if (loader_addr[23:1] == 23'h000201 && loader_en && loader_wr && cart_index)
        hdr_same <= (loader_data_bs == hdr_w200) &&
                    (hdr_w200 == 16'h0404 || hdr_w200 == 16'h0202 ||
                     hdr_w200 == 16'h0101 || hdr_w200 == 16'h0000);
    if (loader_addr[23:1] == 23'h000202 && loader_en && loader_wr && cart_index)
        hdr_valid <= hdr_same && (loader_data_bs == 16'h0080);
end


// =============================================================================
// Configuration (was status[] from the OSD)
// =============================================================================
    wire        max_compat       = MAX_COMPAT;
    wire        patch_checksums  = MAX_COMPAT;
    wire        gamedrive_enable = MAX_COMPAT;


// =============================================================================
// Cartridge EEPROM backing store   (Jaguar.sv:1582-1600 cart_backram)
// =============================================================================
// jaguar.v's 93C46 model keeps its contents here. It was tied to zero, so
// every EEPROM read returned 0000 and Rayman's save slots all showed "ERROR".
// Starts ERASED (FFFF), like a fresh cart's EEPROM; upstream fills it from the
// MiSTer save file instead. Persisted through the APF "Save" data slot via
// port B (target/pocket/core_top.sv).
//
// Stored INVERTED, so it needs no initialiser: M10K powers up all zero, which
// reads back as FFFF. An `initial` loop setting FFFF stopped Quartus inferring
// a RAM block and built 16,384 flip-flops instead; the fit failed at 108%.
    wire [9:0]  cart_bram_addr;
    wire [15:0] cart_bram_data;
    wire        cart_bram_wr;
    // Explicit altsyncram, true dual-port: port A is the console's 93C46
    // model, port B the APF save slot. Two always blocks on one array were NOT
    // inferred as a RAM block: Quartus built 16,384 flip-flops and the fit
    // failed at 143%. Contents stored inverted on both
    // ports; M10K powers up zero = erased (FFFF).
    wire [15:0] cart_bram_q_n, save_rdata_n;
    wire [15:0] cart_bram_q = ~cart_bram_q_n;
altsyncram #(
    .operation_mode                     ( "BIDIR_DUAL_PORT" ),
    .width_a                            ( 16 ), .widthad_a ( 10 ), .numwords_a ( 1024 ),
    .width_b                            ( 16 ), .widthad_b ( 10 ), .numwords_b ( 1024 ),
    .width_byteena_a                    ( 1 ),  .width_byteena_b ( 1 ),
    .outdata_reg_a                      ( "UNREGISTERED" ),
    .outdata_reg_b                      ( "UNREGISTERED" ),
    .address_reg_b                      ( "CLOCK0" ),
    .indata_reg_b                       ( "CLOCK0" ),
    .wrcontrol_wraddress_reg_b          ( "CLOCK0" ),
    .clock_enable_input_a               ( "BYPASS" ), .clock_enable_input_b  ( "BYPASS" ),
    .clock_enable_output_a              ( "BYPASS" ), .clock_enable_output_b ( "BYPASS" ),
    .outdata_aclr_a                     ( "NONE" ),   .outdata_aclr_b        ( "NONE" ),
    .read_during_write_mode_port_a      ( "NEW_DATA_NO_NBE_READ" ),
    .read_during_write_mode_port_b      ( "NEW_DATA_NO_NBE_READ" ),
    .read_during_write_mode_mixed_ports ( "DONT_CARE" ),
    .power_up_uninitialized             ( "FALSE" ),
    .ram_block_type                     ( "M10K" ),
    .intended_device_family             ( "Cyclone V" ),
    .lpm_type                           ( "altsyncram" )
) cart_backram (
    .clock0     ( clk_sys ),
    .address_a  ( cart_bram_addr ),
    .data_a     ( ~cart_bram_data ),
    .wren_a     ( cart_bram_wr ),
    .q_a        ( cart_bram_q_n ),
    .address_b  ( save_wr ? save_waddr : save_raddr ),
    .data_b     ( ~save_wdata ),
    .wren_b     ( save_wr ),
    .q_b        ( save_rdata_n ),
    .aclr0 (1'b0), .aclr1 (1'b0), .addressstall_a (1'b0), .addressstall_b (1'b0),
    .byteena_a (1'b1), .byteena_b (1'b1), .clock1 (1'b1),
    .clocken0 (1'b1), .clocken1 (1'b1), .clocken2 (1'b1), .clocken3 (1'b1),
    .eccstatus ( ), .rden_a (1'b1), .rden_b (1'b1)
);
always @(*) save_rdata = ~save_rdata_n;


// =============================================================================
// The console
// =============================================================================
    wire [9:0]  dram_a_jag;
    wire        dram_ras_n_jag, dram_cas_n_jag;
    wire [3:0]  dram_oe_n, dram_uw_n, dram_lw_n;
    wire [63:0] dram_d;
    wire [23:0] abus_out;
    wire [7:0]  os_rom_q;
    wire        os_ce_n, cart_ce_n;
    wire [1:0]  cart_oe;
    wire [31:0] cart_q;
    wire        startcas, xvclk_o;
    wire        cart_xwaitl;         // ROM-cycle wait, assigned at the SDRAM ch2 mux
    wire [29:0] audbus_out;
    wire [23:0] addr_ch3;
    wire        aud_ce, b_override;
    wire        overflow, underflow, errflow, unhandled;
    wire        dram_startwep, dram_go_rd, dram_rw;
    wire [7:0]  dram_be;
    wire [23:0] dram_address;
    wire [10:3] dram_addressp;
    wire        m68k_clk;
    wire [23:1] m68k_addr;
    wire [15:0] m68k_bus_do;
    reg  [15:0] m68k_data = 16'h0;

jaguar jaguar_inst (
    .xresetl_in         ( xresetl ),
    .cold_reset         ( download_active ),
    .sys_clk            ( clk_sys ),

    .dram_a             ( dram_a_jag ),
    .dram_ras_n         ( dram_ras_n_jag ),
    .dram_cas_n         ( dram_cas_n_jag ),
    .dram_oe_n          ( dram_oe_n ),
    .dram_uw_n          ( dram_uw_n ),
    .dram_lw_n          ( dram_lw_n ),
    .dram_d             ( dram_d ),
    .dram_q             ( dram_q ),
    .dram_oe            ( dram_oe ),
    .dram_be            ( dram_be ),
    .dram_startwep      ( dram_startwep ),
    .dram_addr          ( dram_address ),
    .dram_addrp         ( dram_addressp ),
    .dram_go_rd         ( dram_go_rd ),
    .dram_rw            ( dram_rw ),
    .ram_rdy            ( ram_rdy ),

    .abus_out           ( abus_out ),
    .os_rom_ce_n        ( os_ce_n ),
    .os_rom_q           ( os_rom_q ),
    .cart_ce_n          ( cart_ce_n ),
    .cart_oe            ( cart_oe ),
    .cart_q             ( cart_q ),

    // Cart NVRAM and CD EEPROM backing stores return at M5 (docs/05 s5.6).
    .cart_bram_addr     ( cart_bram_addr ),
    .cart_bram_data     ( cart_bram_data ),
    .cart_bram_q        ( cart_bram_q ),
    .cart_bram_wr       ( cart_bram_wr ),
    .cd_bram_addr       ( ),
    .cd_bram_data       ( ),
    .cd_bram_q          ( 16'h0 ),
    .cd_bram_wr         ( ),

    .vga_vs             ( vga_vs ),
    .vga_hs             ( vga_hs ),
    .vga_r              ( vga_r ),
    .vga_g              ( vga_g ),
    .vga_b              ( vga_b ),
    .hblank             ( hblank ),
    .vblank             ( vblank ),
    .interlaced         ( interlaced ),
    .active_video       ( ACTIVE_VIDEO ),
    .vid_ce             ( vid_ce ),
    .xvclk_o            ( xvclk_o ),
    .ntsc               ( NTSC ),

    .aud_16_l           ( aud_l ),
    .aud_16_r           ( aud_r ),
    .aud_16_eq          ( ),                 // OUTPUT of jaguar (jaguar.v:116),
                                             // not an input. Tying it to 1'b0 is an
                                             // electrical short; Quartus accepted it
                                             // silently, Verilator caught it.

    .xwaitl             ( cart_xwaitl ),
    .startcas           ( startcas ),

    // Inputs: see docs/07. Only the two pads are wired for now.
    .joystick_0         ( joystick_0 ),
    .joystick_1         ( joystick_1 ),
    .joystick_2         ( 32'd0 ),
    .joystick_3         ( 32'd0 ),
    .joystick_4         ( 32'd0 ),
    .analog_0           ( 8'd127 ),
    .analog_1           ( 8'd127 ),
    .analog_2           ( 8'd127 ),
    .analog_3           ( 8'd127 ),
    .spinner_0          ( 9'd0 ),
    .spinner_1          ( 9'd0 ),
    .spinner_speed      ( 2'd0 ),
    .team_tap_port1     ( 1'b0 ),
    .team_tap_port2     ( 1'b0 ),
    .lightgun_mode      ( 2'd0 ),
    .lightgun_crosshair ( 2'd0 ),
    .ps2_mouse          ( 25'd0 ),
    .mouse_ena_1        ( 1'b0 ),
    .mouse_ena_2        ( 1'b0 ),

    // JagLink over the Pocket link port is M7+ (docs/07 s7.5).
    .comlynx_tx         ( ),
    .comlynx_rx         ( 1'b1 ),

    // Jaguar CD. Compiled out by NO_JAGUAR_CD, but the ports remain.
    .cd_en              ( 1'b0 ),
    .cd_ex              ( 1'b0 ),
    .cd_latency_en      ( CD_LATENCY_EN ),
    .aud_in             ( 64'h0 ),
    .audwaitl           ( 1'b1 ),
    .aud_busy           ( 1'b0 ),
    .aud_sess           ( 1'b1 ),
    .cdg_in             ( 64'h0 ),
    .force_music_cd     ( 1'b0 ),
    .toc_addr           ( 10'd0 ),
    .toc_data           ( 16'h0 ),
    .toc_wr             ( 1'b0 ),
    .toc_done           ( 1'b0 ),
    .audbus_out         ( audbus_out ),
    .aud_ce             ( aud_ce ),
    .addr_ch3           ( addr_ch3 ),
    .b_override         ( b_override ),
    .overflow           ( overflow ),
    .underflow          ( underflow ),
    .errflow            ( errflow ),
    .unhandled          ( unhandled ),
    .cd_valid           ( 1'b0 ),            // inputs, not outputs
    .cd_sector2448      ( 1'b0 ),

    .maxc               ( max_compat ),
    .auto_eeprom        ( max_compat ),
    .dohacks            ( patch_checksums ),
    .vintbugfix         ( max_compat ),
    .olpbugfix          ( max_compat ),
    .turbo              ( 1'b0 ),
    .ddreq              ( 1'b1 ),

    // 68000 DATA BUS -- not optional, and not part of the cheat engine.
    //
    // jaguar.v:1607 wires m68k_di straight to the CPU's DATA_i. The core hands
    // the data it wants the CPU to see OUT on m68k_bus_do, upstream passes it
    // through the cheat engine, registers it on m68k_clk, and hands it BACK on
    // m68k_di (Jaguar.sv:1884-1900). Tying m68k_di to zero -- which I did --
    // feeds the 68000 all zeros: it read SSP=0 and PC=0, jumped to 0 and
    // re-read the vector table forever. Quartus compiled that happily through
    // five successful builds; only simulation caught it.
    //
    // With the cheat engine dropped this is a plain pass-through, keeping
    // upstream's one-register delay so the timing is unchanged.
    .m68k_clk           ( m68k_clk ),
    .m68k_addr          ( m68k_addr ),
    .m68k_bus_do        ( m68k_bus_do ),
    .m68k_di            ( m68k_data ),
    .gamedrive_enable   ( gamedrive_enable )
);


// Cheat-engine bypass: pass m68k_bus_do straight back as the CPU's data input,
// with the same single m68k_clk-gated register upstream uses.
always @(posedge clk_sys)
    if (m68k_clk) m68k_data <= m68k_bus_do;


// =============================================================================
// Tom's DRAM controller -> SDRAM ch1    (Jaguar.sv:1062-1124)
// =============================================================================
// Single-SDRAM configuration, so ch1_64 = 1 and the whole 64-bit word comes
// from one chip.
//
// FAST_SDRAM. Upstream DEFINES this for MiSTer's normal
// single-SDRAM build (Jaguar.sv:602-609), so MiSTer users run with it. The
// port originally left it out because three 128 KB BRAM caches are 384 M10K
// against Pocket's 308. Without it every DRAM read waits out the "latency
// kludge" (ram_rdy = ~ch1_req): slowdown with many sprites, and DSP audio
// missing its deadlines. Each cache holds the UPPER 32 bits of every 64-bit
// word in one 256 KB region of the 2 MB DRAM; a hit takes those from BRAM and
// the lower 32 from the first beats of the SDRAM burst, so Tom need not wait.
//
// Two caches fit (2 x 128 M10K + 42 = 298 of 308): regions 0 and 1, which
// are upstream's defaults for cache0/cache2 (status[36:34] = 0). Upstream's
// third, cache1 (region 7 by default), is also MiSTer's memtrack buffer and
// is dropped.
    wire        ch1_64      = 1'b1;
    reg  [9:0]  ras_latch;           // assigned in the RAS/CAS edge block below
    wire [7:0]  ch1_be;              // assigned below with the other ch1 controls
    reg  [7:0]  cas_latch   = 8'd0;
    wire [17:0] sdram_addr  = {ras_latch[9:0], cas_latch[7:0]};
    reg  [2:0]  cache_a     = 3'd0, cache_b = 3'd1;   // upstream defaults
    reg  [2:0]  cache_c     = 3'd4, cache_d = 3'd5;
    reg         sram_en     = 1'b0;
always @(posedge clk_sys) if (reset || ld_busy) begin
    cache_a <= cache_a_sel;
    cache_b <= cache_b_sel;
    cache_c <= cache_c_sel;
    cache_d <= cache_d_sel;
    sram_en <= sram_cache_en;
end
    wire        sram_hit;                // Stage B, see sram_cache below
    wire [31:0] sram_q;
    wire        sram_use_q;              // sram_q is the upper half for sdram_addr
    reg         fastram_w   = 1'b0;
    reg         old_ch1_reqw = 1'b0;
`ifdef POCKET_FIXED_CACHE
    // Upstream's fixed-region FAST_SDRAM caches (regions from the menu).
    wire        cache0      = (sdram_addr[17:15] == cache_a);
    wire        cache2      = (sdram_addr[17:15] == cache_b);
    wire        use_fastram = cache0 | cache2;
    wire [3:0]  wr0 = {4{fastram_w & cache0}} & ch1_be[7:4];
    wire [3:0]  wr2 = {4{fastram_w & cache2}} & ch1_be[7:4];
    wire [63:32] fastram0, fastram2;
    wire [63:32] fastram = cache2 ? fastram2 : fastram0;
    wire [31:0] bc_cached = 32'd0;
    wire [7:0]  bc_nre = 8'd0;
`else
    // Self-selecting block cache (rtl/blkcache.sv): the
    // same BRAM as 8 slots of 64 KB that follow the game's hot blocks.
    wire        bc_hit;
    wire [31:0] bc_q;
    wire [31:0] bc_cached;
    wire [7:0]  bc_nre;
    wire        use_fastram = bc_hit;
    wire [63:32] fastram = bc_q;
`endif
`ifdef POCKET_FASTRAM_DELAY
    // SIMULATION EXPERIMENT: withhold the cached upper
    // half until POCKET_FASTRAM_DELAY clocks after ch1_reqr, to find the
    // latest a Stage B SRAM cache may deliver it.
    reg  [7:0]  fd_cnt = 8'hFF;
always @(posedge clk_ram)
    if (dram_go_rd) fd_cnt <= 8'd1; else if (~&fd_cnt) fd_cnt <= fd_cnt + 1'b1;
    wire [63:32] fastram_eff = (fd_cnt < `POCKET_FASTRAM_DELAY) ? 32'hDEADBEEF : fastram;
`else
    wire [63:32] fastram_eff = fastram;
`endif
    wire [63:0] dram_q      = use_fastram ? {fastram_eff[63:32], ch1_dout[31:0]}
                            : (sram_use_q && sram_en) ? {sram_q,  ch1_dout[31:0]} : ch1_dout;

    wire [3:0]  dram_oe     = (~dram_cas_n_jag) ? ~dram_oe_n : 4'b0000;
    // Latency kludge (Jaguar.sv:1063), conditional.
    // Upstream stalls Tom for one cycle on every read outside the FAST_SDRAM
    // caches. Measured: a read sdram_dual issues in its request cycle has all
    // 64 bits valid exactly 8 clk after dram_go_rd, and Tom consumes at
    // +8 at every MEMCON1 DRAM speed; only a read the controller had to queue
    // (behind refresh, ACT/PRE, a write or ch2) arrives at +9 and needs the
    // stall. ch1_ontime is a register set at the request edge, valid at CAS.
    // FAILED ON HARDWARE: go+8 is a zero-delay deadline. On silicon the
    // last beat needs ~2 clk to reach Tom's capture flops, which the stall
    // provided; 0.0.21 hung in the BIOS. Kept opt-in (POCKET_STALL_ONTIME) for
    // experiments; the default is upstream's unconditional stall.
    wire        ch1_ontime;
`ifdef POCKET_STALL_ONTIME
    wire        ram_rdy     = ~ch1_64 || ~ch1_req || use_fastram || sram_hit || ch1_ontime;
`else
    wire        ram_rdy     = ~ch1_64 || ~ch1_req || use_fastram || sram_hit;
`endif
    assign      dbg_rd        = ch1_req;
    assign      dbg_rd_region = sdram_addr[17:13];
    assign      dbg_stall     = ~ram_rdy;
    assign      dbg_cache_a   = cache_a;
    assign      dbg_cache_b   = cache_b;
    assign      dbg_cached_blocks = bc_cached;
    assign      dbg_reassign  = bc_nre;
    assign      dbg_cache_c   = cache_c;
    assign      dbg_cache_d   = cache_d;

    wire        ram_read_req  = (dram_oe_n != 4'b1111);
    wire        ram_write_req = ({dram_uw_n, dram_lw_n} != 8'hFF);

    wire        ch1_rnw  = !ram_write_req;
    wire        ch1_reqr = dram_go_rd;
    wire        ch1_req  = dram_cas_edge && ~dram_ras_n_jag && !ram_write_req;
    wire        ch1_reqw = dram_cas_edge && ~dram_ras_n_jag &&  ram_write_req;
    wire        ch1_ref  = dram_cas_edge &&  dram_ras_n_jag;
    wire        ch1_act  = dram_ras_edge &&  dram_cas_n_jag;
    wire        ch1_pch  = dram_ras_nedge && dram_cas_n_jag;

// FAST_SDRAM cache upkeep (Jaguar.sv:1272-1324). The column comes from the
// read/write strobe's address; a write updates the cache one cycle later with
// the same byte enables as the SDRAM write.
always @(posedge clk_ram) begin
    fastram_w    <= 1'b0;
    old_ch1_reqw <= ch1_reqw;
    if (ch1_reqr) cas_latch <= dram_addressp[10:3];
    if (ch1_reqw) cas_latch <= dram_a_jag[7:0];
    if (old_ch1_reqw && use_fastram) fastram_w <= 1'b1;
end
`ifdef POCKET_FIXED_CACHE
spram_byte_32x15 fastcache0 (
    .clk ( clk_sys ), .addr ( sdram_addr[14:0] ), .din ( ch1_din[63:32] ),
    .wr ( wr0 ), .dout ( fastram0[63:32] ),
    .addr_b ( 15'd0 ), .din_b ( 32'd0 ), .wr_b ( 4'd0 ), .dout_b ( ),
    .use_16_bit ( 1'b0 ), .addr_16 ( 16'd0 ), .dout_16 ( ), .din_16 ( 16'd0 ), .wr_16 ( 2'b00 ),
    .addr_b_16 ( 16'd0 ), .dout_b_16 ( ), .din_b_16 ( 16'd0 ), .wr_b_16 ( 2'b00 )
);
spram_byte_32x15 fastcache2 (
    .clk ( clk_sys ), .addr ( sdram_addr[14:0] ), .din ( ch1_din[63:32] ),
    .wr ( wr2 ), .dout ( fastram2[63:32] ),
    .addr_b ( 15'd0 ), .din_b ( 32'd0 ), .wr_b ( 4'd0 ), .dout_b ( ),
    .use_16_bit ( 1'b0 ), .addr_16 ( 16'd0 ), .dout_16 ( ), .din_16 ( 16'd0 ), .wr_16 ( 2'b00 ),
    .addr_b_16 ( 16'd0 ), .dout_b_16 ( ), .din_b_16 ( 16'd0 ), .wr_b_16 ( 2'b00 )
);
`endif

    wire [63:0] ch1_din = dram_d;
    wire [63:0] ch1_dout;
    wire        ch1a_ready;

// Byte enables, noting the 16-bit upper/lower interleave of the Jaguar's
// four 16-bit DRAM chips.
    assign      ch1_be = ~{ dram_uw_n[3], dram_lw_n[3],
                            dram_uw_n[2], dram_lw_n[2],
                            dram_uw_n[1], dram_lw_n[1],
                            dram_uw_n[0], dram_lw_n[0] };

`ifndef POCKET_FIXED_CACHE
    wire        ch1_rd_done;
blkcache blkcache (
    .clk           ( clk_ram ),
    .rst           ( !sdram_xresetlp ),
    .sdram_addr    ( sdram_addr ),
    .rd_cas        ( ch1_req ),
    .wr_go         ( old_ch1_reqw ),
    .wr_data       ( ch1_din[63:32] ),
    .wr_be         ( ch1_be[7:4] ),
    .rd_done       ( ch1_rd_done ),
    .rd_data       ( ch1_dout[63:32] ),
    .hit           ( bc_hit ),
    .q             ( bc_q ),
    .cached_blocks ( bc_cached ),
    .n_reassign    ( bc_nre )
);
`else
    wire        ch1_rd_done;
`endif

// Stage B: regions C and D in the external SRAM (rtl/sram_cache.sv).
// BRAM regions A/B take precedence on overlap; a
// read the SRAM cannot serve in time falls back to the SDRAM path above.
// v2: nothing here captures Tom's raw strobes into state -- sram_cache
// registers its inputs once, `hit` is ch1_req AND a register (upstream's
// use_fastram shape), and the dram_q select compares registered addresses.
    wire        sram_hit_raw;
    assign      sram_hit = sram_hit_raw && sram_en && !use_fastram;
// Shelved: built only with POCKET_SRAM_CACHE. Even switched off, its
// presence coincided with 0.0.20/0.0.21 hanging in the BIOS, so the
// default build leaves the SRAM pins idle, as 0.0.17 did.
`ifdef POCKET_SRAM_CACHE
sram_cache sram_cache (
    .clk        ( clk_ram ),
    .rst        ( !sdram_xresetlp || !sram_en ),
    .reg_c      ( cache_c ),
    .reg_d      ( cache_d ),
    .rd_go      ( ch1_reqr ),
    .rd_addr    ( {ras_latch[9:0], dram_addressp[10:3]} ),
    .cas        ( ch1_req ),
    .cas_addr   ( sdram_addr ),
    .hit        ( sram_hit_raw ),
    .use_q      ( sram_use_q ),
    .q          ( sram_q ),
    .wr_go      ( ch1_reqw ),
    .wr_addr    ( {ras_latch[9:0], dram_a_jag[7:0]} ),
    .wr_data    ( ch1_din[63:32] ),
    .wr_be      ( ch1_be[7:4] ),
    .bist_en    ( sram_bist_en ),
    .bist_start ( pll_locked ),
    .bist_done  ( dbg_sram_bist_done ),
    .bist_err   ( dbg_sram_bist_err ),
    .bist_err_w2( dbg_sram_bist_w2 ),
    .disabled   ( dbg_sram_disabled ),
    .n_hit      ( dbg_sram_hits ),
    .n_fallback ( dbg_sram_fallbacks ),
    .q_max      ( dbg_sram_qmax ),
    .sram_a     ( sram_a ),
    .sram_dq    ( sram_dq ),
    .sram_oe_n  ( sram_oe_n ),
    .sram_we_n  ( sram_we_n ),
    .sram_ub_n  ( sram_ub_n ),
    .sram_lb_n  ( sram_lb_n )
);
`else
    assign sram_hit_raw = 1'b0;  assign sram_use_q = 1'b0;  assign sram_q = 32'd0;
    assign sram_a = 17'd0;       assign sram_dq = {16{1'bZ}};
    assign sram_oe_n = 1'b1;     assign sram_we_n = 1'b1;
    assign sram_ub_n = 1'b1;     assign sram_lb_n = 1'b1;
    assign dbg_sram_disabled = 1'b0; assign dbg_sram_hits = 16'd0; assign dbg_sram_fallbacks = 16'd0;
    assign dbg_sram_qmax = 4'd0;     assign dbg_sram_bist_done = 1'b0;
    assign dbg_sram_bist_err = 16'd0; assign dbg_sram_bist_w2 = 16'd0;
`endif

    reg         old_cas_n, old_ras_n, old_ram_read_req;
    wire        dram_cas_edge  =  old_cas_n && ~dram_cas_n_jag;
    wire        dram_ras_edge  =  old_ras_n && ~dram_ras_n_jag;
    wire        dram_ras_nedge = ~old_ras_n &&  dram_ras_n_jag;
    reg  [23:0] old_abus_out;

always @(posedge clk_ram)
if (reset) begin
    dbg_os_seen <= 1'b0;
    ras_latch <= 10'd0;
    old_cas_n <= 1'b1;
    bootcopy  <= 19'h0;
end else begin
    if (!os_ce_n) dbg_os_seen <= 1'b1;
    old_cas_n        <= dram_cas_n_jag;
    old_ras_n        <= dram_ras_n_jag;
    old_ram_read_req <= ram_read_req;
    if (old_ras_n && ~dram_ras_n_jag) ras_latch <= dram_a_jag;
    if (|bootcopy) bootcopy <= bootcopy - 19'h1;
end

always @(posedge clk_sys)
    old_abus_out <= reset ? 24'h112233 : abus_out;


// =============================================================================
// SDRAM power-up hold. sdram_dual waits 12,100 cycles
// (114 us) of NOPs before its first command, sized for MiSTer's 3.3 V parts
// (100 us). The Pocket's 1.8 V low-power SDR family asks for 200 us after power
// and a stable clock. Hold the controller in init for a further 32,768 cycles
// (308 us) after PLL lock -- it issues only NOPs while init is high.
// target/pocket/core_top.sv's setup_done gate is sized to cover this too.
    reg  [15:0] sdram_pwr_cnt = 0;
    wire        sdram_pwr_ok  = sdram_pwr_cnt[15];
always @(posedge clk_ram)
    if (!pll_locked)         sdram_pwr_cnt <= 0;
    else if (!sdram_pwr_ok)  sdram_pwr_cnt <= sdram_pwr_cnt + 1'b1;

// SDRAM ch2: cart ROM and BIOS    (Jaguar.sv:1364-1446)
// =============================================================================
// BIOS lives at ch2 row 0x7F0000 with addr_ext set, cart at 0 (see the memory
// map comment at rtl/upstream/mem/sdram_dual.sv:22-36).
// ---- TEMPORARY load verifier ----------------------------
// The Pocket fails on the first launch after every power-on. Did the images
// actually land in SDRAM intact on that launch? Sum what the loader writes;
// when loading ends, hold the console in reset (controller self-refreshing),
// read every word back via ch2 with the sweep core's proven 40-cycle pacing,
// sum again, compare. About 0.8 s for a 4 MB cart.
    // (verifier registers are declared with the reset logic, which uses vf_busy)
    assign dbg_bios_diff = vf_sum_br[15:0] - vf_sum_bw[15:0];
    assign dbg_cart_diff = vf_sum_cr[15:0] - vf_sum_cw[15:0];
`ifdef POCKET_DIAG     // readback verifier: diagnostic builds only (vf_busy stays 0 otherwise)
always @(posedge clk_sys) begin
    vf_dl_old <= ld_busy;
    vf_req    <= 1'b0;
    if (download_active && !vf_dl_old) begin   // a new download began
        vf_sum_bw <= 0; vf_sum_cw <= 0; vf_nb <= 0; vf_nc <= 0; dbg_vf_done <= 1'b0;
    end
    if (loader_en && loader_wr) begin
        if (os_index) begin vf_sum_bw <= vf_sum_bw + loader_data_bs; vf_nb <= vf_nb + 1'b1; end
        else          begin vf_sum_cw <= vf_sum_cw + loader_data_bs; vf_nc <= vf_nc + 1'b1; end
    end
    if (vf_dl_old && !ld_busy) begin
        vf_busy <= 1'b1; vf_phase <= 1'b0; vf_idx <= 0; vf_t <= 0;
        vf_sum_br <= 0; vf_sum_cr <= 0;
    end else if (vf_busy) begin
        vf_t <= vf_t + 1'b1;
        if (vf_t == 6'd0) vf_req <= 1'b1;
        if (vf_t == 6'd40) begin
            vf_t <= 0;
            if (!vf_phase) vf_sum_br <= vf_sum_br + cart_qsc[31:16];
            else           vf_sum_cr <= vf_sum_cr + cart_qsc[31:16];
            if (!vf_phase && vf_idx + 1'b1 >= vf_nb) begin vf_phase <= 1'b1; vf_idx <= 0;
                if (vf_nc == 0) begin vf_busy <= 1'b0; dbg_vf_done <= 1'b1; end end
            else if (vf_phase && vf_idx + 1'b1 >= vf_nc) begin vf_busy <= 1'b0; dbg_vf_done <= 1'b1; end
            else vf_idx <= vf_idx + 1'b1;
        end
    end
end
`endif

    wire cart_rd_trig = !cart_ce_n && ram_read_req && (!old_ram_read_req || (abus_out != old_abus_out));
    // cart address into the image: 8 KB lower for a headerless dump.
    // Cart reads only: BIOS reads share this address path (os_rd_trig adds
    // 0x7F0000 below), and shifting them stopped the 68000 at its reset
    // vector -- caught in simulation before it reached hardware.
    wire [22:2] cart_abus = (cart_headerless && !cart_ce_n) ? (abus_out[22:2] - 21'h800)
                                                            : abus_out[22:2];
    wire os_rd_trig   = !os_ce_n   && ram_read_req && (!old_ram_read_req || (abus_out != old_abus_out));

    wire [23:1] cart_ch2_addr =
        vf_busy   ? ({1'b0, vf_idx} | (vf_phase ? 23'h000000 : 23'h7F0000)) :
        ld_busy   ? (lq_cur[38:16] | (lq_cur[39] ? 23'h7F0000 : 23'h000000))
                  : ({1'b0, cart_abus[22:20] & cart_mask[22:20], cart_abus[19:2], 1'b0}
                     | (os_rd_trig ? 23'h7F0000 : 23'h000000));
    wire        cart_ch2_addr_ext = vf_busy ? !vf_phase : ld_busy ? lq_cur[39] : os_rd_trig;
    wire [15:0] cart_ch2_din     = ld_busy ? lq_cur[15:0] : dram_d[15:0];
    wire        cart_ch2_req     = vf_busy ? vf_req : ld_busy ? lq_req : (os_rd_trig | cart_rd_trig);
    wire        cart_ch2_rnw     = vf_busy ? 1'b1 : ld_busy ? 1'b0 : 1'b1;
    wire [1:0]  cart_ch2_be      = (vf_busy || ld_busy) ? 2'b11
                                             : (abus_out[1] ? ch1_be[1:0] : ch1_be[3:2]);
    wire [31:0] cart_qsc;
    // Headerless dumps are loaded as-is at SDRAM 0, so
    // cart address A reads image offset A - 0x2000, and the missing first
    // 8 KB reads as a minimal universal header: 32-bit bus at 0x400, entry
    // point 0x802000 at 0x404, zeros elsewhere. The flags are latched at the
    // ROM-read trigger; the data is consumed several clocks later, after the
    // ch2 read (which still runs, harmlessly) completes.
    reg         hl_hdr = 1'b0;
    reg  [31:0] hl_val = 32'd0;
always @(posedge clk_sys) if (cart_rd_trig) begin
    hl_hdr <= cart_headerless && (abus_out[19:13] == 7'd0) && (abus_out[22:20] == 3'd0);
    hl_val <= (abus_out[12:2] == 11'h100) ? 32'h04040404
            : (abus_out[12:2] == 11'h101) ? 32'h00802000 : 32'h00000000;
end
    wire [31:0] cart_qs = hl_hdr ? hl_val : cart_qsc;
    wire        sdram_ch2_ready;

// Cart/BIOS ROM-cycle wait. Upstream ties Tom's xwaitl
// high, so a ROM cycle ends after MEMCON1's fixed ROMSPEED wait states whether
// or not SDRAM ch2 has delivered -- ch2 is served only from STATE_IDLE, behind
// every queued ch1 command and refresh, so under heavy DRAM traffic the cycle
// latches the PREVIOUS read's data. A real cart answers in time, so holding
// xwaitl low only while a ch2 read is outstanding costs nothing when SDRAM
// keeps up and turns a wrong read into a slightly late one when it does not.
    wire        ch2_rd_busy;

// ROM-read timing probe. Boot simulation never saw a
// late read (latency 5-8 clk); gameplay cannot be simulated in useful time,
// so measure on hardware. A ROM cycle runs from its trigger to the next
// trigger or the end of the read strobe; its shortest length is the
// programmed ROMSPEED. A read whose data took within 2 clk of that would have
// latched stale data with xwaitl tied high, so with the wait in place this
// counts the reads the wait rescued.
    reg  [7:0] rp_lat = 0, rp_cyc = 0;
    reg        rp_pend = 0, rp_open = 0, old_busy = 0;
    wire       rp_trig = os_rd_trig | cart_rd_trig;
always @(posedge clk_sys) begin
    old_busy <= ch2_rd_busy;
    if (rp_pend && ~&rp_lat) rp_lat <= rp_lat + 1'b1;
    if (rp_open && ~&rp_cyc) rp_cyc <= rp_cyc + 1'b1;
    if (rp_pend && old_busy && !ch2_rd_busy) begin
        rp_pend <= 1'b0;
        if (rp_lat > dbg_rom_maxlat) dbg_rom_maxlat <= rp_lat;
        if (rp_lat + 8'd2 >= dbg_rom_mincyc && ~&dbg_rom_late) dbg_rom_late <= dbg_rom_late + 1'b1;
    end
    if (rp_open && (rp_trig || !ram_read_req)) begin
        rp_open <= 1'b0;
        if (rp_cyc < dbg_rom_mincyc && rp_cyc > 8'd2) dbg_rom_mincyc <= rp_cyc;
    end
    if (rp_trig) begin
        rp_pend <= 1'b1; rp_open <= 1'b1; rp_lat <= 8'd1; rp_cyc <= 8'd1;
    end
    if (reset) begin
        rp_pend <= 1'b0; rp_open <= 1'b0;
        dbg_rom_maxlat <= 8'd0; dbg_rom_mincyc <= 8'hFF; dbg_rom_late <= 16'd0;
    end
end
`ifdef POCKET_NO_CART_WAIT
    assign      cart_xwaitl = 1'b1;               // upstream behaviour, for A/B
`else
    assign      cart_xwaitl = ~ch2_rd_busy;
`endif

// 8/16/32-bit cart data steering (Jaguar.sv:1200-1212).
    wire [3:0]  use_b;
    assign use_b[3:2] = cart_headerless ? 2'b00 : cart_b;   // headerless dumps: 32-bit
    assign use_b[1:0] = addr_b;
    assign cart_q[31:16] = cart_qs[31:16];
    assign cart_q[15:8]  = (use_b[2] && ~use_b[1]) ? cart_qs[31:24] : cart_qs[15:8];
    assign cart_q[7:0]   = (use_b == 4'b1000) ? cart_qs[31:24]
                         : (use_b == 4'b1001) ? cart_qs[23:16]
                         : (use_b == 4'b1010) ? cart_qs[15:8]
                         : (use_b == 4'b1011) ? cart_qs[7:0]
                         : (use_b == 4'b0100) ? cart_qs[23:16]
                         : (use_b == 4'b0101) ? cart_qs[23:16]
                         : (use_b == 4'b0110) ? cart_qs[7:0]
                         : (use_b == 4'b0111) ? cart_qs[7:0]
                         :                      cart_qs[7:0];

// The BIOS is read straight out of SDRAM ch2 -- no BRAM copy. (Jaguar.sv's
// fastcache2 path is dead code: its only selector, bios_overwrote, is a
// constant zero. See docs/08.) The patch rewrites the cart-checksum BEQ to a
// BRA; 0x136E is the K BIOS, 0x19C6 the M BIOS.
assign os_rom_q = (((abus_out[16:0] == 17'h0136E && !bios_m) ||
                    (abus_out[16:0] == 17'h019C6 &&  bios_m)) && patch_checksums)
                  ? 8'h60
                  : cart_qsc[8*(3-abus_out[1:0]) +: 8];


// =============================================================================
// SDRAM controller
// =============================================================================
    wire ram64;

sdram sdram (
    .init               ( ~pll_locked | ~sdram_pwr_ok ),
    .clk                ( clk_ram ),

    .SDRAM_DQ           ( dram_dq ),
    .SDRAM_A            ( dram_a ),
    .SDRAM_DQML         ( dram_dqm[0] ),
    .SDRAM_DQMH         ( dram_dqm[1] ),
    .SDRAM_BA           ( dram_ba ),
    .SDRAM_nCS          ( ),               // Pocket ties CS low on the board
    .SDRAM_nWE          ( dram_we_n ),
    .SDRAM_nRAS         ( dram_ras_n ),
    .SDRAM_nCAS         ( dram_cas_n ),
    .SDRAM_CKE          ( dram_cke ),
    .SDRAM_CLK          ( dram_clk ),

    .ch1_addr           ( dram_addressp[10:3] ),
    .ch1_caddr          ( {3'b000, dram_a_jag} ),
    .ch1_dout           ( {ch1_dout[63:48], ch1_dout[47:32], ch1_dout[31:16], ch1_dout[15:0]} ),
    .ch1_din            ( {ch1_din[63:48],  ch1_din[47:32],  ch1_din[31:16],  ch1_din[15:0]} ),
    .ch1_reqr           ( ch1_reqr ),
    .ch1_reqw           ( ch1_reqw ),
    .ch1_ref            ( ch1_ref ),
    .ch1_act            ( ch1_act ),
    .ch1_pch            ( ch1_pch ),
    .ch1_rnw            ( ch1_rnw ),
    .ch1_be             ( {ch1_be[7:6], ch1_be[5:4], ch1_be[3:2], ch1_be[1:0]} ),
    .ch1_ready          ( ch1a_ready ),
    .ch1_64             ( ch1_64 ),
    .ch1_ontime         ( ch1_ontime ),
    .ch1_rd_done        ( ch1_rd_done ),

    .ch2_addr           ( cart_ch2_addr ),
    .ch2_addr_ext       ( cart_ch2_addr_ext ),
    .ch2_dout           ( cart_qsc ),
    .ch2_din            ( cart_ch2_din ),
    .ch2_req            ( cart_ch2_req ),
    .ch2_rnw            ( cart_ch2_rnw ),
    .ch2_be             ( cart_ch2_be ),
    .ch2_ready          ( sdram_ch2_ready ),
    .ch2_rd_busy        ( ch2_rd_busy ),

    .ch3_addr           ( addr_ch3 ),
    .ch3_dout           ( ),
    .ch3_din            ( 32'h0 ),
    .ch3_req            ( 1'b1 ),
    .ch3_rnw            ( 1'b1 ),
    .ch3_ready          ( ),

    .ram64              ( ram64 ),
    .self_refresh       ( loader_en || !sdram_xresetlp )
);

endmodule

`default_nettype wire
