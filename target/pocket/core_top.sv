//
// Atari Jaguar for Analogue Pocket -- APF top-level core.
//
// Instantiated by platform/pocket/apf_top.v (do not modify that file).
//
// Derived from Analogue's core-template src/fpga/core/core_top.v. The port
// list, the cartridge/link-port level-translator defaults and the
// core_bridge_cmd instantiation are kept VERBATIM from the template: the
// translator directions in particular must be driven to safe values or
// hardware can be damaged.
//
// MILESTONE 1 SCOPE (docs/09, docs/10): this exists to reach quartus_map and
// then quartus_fit so docs/08's resource estimates can be replaced with
// measurements. Audio, PSRAM, SRAM, saves, CD and configuration are
// deliberately tied off. See the TIE-OFFS section.
//
`default_nettype none

module core_top (

//
// physical connections
//

///////////////////////////////////////////////////
// clock inputs 74.25mhz. not phase aligned, so treat these domains as asynchronous

input   wire            clk_74a, // mainclk1
input   wire            clk_74b, // mainclk1 

///////////////////////////////////////////////////
// cartridge interface
// switches between 3.3v and 5v mechanically
// output enable for multibit translators controlled by pic32

// GBA AD[15:8]
inout   wire    [7:0]   cart_tran_bank2,
output  wire            cart_tran_bank2_dir,

// GBA AD[7:0]
inout   wire    [7:0]   cart_tran_bank3,
output  wire            cart_tran_bank3_dir,

// GBA A[23:16]
inout   wire    [7:0]   cart_tran_bank1,
output  wire            cart_tran_bank1_dir,

// GBA [7] PHI#
// GBA [6] WR#
// GBA [5] RD#
// GBA [4] CS1#/CS#
//     [3:0] unwired
inout   wire    [7:4]   cart_tran_bank0,
output  wire            cart_tran_bank0_dir,

// GBA CS2#/RES#
inout   wire            cart_tran_pin30,
output  wire            cart_tran_pin30_dir,
// when GBC cart is inserted, this signal when low or weak will pull GBC /RES low with a special circuit
// the goal is that when unconfigured, the FPGA weak pullups won't interfere.
// thus, if GBC cart is inserted, FPGA must drive this high in order to let the level translators
// and general IO drive this pin.
output  wire            cart_pin30_pwroff_reset,

// GBA IRQ/DRQ
inout   wire            cart_tran_pin31,
output  wire            cart_tran_pin31_dir,

// infrared
input   wire            port_ir_rx,
output  wire            port_ir_tx,
output  wire            port_ir_rx_disable, 

// GBA link port
inout   wire            port_tran_si,
output  wire            port_tran_si_dir,
inout   wire            port_tran_so,
output  wire            port_tran_so_dir,
inout   wire            port_tran_sck,
output  wire            port_tran_sck_dir,
inout   wire            port_tran_sd,
output  wire            port_tran_sd_dir,
 
///////////////////////////////////////////////////
// cellular psram 0 and 1, two chips (64mbit x2 dual die per chip)

output  wire    [21:16] cram0_a,
inout   wire    [15:0]  cram0_dq,
input   wire            cram0_wait,
output  wire            cram0_clk,
output  wire            cram0_adv_n,
output  wire            cram0_cre,
output  wire            cram0_ce0_n,
output  wire            cram0_ce1_n,
output  wire            cram0_oe_n,
output  wire            cram0_we_n,
output  wire            cram0_ub_n,
output  wire            cram0_lb_n,

output  wire    [21:16] cram1_a,
inout   wire    [15:0]  cram1_dq,
input   wire            cram1_wait,
output  wire            cram1_clk,
output  wire            cram1_adv_n,
output  wire            cram1_cre,
output  wire            cram1_ce0_n,
output  wire            cram1_ce1_n,
output  wire            cram1_oe_n,
output  wire            cram1_we_n,
output  wire            cram1_ub_n,
output  wire            cram1_lb_n,

///////////////////////////////////////////////////
// sdram, 512mbit 16bit

output  wire    [12:0]  dram_a,
output  wire    [1:0]   dram_ba,
inout   wire    [15:0]  dram_dq,
output  wire    [1:0]   dram_dqm,
output  wire            dram_clk,
output  wire            dram_cke,
output  wire            dram_ras_n,
output  wire            dram_cas_n,
output  wire            dram_we_n,

///////////////////////////////////////////////////
// sram, 1mbit 16bit

output  wire    [16:0]  sram_a,
inout   wire    [15:0]  sram_dq,
output  wire            sram_oe_n,
output  wire            sram_we_n,
output  wire            sram_ub_n,
output  wire            sram_lb_n,

///////////////////////////////////////////////////
// vblank driven by dock for sync in a certain mode

input   wire            vblank,

///////////////////////////////////////////////////
// i/o to 6515D breakout usb uart

output  wire            dbg_tx,
input   wire            dbg_rx,

///////////////////////////////////////////////////
// i/o pads near jtag connector user can solder to

output  wire            user1,
input   wire            user2,

///////////////////////////////////////////////////
// RFU internal i2c bus 

inout   wire            aux_sda,
output  wire            aux_scl,

///////////////////////////////////////////////////
// RFU, do not use
output  wire            vpll_feed,


//
// logical connections
//

///////////////////////////////////////////////////
// video, audio output to scaler
output  wire    [23:0]  video_rgb,
output  wire            video_rgb_clock,
output  wire            video_rgb_clock_90,
output  wire            video_de,
output  wire            video_skip,
output  wire            video_vs,
output  wire            video_hs,
    
output  wire            audio_mclk,
input   wire            audio_adc,
output  wire            audio_dac,
output  wire            audio_lrck,

///////////////////////////////////////////////////
// bridge bus connection
// synchronous to clk_74a
output  wire            bridge_endian_little,
input   wire    [31:0]  bridge_addr,
input   wire            bridge_rd,
output  reg     [31:0]  bridge_rd_data,
input   wire            bridge_wr,
input   wire    [31:0]  bridge_wr_data,

///////////////////////////////////////////////////
// controller data
// 
// key bitmap:
//   [0]    dpad_up
//   [1]    dpad_down
//   [2]    dpad_left
//   [3]    dpad_right
//   [4]    face_a
//   [5]    face_b
//   [6]    face_x
//   [7]    face_y
//   [8]    trig_l1
//   [9]    trig_r1
//   [10]   trig_l2
//   [11]   trig_r2
//   [12]   trig_l3
//   [13]   trig_r3
//   [14]   face_select
//   [15]   face_start
//   [31:28] type
// joy values - unsigned
//   [ 7: 0] lstick_x
//   [15: 8] lstick_y
//   [23:16] rstick_x
//   [31:24] rstick_y
// trigger values - unsigned
//   [ 7: 0] ltrig
//   [15: 8] rtrig
//
input   wire    [31:0]  cont1_key,
input   wire    [31:0]  cont2_key,
input   wire    [31:0]  cont3_key,
input   wire    [31:0]  cont4_key,
input   wire    [31:0]  cont1_joy,
input   wire    [31:0]  cont2_joy,
input   wire    [31:0]  cont3_joy,
input   wire    [31:0]  cont4_joy,
input   wire    [15:0]  cont1_trig,
input   wire    [15:0]  cont2_trig,
input   wire    [15:0]  cont3_trig,
input   wire    [15:0]  cont4_trig
    
);

// not using the IR port, so turn off both the LED, and
// disable the receive circuit to save power
assign port_ir_tx = 0;
assign port_ir_rx_disable = 1;

// bridge endianness
assign bridge_endian_little = 0;

// cart is unused, so set all level translators accordingly
// directions are 0:IN, 1:OUT
assign cart_tran_bank3 = 8'hzz;
assign cart_tran_bank3_dir = 1'b0;
assign cart_tran_bank2 = 8'hzz;
assign cart_tran_bank2_dir = 1'b0;
assign cart_tran_bank1 = 8'hzz;
assign cart_tran_bank1_dir = 1'b0;
assign cart_tran_bank0 = 4'hf;
assign cart_tran_bank0_dir = 1'b1;
assign cart_tran_pin30 = 1'b0;      // reset or cs2, we let the hw control it by itself
assign cart_tran_pin30_dir = 1'bz;
assign cart_pin30_pwroff_reset = 1'b0;  // hardware can control this
assign cart_tran_pin31 = 1'bz;      // input
assign cart_tran_pin31_dir = 1'b0;  // input

// link port is unused, set to input only to be safe
// each bit may be bidirectional in some applications
assign port_tran_so = 1'bz;
assign port_tran_so_dir = 1'b0;     // SO is output only
assign port_tran_si = 1'bz;
assign port_tran_si_dir = 1'b0;     // SI is input only
assign port_tran_sck = 1'bz;
assign port_tran_sck_dir = 1'b0;    // clock direction can change
assign port_tran_sd = 1'bz;
assign port_tran_sd_dir = 1'b0;     // SD is input and not used

// tie off the rest of the pins we are not using
// assign cram0_a = 'h0;   // driven by the core (see below)
// assign cram0_dq = {16{1'bZ}};   // driven by the core (see below)
// assign cram0_clk = 0;   // driven by the core (see below)
// assign cram0_adv_n = 1;   // driven by the core (see below)
// assign cram0_cre = 0;   // driven by the core (see below)
// assign cram0_ce0_n = 1;   // driven by the core (see below)
// assign cram0_ce1_n = 1;   // driven by the core (see below)
// assign cram0_oe_n = 1;   // driven by the core (see below)
// assign cram0_we_n = 1;   // driven by the core (see below)
// assign cram0_ub_n = 1;   // driven by the core (see below)
// assign cram0_lb_n = 1;   // driven by the core (see below)

// assign cram1_a = 'h0;   // driven by the core (see below)
// assign cram1_dq = {16{1'bZ}};   // driven by the core (see below)
// assign cram1_clk = 0;   // driven by the core (see below)
// assign cram1_adv_n = 1;   // driven by the core (see below)
// assign cram1_cre = 0;   // driven by the core (see below)
// assign cram1_ce0_n = 1;   // driven by the core (see below)
// assign cram1_ce1_n = 1;   // driven by the core (see below)
// assign cram1_oe_n = 1;   // driven by the core (see below)
// assign cram1_we_n = 1;   // driven by the core (see below)
// assign cram1_ub_n = 1;   // driven by the core (see below)
// assign cram1_lb_n = 1;   // driven by the core (see below)

// assign dram_a = 'h0;   // driven by the core (see below)
// assign dram_ba = 'h0;   // driven by the core (see below)
// assign dram_dq = {16{1'bZ}};   // driven by the core (see below)
// assign dram_dqm = 'h0;   // driven by the core (see below)
// assign dram_clk = 'h0;   // driven by the core (see below)
// assign dram_cke = 'h0;   // driven by the core (see below)
// assign dram_ras_n = 'h1;   // driven by the core (see below)
// assign dram_cas_n = 'h1;   // driven by the core (see below)
// assign dram_we_n = 'h1;   // driven by the core (see below)

assign dbg_tx = 1'bZ;
assign user1 = 1'bZ;
assign aux_scl = 1'bZ;
assign vpll_feed = 1'bZ;


// --- template bridge_rd_data mux replaced below ---
//
// host/target command handler
//
    wire            reset_n;                // driven by host commands, can be used as core-wide reset
    wire    [31:0]  cmd_bridge_rd_data;
    
// bridge host commands
// synchronous to clk_74a
    // Both wait for the SDRAM controller's power-up sequence, not just PLL lock.
    // The host starts writing data slots once setup is done, and sdram_dual
    // keeps only ONE pending request while in STATE_STARTUP (~12,100 clk_sys,
    // 114 us), so earlier writes are lost -- the first BIOS words are the
    // 68000 reset vectors.
    wire            sdram_ready_74;
    wire            status_boot_done  = pll_core_locked_s & sdram_ready_74;
    wire            status_setup_done = pll_core_locked_s & sdram_ready_74; // rising edge triggers a target command
    wire            status_running = reset_n; // we are running as soon as reset_n goes high

    wire            dataslot_requestread;
    wire    [15:0]  dataslot_requestread_id;
    wire            dataslot_requestread_ack = 1;
    wire            dataslot_requestread_ok = 1;

    wire            dataslot_requestwrite;
    wire    [15:0]  dataslot_requestwrite_id;
    wire    [31:0]  dataslot_requestwrite_size;
    wire            dataslot_requestwrite_ack = 1;
    wire            dataslot_requestwrite_ok = 1;

    wire            dataslot_update;
    wire    [15:0]  dataslot_update_id;
    wire    [31:0]  dataslot_update_size;
    
    wire            dataslot_allcomplete;

    wire     [31:0] rtc_epoch_seconds;
    wire     [31:0] rtc_date_bcd;
    wire     [31:0] rtc_time_bcd;
    wire            rtc_valid;

    wire            savestate_supported;
    wire    [31:0]  savestate_addr;
    wire    [31:0]  savestate_size;
    wire    [31:0]  savestate_maxloadsize;

    wire            savestate_start;
    wire            savestate_start_ack;
    wire            savestate_start_busy;
    wire            savestate_start_ok;
    wire            savestate_start_err;

    wire            savestate_load;
    wire            savestate_load_ack;
    wire            savestate_load_busy;
    wire            savestate_load_ok;
    wire            savestate_load_err;
    
    wire            osnotify_inmenu;

// bridge target commands
// synchronous to clk_74a

    wire             target_dataslot_read = 0;   // M1: core initiates no slot access (docs/02)
    wire             target_dataslot_write = 0;   // M1: core initiates no slot access (docs/02)
    wire             target_dataslot_getfile = 0;   // M1: core initiates no slot access (docs/02)
    wire             target_dataslot_openfile = 0;   // M1: core initiates no slot access (docs/02)
    
    wire            target_dataslot_ack;        
    wire            target_dataslot_done;
    wire    [2:0]   target_dataslot_err;

    wire     [15:0]  target_dataslot_id = 0;   // M1: core initiates no slot access (docs/02)
    wire     [31:0]  target_dataslot_slotoffset = 0;   // M1: core initiates no slot access (docs/02)
    wire     [31:0]  target_dataslot_bridgeaddr = 0;   // M1: core initiates no slot access (docs/02)
    wire     [31:0]  target_dataslot_length = 0;   // M1: core initiates no slot access (docs/02)
    
    wire    [31:0]  target_buffer_param_struct; // to be mapped/implemented when using some Target commands
    wire    [31:0]  target_buffer_resp_struct;  // to be mapped/implemented when using some Target commands
    
// bridge data slot access
// synchronous to clk_74a

    wire    [9:0]   datatable_addr;
    wire            datatable_wren;
    wire    [31:0]  datatable_data;
    wire    [31:0]  datatable_q;

core_bridge_cmd icb (

    .clk                ( clk_74a ),
    .reset_n            ( reset_n ),

    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_rd              ( bridge_rd ),
    .bridge_rd_data         ( cmd_bridge_rd_data ),
    .bridge_wr              ( bridge_wr ),
    .bridge_wr_data         ( bridge_wr_data ),
    
    .status_boot_done       ( status_boot_done ),
    .status_setup_done      ( status_setup_done ),
    .status_running         ( status_running ),

    .dataslot_requestread       ( dataslot_requestread ),
    .dataslot_requestread_id    ( dataslot_requestread_id ),
    .dataslot_requestread_ack   ( dataslot_requestread_ack ),
    .dataslot_requestread_ok    ( dataslot_requestread_ok ),

    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
    .dataslot_requestwrite_ack  ( dataslot_requestwrite_ack ),
    .dataslot_requestwrite_ok   ( dataslot_requestwrite_ok ),

    .dataslot_update            ( dataslot_update ),
    .dataslot_update_id         ( dataslot_update_id ),
    .dataslot_update_size       ( dataslot_update_size ),
    
    .dataslot_allcomplete   ( dataslot_allcomplete ),

    .rtc_epoch_seconds      ( rtc_epoch_seconds ),
    .rtc_date_bcd           ( rtc_date_bcd ),
    .rtc_time_bcd           ( rtc_time_bcd ),
    .rtc_valid              ( rtc_valid ),
    
    .savestate_supported    ( savestate_supported ),
    .savestate_addr         ( savestate_addr ),
    .savestate_size         ( savestate_size ),
    .savestate_maxloadsize  ( savestate_maxloadsize ),

    .savestate_start        ( savestate_start ),
    .savestate_start_ack    ( savestate_start_ack ),
    .savestate_start_busy   ( savestate_start_busy ),
    .savestate_start_ok     ( savestate_start_ok ),
    .savestate_start_err    ( savestate_start_err ),

    .savestate_load         ( savestate_load ),
    .savestate_load_ack     ( savestate_load_ack ),
    .savestate_load_busy    ( savestate_load_busy ),
    .savestate_load_ok      ( savestate_load_ok ),
    .savestate_load_err     ( savestate_load_err ),

    .osnotify_inmenu        ( osnotify_inmenu ),
    
    .target_dataslot_read       ( target_dataslot_read ),
    .target_dataslot_write      ( target_dataslot_write ),
    .target_dataslot_getfile    ( target_dataslot_getfile ),
    .target_dataslot_openfile   ( target_dataslot_openfile ),
    
    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err ),

    .target_dataslot_id         ( target_dataslot_id ),
    .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
    .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
    .target_dataslot_length     ( target_dataslot_length ),

    .target_buffer_param_struct ( target_buffer_param_struct ),
    .target_buffer_resp_struct  ( target_buffer_resp_struct ),
    
    .datatable_addr         ( datatable_addr ),
    .datatable_wren         ( datatable_wren ),
    .datatable_data         ( datatable_data ),
    .datatable_q            ( datatable_q )

);

// =============================================================================
// Bridge address map
// =============================================================================
// 0x0xxxxxxx  core control / config registers (written by APF from
//             interact.json; M1 uses compile-time defaults instead)
// 0x1xxxxxxx  Cartridge ROM     data slot 1  -> data_loader
// 0x2xxxxxxx  Jaguar BIOS       data slot 2  -> data_loader
// 0x3xxxxxxx  EEPROM save       data slot 10 -> save data_loader / data_unloader
// 0xF8xxxxxx  core_bridge_cmd   (APF reserved)
//
// All bridge_* signals are synchronous to clk_74a.

    wire    [31:0]  save_bridge_rd_data;
always @(*) begin
    casex (bridge_addr)
    default:        bridge_rd_data <= 0;
    32'h3xxxxxxx:   bridge_rd_data <= save_bridge_rd_data;
    32'hF8xxxxxx:   bridge_rd_data <= cmd_bridge_rd_data;
    endcase
end


// =============================================================================
// Reset
// =============================================================================
// reset_n arrives from the host in clk_74a. Bring it into clk_sys and hold the
// core in reset until the PLL has locked.
    wire            pll_core_locked;
    wire            pll_core_locked_s;
synch_3 s_pll_lock (pll_core_locked, pll_core_locked_s, clk_74a);

    wire            reset_n_s;
synch_3 s_reset_n  (reset_n, reset_n_s, clk_sys);

    wire            core_reset = ~reset_n_s | ~pll_core_locked;

// SDRAM power-up guard. jaguar_top holds sdram_dual in init for 32,768
// clk_sys after lock (low-power part: 200 us), then its startup takes
// sdram_startup_cycles = 12,100; 65,536 (616 us) covers both with margin.
    reg     [16:0]  sdram_up_cnt = 0;
    wire            sdram_ready  = sdram_up_cnt[16];
always @(posedge clk_sys)
    if (!pll_core_locked)  sdram_up_cnt <= 0;
    else if (!sdram_ready) sdram_up_cnt <= sdram_up_cnt + 1'b1;
synch_3 s_sdram_ready (sdram_ready, sdram_ready_74, clk_74a);


// =============================================================================
// ROM / BIOS loading   (docs/05)
// =============================================================================
// data_loader converts APF's 32-bit big-endian bridge writes into the 16-bit
// write stream that Jaguar_MiSTer's loader state machine already expects, and
// crosses clk_74a -> clk_sys internally. OUTPUT_WORD_SIZE = 2 matches MiSTer's
// ioctl_data width.
//
// APF has no back-pressure channel. docs/05 section 5.4 shows that is fine:
// APF delivers a word roughly every 75 clk_74a cycles (~107 clk_sys cycles)
// and a 16-bit SDRAM ch2 write costs ~6 clk_sys cycles -- about 9x headroom --
// so MiSTer's ioctl_wait path is simply dropped.

    wire            cart_wr;
    wire    [24:0]  cart_addr;
    wire    [15:0]  cart_data;

data_loader #(
    .ADDRESS_MASK_UPPER_4   ( 4'h1 ),
    .ADDRESS_SIZE           ( 25 ),
    .OUTPUT_WORD_SIZE       ( 2 )
) cart_loader (
    .clk_74a                ( clk_74a ),
    .clk_memory             ( clk_sys ),
    .bridge_wr              ( bridge_wr ),
    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_wr_data         ( bridge_wr_data ),
    .write_en               ( cart_wr ),
    .write_addr             ( cart_addr ),
    .write_data             ( cart_data )
);

    wire            bios_wr;
    wire    [24:0]  bios_addr;
    wire    [15:0]  bios_data;

data_loader #(
    .ADDRESS_MASK_UPPER_4   ( 4'h2 ),
    .ADDRESS_SIZE           ( 25 ),
    .OUTPUT_WORD_SIZE       ( 2 )
) bios_loader (
    .clk_74a                ( clk_74a ),
    .clk_memory             ( clk_sys ),
    .bridge_wr              ( bridge_wr ),
    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_wr_data         ( bridge_wr_data ),
    .write_en               ( bios_wr ),
    .write_addr             ( bios_addr ),
    .write_data             ( bios_data )
);

// ---- EEPROM save slot -----------------------------------
// The 93C46 model's backing RAM (jaguar_top port B) is exposed as APF's
// nonvolatile "Save" slot: filled at load like any slot, read back over the
// bridge when the host unloads it. Words are big-endian in the .sav file, with
// the same byte swap both ways so a round trip is exact.
    wire            save_wr;
    wire    [11:0]  save_waddr_b, save_raddr_b;
    wire    [15:0]  save_wdata_le, save_rdata;
    wire            save_rd;
data_loader #(
    .ADDRESS_MASK_UPPER_4   ( 4'h3 ),
    .ADDRESS_SIZE           ( 12 ),
    .OUTPUT_WORD_SIZE       ( 2 )
) save_loader (
    .clk_74a                ( clk_74a ),
    .clk_memory             ( clk_sys ),
    .bridge_wr              ( bridge_wr ),
    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_wr_data         ( bridge_wr_data ),
    .write_en               ( save_wr ),
    .write_addr             ( save_waddr_b ),
    .write_data             ( save_wdata_le )
);
data_unloader #(
    .ADDRESS_MASK_UPPER_4   ( 4'h3 ),
    .ADDRESS_SIZE           ( 12 ),
    .READ_MEM_CLOCK_DELAY   ( 4 ),
    .INPUT_WORD_SIZE        ( 2 )
) save_unloader (
    .clk_74a                ( clk_74a ),
    .clk_memory             ( clk_sys ),
    .bridge_rd              ( bridge_rd ),
    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_rd_data         ( save_bridge_rd_data ),
    .read_en                ( save_rd ),
    .read_addr              ( save_raddr_b ),
    .read_data              ( {save_rdata[7:0], save_rdata[15:8]} )
);

// Stand-in for MiSTer's ioctl_download/ioctl_index. APF signals the start of a
// slot transfer with dataslot_requestwrite and the end of ALL transfers with
// dataslot_allcomplete, so the "download active" flag has to be latched.
reg             download_active = 0;
always @(posedge clk_74a) begin
    if (dataslot_requestwrite)      download_active <= 1;
    else if (dataslot_allcomplete)  download_active <= 0;
end

    wire            download_active_s;
synch_3 s_dl_active (download_active, download_active_s, clk_sys);

// FAST_SDRAM cache regions from the Pocket menu (interact.json):
// 0x40000000 = cache A, 0x40000004 = cache B, each a 256 KB region 0-7
// of the 2 MB DRAM. jaguar_top only takes them while the console is in reset,
// so a quasi-static 2-FF sync is enough.
// 0x40000008 / 0x4000000C = SRAM caches C / D, 0x40000010 = SRAM cache on/off
// (Stage B). Defaults A=7 B=6 C=4 D=5: the four regions
// Rayman reads most, so a fresh install starts with them.
reg [2:0] cache_a_74 = 3'd7, cache_b_74 = 3'd6, cache_c_74 = 3'd4, cache_d_74 = 3'd5;
reg       sram_en_74 = 1'b0;   // off by default (the SRAM cache is shelved)
// Controls: 0x40000018 L button key, 0x4000001C R button key
// (0 *, 1 #, 2 '0', 3..11 '1'..'9'), 0x40000020 keypad modifier (1 = Select).
reg [3:0] lkey_74 = 4'd0, rkey_74 = 4'd1, xkey_74 = 4'd2;   // 0x40000024: X button key (12 = none)
reg       kshift_74 = 1'b1;
always @(posedge clk_74a) if (bridge_wr) begin
    if (bridge_addr == 32'h40000000) cache_a_74 <= bridge_wr_data[2:0];
    if (bridge_addr == 32'h40000004) cache_b_74 <= bridge_wr_data[2:0];
    if (bridge_addr == 32'h40000008) cache_c_74 <= bridge_wr_data[2:0];
    if (bridge_addr == 32'h4000000C) cache_d_74 <= bridge_wr_data[2:0];
    if (bridge_addr == 32'h40000010) sram_en_74 <= bridge_wr_data[0];
    if (bridge_addr == 32'h40000018) lkey_74    <= bridge_wr_data[3:0];
    if (bridge_addr == 32'h4000001C) rkey_74    <= bridge_wr_data[3:0];
    if (bridge_addr == 32'h40000020) kshift_74  <= bridge_wr_data[0];
    if (bridge_addr == 32'h40000024) xkey_74    <= bridge_wr_data[3:0];
end
reg [2:0] cache_a_s1 = 3'd7, cache_a_s = 3'd7, cache_b_s1 = 3'd6, cache_b_s = 3'd6;
reg [2:0] cache_c_s1 = 3'd4, cache_c_s = 3'd4, cache_d_s1 = 3'd5, cache_d_s = 3'd5;
reg       sram_en_s1 = 1'b0, sram_en_s = 1'b0;
reg [3:0] lkey_s1 = 4'd0, lkey_s = 4'd0, rkey_s1 = 4'd1, rkey_s = 4'd1, xkey_s1 = 4'd2, xkey_s = 4'd2;
reg       kshift_s1 = 1'b1, kshift_s = 1'b1;
always @(posedge clk_sys) begin
    cache_a_s1 <= cache_a_74;  cache_a_s <= cache_a_s1;
    cache_b_s1 <= cache_b_74;  cache_b_s <= cache_b_s1;
    cache_c_s1 <= cache_c_74;  cache_c_s <= cache_c_s1;
    cache_d_s1 <= cache_d_74;  cache_d_s <= cache_d_s1;
    sram_en_s1 <= sram_en_74;  sram_en_s <= sram_en_s1;
    lkey_s1    <= lkey_74;     lkey_s    <= lkey_s1;
    rkey_s1    <= rkey_74;     rkey_s    <= rkey_s1;
    kshift_s1  <= kshift_74;   kshift_s  <= kshift_s1;
    xkey_s1    <= xkey_74;     xkey_s    <= xkey_s1;
end


// =============================================================================
// Controllers  (Pocket cont*_key -> Jaguar_MiSTer joystick bit order)
// =============================================================================
// Pocket: [0]up [1]down [2]left [3]right [4]A [5]B [6]X [7]Y [8]L1 [9]R1
//         [10]L2 [11]R2 [12]L3 [13]R3 [14]select [15]start
// Jaguar: [0]right [1]left [2]down [3]up [4]A [5]B [6]C [7]Option [8]Pause
//         [9..18] keypad 1-9,0  [19]star  [20]hash   (jaguar.v:804-824)
// Mapping, keypad layer and menu options: target/pocket/pad_map.sv.
// Buttons need no coherency, so a plain per-bit 2-FF sync into clk_sys.
    reg [15:0] c1_s1 = 0, c1_s2 = 0, c2_s1 = 0, c2_s2 = 0;
always @(posedge clk_sys) begin
    c1_s1 <= cont1_key[15:0];  c1_s2 <= c1_s1;
    c2_s1 <= cont2_key[15:0];  c2_s2 <= c2_s1;
end
    wire [31:0] joy0, joy1;
pad_map pad1 (.clk(clk_sys), .k(c1_s2), .l_key(lkey_s), .r_key(rkey_s), .x_key(xkey_s), .shift_en(kshift_s), .jag(joy0));
pad_map pad2 (.clk(clk_sys), .k(c2_s2), .l_key(lkey_s), .r_key(rkey_s), .x_key(xkey_s), .shift_en(kshift_s), .jag(joy1));
    wire        dbg_os_seen;
    wire        dbg_vf_done;
    wire [15:0] dbg_bios_diff, dbg_cart_diff;
    wire        dbg_lq_ovf;
    wire [7:0]  dbg_rom_maxlat, dbg_rom_mincyc;
    wire [15:0] dbg_rom_late;
    wire        dbg_rd, dbg_stall;
    wire [4:0]  dbg_rd_region;
    wire [2:0]  dbg_cache_a, dbg_cache_b;
    wire [31:0] dbg_cached_blocks;
    wire [7:0]  dbg_reassign;
    wire [2:0]  dbg_cache_c, dbg_cache_d;
    wire        dbg_sram_disabled;
    wire [15:0] dbg_sram_hits, dbg_sram_fallbacks;
    wire [3:0]  dbg_sram_qmax;
    wire        dbg_sram_bist_done;
    wire [15:0] dbg_sram_bist_err, dbg_sram_bist_w2;
    wire        vid_fallback;     // jaguar_video: no console sync, blank raster
    wire [23:0] video_rgb_jv;     // jaguar_video output, before the diagnostic overlay


// =============================================================================
// The console
// =============================================================================
    wire    [7:0]   vga_r, vga_g, vga_b;
    // NB: `vblank` alone is an APF *input port* of core_top (dock-driven sync),
    // so the console's blanking outputs must carry a prefix.
    wire            vga_hs, vga_vs, jag_hblank, jag_vblank, vid_ce, interlaced;
    wire    [15:0]  aud_l, aud_r;

jaguar_top jaguar_top (
    .clk_sys            ( clk_sys ),
    .clk_ram            ( clk_sys ),      // docs/03: clk_ram == clk_sys == 106.363636 MHz
    .pll_locked         ( pll_core_locked ),
    .reset              ( core_reset ),

    // ROM / BIOS loading (docs/05)
    .cart_wr            ( cart_wr ),
    .cart_addr          ( cart_addr ),
    .cart_data          ( cart_data ),
    .bios_wr            ( bios_wr ),
    .bios_addr          ( bios_addr ),
    .bios_data          ( bios_data ),
    .download_active    ( download_active_s ),

    // SDRAM (docs/04 Stage A: ch1 Jaguar DRAM + ch2 cart/BIOS on one chip)
    .dram_a             ( dram_a ),
    .dram_ba            ( dram_ba ),
    .dram_dq            ( dram_dq ),
    .dram_dqm           ( dram_dqm ),
    .dram_clk           ( dram_clk ),
    .dram_cke           ( dram_cke ),
    .dram_ras_n         ( dram_ras_n ),
    .dram_cas_n         ( dram_cas_n ),
    .dram_we_n          ( dram_we_n ),

    // Video, in the clk_sys CE domain (docs/06)
    .vga_r              ( vga_r ),
    .vga_g              ( vga_g ),
    .vga_b              ( vga_b ),
    .vga_hs             ( vga_hs ),
    .vga_vs             ( vga_vs ),
    .hblank             ( jag_hblank ),
    .vblank             ( jag_vblank ),
    .vid_ce             ( vid_ce ),
    .interlaced         ( interlaced ),

    // Audio (docs/06); tied off at the APF pins until M6
    .aud_l              ( aud_l ),
    .aud_r              ( aud_r ),

    // Controls (docs/07); all constant for M1
    .save_wr            ( save_wr ),
    .save_waddr         ( save_waddr_b[10:1] ),
    .save_wdata         ( {save_wdata_le[7:0], save_wdata_le[15:8]} ),
    .save_raddr         ( save_raddr_b[10:1] ),
    .save_rdata         ( save_rdata ),
    .joystick_0         ( joy0 ),
    .joystick_1         ( joy1 ),
    .cache_a_sel        ( cache_a_s ),
    .cache_b_sel        ( cache_b_s ),
    .cache_c_sel        ( cache_c_s ),
    .cache_d_sel        ( cache_d_s ),
    .sram_cache_en      ( sram_en_s ),
`ifdef POCKET_DIAG
    .sram_bist_en       ( 1'b1 ),
`else
    .sram_bist_en       ( 1'b0 ),
`endif
    .sram_a             ( sram_a ),
    .sram_dq            ( sram_dq ),
    .sram_oe_n          ( sram_oe_n ),
    .sram_we_n          ( sram_we_n ),
    .sram_ub_n          ( sram_ub_n ),
    .sram_lb_n          ( sram_lb_n ),
    .dbg_os_seen        ( dbg_os_seen ),
    .dbg_vf_done        ( dbg_vf_done ),
    .dbg_bios_diff      ( dbg_bios_diff ),
    .dbg_cart_diff      ( dbg_cart_diff ),
    .dbg_lq_ovf         ( dbg_lq_ovf ),
    .dbg_rom_maxlat     ( dbg_rom_maxlat ),
    .dbg_rom_mincyc     ( dbg_rom_mincyc ),
    .dbg_rom_late       ( dbg_rom_late ),
    .dbg_rd             ( dbg_rd ),
    .dbg_rd_region      ( dbg_rd_region ),
    .dbg_stall          ( dbg_stall ),
    .dbg_cache_a        ( dbg_cache_a ),
    .dbg_cache_b        ( dbg_cache_b ),
    .dbg_cached_blocks  ( dbg_cached_blocks ),
    .dbg_reassign       ( dbg_reassign ),
    .dbg_cache_c        ( dbg_cache_c ),
    .dbg_cache_d        ( dbg_cache_d ),
    .dbg_sram_disabled  ( dbg_sram_disabled ),
    .dbg_sram_hits      ( dbg_sram_hits ),
    .dbg_sram_fallbacks ( dbg_sram_fallbacks ),
    .dbg_sram_qmax      ( dbg_sram_qmax ),
    .dbg_sram_bist_done ( dbg_sram_bist_done ),
    .dbg_sram_bist_err  ( dbg_sram_bist_err ),
    .dbg_sram_bist_w2   ( dbg_sram_bist_w2 )
);


// =============================================================================
// Video out   (docs/06)
// =============================================================================
assign video_rgb_clock    = clk_vid;
assign video_rgb_clock_90 = clk_vid_90;

jaguar_video jaguar_video (
    .clk_sys    ( clk_sys ),
    .vid_ce     ( vid_ce ),
    .vga_r      ( vga_r ),
    .vga_g      ( vga_g ),
    .vga_b      ( vga_b ),
    .vga_hs     ( vga_hs ),
    .vga_vs     ( vga_vs ),
    .hblank     ( jag_hblank ),
    .vblank     ( jag_vblank ),

    .clk_vid    ( clk_vid ),
    .video_rgb  ( video_rgb_jv ),
    .video_de   ( video_de ),
    .video_skip ( video_skip ),
    .fallback   ( vid_fallback ),
    .video_hs   ( video_hs ),
    .video_vs   ( video_vs )
);


// -----------------------------------------------------------------------------
// DIAGNOSTIC overlay, shown only in POCKET_DIAG builds.
// Five rows of 16 squares at the top-left, bit 15 on the left, white = 1,
// dark grey = 0, plus a 17th flag square. jaguar_video's fallback raster keeps
// this visible even when the console never produces sync.
//   row 0  SRAM cache: reads served from the SRAM
//          (16-bit, saturating). flag: green = SRAM cache on, grey = off
//   row 1  BIOS words written >> 4   (128 KB BIOS = 0x1000).  flag: green if 0x1000
//   row 2  cart words written >> 8   (4 MB cart  = 0x2000).   flag: green if nonzero
//   row 3  status: [15] pll_locked [14] sdram_ready [13] reset_n (host)
//          [12] download_active [11] core_reset [10] 68000 selected BIOS
//          [9] console VS seen [8] fallback raster now
//          [7] loader write queue OVERFLOWED (writes lost)  [6:4] dataslot_requestwrite count
//          [3:0] dataslot_allcomplete count
//          flag: green = BIOS reached and VS seen
//   row 4  SRAM write self-test: words wrong after
//          writing with the cache's own timing (WE low 2 clk), 16-bit.
//          flag: blue = running, green = 0, red = errors
//   row 5  SRAM cache: [15:12] deepest write queue seen (8 = full)
//          [0] DISABLED (queue overflowed; all reads via SDRAM until reload)
//          flag: green = healthy, red = disabled
//   row 6  SRAM write self-test, one nibble per WE-low width, left to
//          right W = 1, 2, 3, 6 clk (F = 15+), read back at L = 4.
//          flag: as row 4, for all four. (Was the region list, and before
//          that the SRAM probe of 0.0.15-0.0.17.)
    reg     [25:0]  diag_t = 0;
    reg     [15:0]  diag_first = 0, diag_rel = 0;
    reg             diag_seen = 0, diag_early = 0, diag_relseen = 0;
    reg     [19:0]  diag_bios = 0;
    reg     [23:0]  diag_cart = 0;
    reg             diag_vs = 0, diag_vs_old = 0;
always @(posedge clk_sys) begin
    if (!pll_core_locked) begin
        diag_t <= 0; diag_seen <= 0; diag_early <= 0; diag_first <= 0;
        diag_rel <= 0; diag_relseen <= 0; diag_bios <= 0; diag_cart <= 0;
        diag_vs <= 0;
    end else begin
        if (~&diag_t) diag_t <= diag_t + 1'b1;
        if (!diag_seen && (cart_wr || bios_wr)) begin
            diag_seen  <= 1'b1;
            diag_first <= diag_t[25:10];
            diag_early <= !sdram_ready;
        end
        if (!diag_relseen && reset_n_s) begin
            diag_relseen <= 1'b1;
            diag_rel     <= diag_t[25:10];
        end
        if (bios_wr && ~&diag_bios) diag_bios <= diag_bios + 1'b1;
        if (cart_wr && ~&diag_cart) diag_cart <= diag_cart + 1'b1;
        diag_vs_old <= vga_vs;
        if (vga_vs && !diag_vs_old) diag_vs <= 1'b1;
    end
end
    // host command counters, in clk_74a
    reg [3:0] diag_nreq = 0, diag_nall = 0;
    reg       diag_rq_old = 0, diag_ac_old = 0;
always @(posedge clk_74a) begin
    diag_rq_old <= dataslot_requestwrite;
    diag_ac_old <= dataslot_allcomplete;
    if (dataslot_requestwrite && !diag_rq_old && ~&diag_nreq) diag_nreq <= diag_nreq + 1'b1;
    if (dataslot_allcomplete  && !diag_ac_old && ~&diag_nall) diag_nall <= diag_nall + 1'b1;
end
    // Quasi-static values read across domains for display only.
    wire [15:0] diag_status = {pll_core_locked, sdram_ready, reset_n_s, download_active_s,
                               core_reset, dbg_os_seen, diag_vs, vid_fallback,
                               dbg_lq_ovf, diag_nreq[2:0], diag_nall};
    reg  [15:0] drow_val;
    reg  [23:0] dflag;
    // Position in the APF raster, counted on written pixels.
    reg [9:0] dx = 0;
    reg [8:0] dy = 0;
    reg       dde = 0;
always @(posedge clk_vid) begin
    dde <= video_de;
    if (video_vs) dy <= 0;
    else if (dde && !video_de) dy <= dy + 1'b1;
    if (!video_de) dx <= 0;
    else if (!video_skip) dx <= dx + 1'b1;
end
    wire [4:0] dcell = dx[9:3];                 // 8-pixel cells
    wire [8:0] dyr   = dy - 9'd4;               // rows start at line 4, 8 lines apart
    wire [2:0] drix  = dyr[6:3];
    wire       drow  = (dy >= 9'd4) && (dy < 9'd60) && (dyr[2:0] < 3'd6);
    wire       dbox  = drow && (dx[2:0] >= 3'd1) && (dx[2:0] <= 3'd6) && (dx < 10'd136);
    localparam [23:0] GRN = 24'h00C000, RED = 24'hE00000, BLU = 24'h0000C0;
always @(*) begin
    case (drix)
      3'd0: begin drow_val = dbg_sram_hits;
                  dflag = sram_en_s ? GRN : 24'h404040; end
      3'd1: begin drow_val = diag_bios[19:4];
                  dflag = (diag_bios[19:4] == 16'h1000) ? GRN : RED; end
      3'd2: begin drow_val = diag_cart[23:8];
                  dflag = (diag_cart != 0) ? GRN : RED; end
      3'd3: begin drow_val = diag_status;
                  dflag = (dbg_os_seen && diag_vs) ? GRN : RED; end
      3'd4: begin drow_val = dbg_sram_bist_w2;
                  dflag = !dbg_sram_bist_done ? BLU : (dbg_sram_bist_w2 == 0) ? GRN : RED; end
      3'd5: begin drow_val = {dbg_sram_qmax, 11'd0, dbg_sram_disabled};
                  dflag = dbg_sram_disabled ? RED : GRN; end
      default: begin drow_val = dbg_sram_bist_err;
                  dflag = !dbg_sram_bist_done ? BLU : (dbg_sram_bist_err == 0) ? GRN : RED; end
    endcase
end
    wire [23:0] dcol = (dcell == 5'd16) ? dflag
                     : drow_val[5'd15 - dcell[3:0]] ? 24'hFFFFFF : 24'h404040;

// DRAM read traffic by block. Under the squares,
// 33 bars, 4 lines apart, log2 scale (16 px per doubling, dim tick every
// 32 px = 4x):
//   bars 0-31  Tom DRAM reads in each 64 KB block (0x000000, 0x010000, ...
//              0x1F0000) per window. Green = inside a cached 256 KB region,
//              red = not. The background alternates every four bars, one
//              shade per 256 KB region, so regions 0-7 can be told apart.
//   bar  32    cycles with ram_rdy low (Tom held by the latency kludge), white.
// A window is 2^21 clk_sys = 19.7 ms, a little over one frame.
    reg  [20:0] tw = 0;
    reg  [19:0] tcnt [0:32];
    reg  [8:0]  tbar [0:32];
    integer     ti;
    function [8:0] log16(input [19:0] v);     // 16*floor(log2 v) + next 4 bits
        integer k; reg [4:0] m; reg [19:0] sh;
        begin
            m = 0;
            for (k = 0; k < 20; k = k + 1) if (v[k]) m = k[4:0];
            sh = (m >= 4) ? (v >> (m - 4)) : (v << (4 - m));
            log16 = (v == 0) ? 9'd0 : {m, sh[3:0]} + 9'd16;
        end
    endfunction
always @(posedge clk_sys) begin
    tw <= tw + 1'b1;
    if (&tw) begin
        for (ti = 0; ti < 33; ti = ti + 1) begin
            tbar[ti] <= log16(tcnt[ti]);
            tcnt[ti] <= 20'd0;
        end
    end else begin
        if (dbg_rd && ~&tcnt[dbg_rd_region]) tcnt[dbg_rd_region] <= tcnt[dbg_rd_region] + 1'b1;
        if (dbg_stall && ~&tcnt[32])         tcnt[32] <= tcnt[32] + 1'b1;
    end
end
    wire [8:0] by   = dy - 9'd64;                 // bars start at line 64, 4 lines apart
    wire [5:0] bix  = by[7:2];
    wire       brow = (dy >= 9'd64) && (dy < 9'd64 + 9'd132) && (by[1:0] != 2'd3);
    wire [8:0] bx   = dx[8:0] - 9'd4;
    wire       bin  = brow && (dx >= 10'd4) && (dx < 10'd4 + 10'd320);
    wire       bon  = bin && (bx < tbar[bix]);
    wire       btick = bin && (bx[4:0] == 5'd0);
    wire       bcached = dbg_cached_blocks[bix[4:0]];   // block cache
    wire [23:0] bbg  = bix[2] ? 24'h303030 : 24'h181818;   // shade per 256 KB region
    wire [23:0] bcol = !bon ? (btick ? 24'h606060 : bbg)
                     : (bix == 6'd32) ? 24'hFFFFFF : bcached ? 24'h00D000 : 24'hE00000;
`ifdef POCKET_DIAG
assign video_rgb = (video_de && !video_skip && dbox) ? dcol
                 : (video_de && !video_skip && bin)  ? bcol : video_rgb_jv;
`else
assign video_rgb = video_rgb_jv;       // release build: no readout overlay
`endif

// =============================================================================
// Audio out   (docs/06 section 6.4)
// =============================================================================
// Wired ahead of its M6 slot on purpose: with aud_l/aud_r unconnected, Quartus
// prunes Jerry's DAC and tda1545a, and the M2 fit number stops representing
// the real core. Nearest-neighbour resample, as every Pocket core does -- and
// more defensible here than usual, since Jerry's sample rate is programmable.
sound_i2s #(
    .CHANNEL_WIDTH  ( 16 ),
    .SIGNED_INPUT   ( 1 )
) sound_i2s (
    .clk_74a    ( clk_74a ),
    .clk_audio  ( clk_sys ),
    .audio_l    ( aud_l ),
    .audio_r    ( aud_r ),
    .audio_mclk ( audio_mclk ),
    .audio_lrck ( audio_lrck ),
    .audio_dac  ( audio_dac )
);
// TODO M6: mute on osnotify_inmenu, and measure the real dac_sample_strobe
// rate against 48 kHz (docs/06 open question).


// =============================================================================
// TIE-OFFS -- every one of these is a deliberate M1 decision, not an oversight
// =============================================================================

// PSRAM: Stage B moves cart ROM here (docs/04 section 4.5). Safe defaults.
assign cram0_a = 'h0;  assign cram0_dq = {16{1'bZ}};
assign cram0_clk = 0;  assign cram0_adv_n = 1;  assign cram0_cre = 0;
assign cram0_ce0_n = 1; assign cram0_ce1_n = 1; assign cram0_oe_n = 1;
assign cram0_we_n = 1;  assign cram0_ub_n = 1;  assign cram0_lb_n = 1;

assign cram1_a = 'h0;  assign cram1_dq = {16{1'bZ}};
assign cram1_clk = 0;  assign cram1_adv_n = 1;  assign cram1_cre = 0;
assign cram1_ce0_n = 1; assign cram1_ce1_n = 1; assign cram1_oe_n = 1;
assign cram1_we_n = 1;  assign cram1_ub_n = 1;  assign cram1_lb_n = 1;

// SRAM: driven by jaguar_top's Stage B cache (rtl/sram_cache.sv).
// Size and speed were measured by target/pocket/sram_probe.sv.

// No savestates (docs/02).
assign savestate_supported  = 0;
assign savestate_addr       = 0;
assign savestate_size       = 0;
assign savestate_maxloadsize = 0;
assign savestate_start_ack  = 0;
assign savestate_start_busy = 0;
assign savestate_start_ok   = 0;
assign savestate_start_err  = 0;
assign savestate_load_ack   = 0;
assign savestate_load_busy  = 0;
assign savestate_load_ok    = 0;
assign savestate_load_err   = 0;

// No core-initiated data slot access until saves land at M5/M6. The
// target_dataslot_* signals are constant at their declarations above.
assign target_buffer_param_struct = 0;
assign target_buffer_resp_struct  = 0;

// datatable: publish the save slot's size. Entry (slot_index * 2 + 1) holds a
// slot's size, by array position in data.json, not id. Save is index 2
// (Cartridge, Jaguar BIOS, Save). Same pattern as openfpga-SNES.
assign datatable_addr = 10'd5;
assign datatable_wren = 1'b1;
assign datatable_data = 32'd2048;     // 1024 x 16-bit EEPROM words


// =============================================================================
// Clocks   (docs/03)
// =============================================================================
// 106.363636 MHz is a hard requirement: jaguar.v derives its four clock-enable
// phases with a fixed /4 counter, so clk_sys must be exactly 4x the 26.590909
// MHz Jaguar video clock. There is no slower-core fallback.
//
// 74.25 -> 106.363636 is M/N = 520/363, which needs the FRACTIONAL PLL. Build
// it in the Quartus IP Catalog (Altera PLL, fractional mode) with reference
// clk_74a and outputs:
//     outclk_0  106.363636 MHz    clk_sys / clk_ram
//     outclk_1   26.590909 MHz    clk_vid           (video_rgb_clock)
//     outclk_2   26.590909 MHz    clk_vid_90, +90 deg phase
// then check the achieved frequency and ppm error in the fitter's PLL Usage Summary.
    wire    clk_sys;
    wire    clk_vid;
    wire    clk_vid_90;

mf_pllbase mp1 (
    .refclk(clk_74a),
    .rst        ( 0 ),
    .outclk_0   ( clk_sys ),
    .outclk_1   ( clk_vid ),
    .outclk_2   ( clk_vid_90 ),
    .locked     ( pll_core_locked )
);

endmodule

`default_nettype wire
