# 9. Minimum viable Pocket wrapper required for synthesis

The goal of this wrapper is **one thing only**: get `jaguar` through
`quartus_map` and `quartus_fit` inside an APF project so that doc 08's estimates
can be replaced with measurements. It must not try to work.

## 9.1 Repository layout

Mirrors `agg23/openfpga-SNES`, which is the closest public MiSTer→Pocket port
and keeps a diffable relationship with upstream.

```
openfpga-Jaguar/
├── docs/                           this analysis
├── tools/
│   ├── fetch-refs.sh               clone the three reference repos
│   ├── hier.py                     hierarchy extractor
│   ├── lint-jaguar.sh              Verilator elaboration check (runs on macOS)
│   └── quartus.sh                  Docker wrapper: raetro/quartus:21.1
├── rtl/
│   ├── upstream/                   Jaguar_MiSTer rtl/ — VERBATIM, synced
│   └── jaguar_top.sv               trimmed Jaguar.sv (MiSTer-shaped, APF-fed)
├── target/pocket/
│   ├── core_top.sv                 APF top — from core-template, edited
│   ├── core_bridge_cmd.v           from core-template, verbatim
│   ├── core_constraints.sdc
│   ├── data_loader.sv              from openfpga-SNES (MIT)
│   ├── data_unloader.sv            from openfpga-SNES (MIT)   [M5+]
│   ├── sound_i2s.sv                from openfpga-SNES (MIT)   [M6]
│   ├── psram.sv                    from openfpga-SNES (MIT)   [Stage B]
│   ├── jaguar_video.sv             NEW — CE→pixel-clock bridge (doc 06)
│   └── mf_pllbase*                 NEW — 106.363636 / 26.590909 / 26.59@90°
├── platform/pocket/                core-template src/fpga/apf/ — VERBATIM
├── projects/
│   ├── jaguar_pocket.qpf / .qsf / .qip / .sdc
└── pkg/pocket/                     core.json, data.json, video.json, …  [M7]
```

## 9.2 What `core_top.sv` must do for Milestone 1

Start from `core-template/src/fpga/core/core_top.v` unmodified, then make
exactly these changes:

**Keep as-is (do not touch):**
* the entire port list
* all `cart_tran_*`, `port_tran_*`, `port_ir_*` safe-default assignments
  (these drive level translators — getting them wrong can damage hardware)
* `core_bridge_cmd icb (...)` and every signal feeding it
* `bridge_endian_little = 0`

**Add:**

```verilog
// ---- PLL ----------------------------------------------------------------
wire clk_sys;          // 106.363636 MHz  (core + SDRAM)
wire clk_vid;          //  26.590909 MHz
wire clk_vid_90;       //  26.590909 MHz, +90°
wire pll_core_locked;

mf_pllbase mp1 (
    .refclk   (clk_74b),
    .rst      (0),
    .outclk_0 (clk_sys),
    .outclk_1 (clk_vid),
    .outclk_2 (clk_vid_90),
    .locked   (pll_core_locked)
);

// ---- reset --------------------------------------------------------------
// reset_n comes from the host via core_bridge_cmd, in clk_74a.
// Synchronise into clk_sys and OR with !pll_core_locked.

// ---- ROM load path ------------------------------------------------------
data_loader #(
    .ADDRESS_MASK_UPPER_4 (4'h1),     // cart slot, bridge addr 0x1xxxxxxx
    .ADDRESS_SIZE         (25),
    .OUTPUT_WORD_SIZE     (2)         // 16-bit, matches MiSTer ioctl_data
) cart_loader (
    .clk_74a    (clk_74a),
    .clk_memory (clk_sys),
    .bridge_wr  (bridge_wr),
    .bridge_endian_little (bridge_endian_little),
    .bridge_addr(bridge_addr),
    .bridge_wr_data(bridge_wr_data),
    .write_en   (ioctl_wr),
    .write_addr (ioctl_addr),
    .write_data (ioctl_data)
);
// a second instance with ADDRESS_MASK_UPPER_4 = 4'h2 for the BIOS slot

// ---- the core -----------------------------------------------------------
jaguar_top jaguar_top ( ... );

// ---- video --------------------------------------------------------------
assign video_rgb_clock    = clk_vid;
assign video_rgb_clock_90 = clk_vid_90;
// M1: drive video_rgb/de/hs/vs from jaguar_video.sv — or even from a
//     trivial test-pattern generator. Either keeps the pins alive so the
//     fitter is honest about I/O.
assign video_skip = 0;
```

**Explicitly tie off for Milestone 1** (each one is a deliberate decision, not
an oversight — record it):

```verilog
assign audio_mclk = 0;  assign audio_dac = 0;  assign audio_lrck = 0;
assign sram_a = 'h0; assign sram_dq = {16{1'bZ}};
assign sram_oe_n = 1; assign sram_we_n = 1; assign sram_ub_n = 1; assign sram_lb_n = 1;
assign cram0_* = <template safe defaults>;
assign cram1_* = <template safe defaults>;
// dram_* ARE driven — by the sdram controller. This is the point of M1.
assign savestate_supported = 0;
assign dataslot_requestread_ack = 1;  assign dataslot_requestread_ok = 1;
assign dataslot_requestwrite_ack = 1; assign dataslot_requestwrite_ok = 1;
```

## 9.3 What `rtl/jaguar_top.sv` must be

A deliberately **recognisable descendant of `Jaguar.sv`**, so upstream changes
stay mergeable. Take `Jaguar.sv` and:

### Delete

| Lines (approx) | What |
|---|---|
| 28-57 | `emu_ports.vh` include and the MiSTer `assign …='Z'` block |
| 303-371 | `hps_io` instance |
| 117-192 | `CONF_STR` (replace `status[...]` reads with parameters/ports) |
| 629-641 | `auto_crt_ar` |
| 896-966 | `numstick`, `video_mixer`, `video_freak` |
| 971-1000 | MiSTer audio assigns + the whole `DDRAM_*` block |
| 1024-1057 | `jaguar_cd_stream` |
| 1254-1349 | the `FAST_SDRAM` fastcache block (keep `ifdef`, leave it undefined) |
| 1502-1551 | `sdram2` instance (keep behind `` `ifdef `` ) |
| 1593-1639 | `cart_backram`, `cd_eeprom_backram`, `debug_rom` (M1 only — restore at M5) |
| 1640+ | `save_slot` instances, `CODES` |

### Keep

* the PLL-free clock wiring (`clk_sys`, `clk_ram` now come in as ports)
* `jaguar jaguar_inst (...)` — **every port, unchanged**
* the ROM loader state machine (`:375-581`) — it is good code and the
  `data_loader` output is signal-compatible with `ioctl_*`
* the `cart_mask`, `bios_m`, `cart_b`/`bios_b`/`nvme_b` download sniffers
* the ch1 RAS/CAS edge-detection glue (`:1062-1119`)
* `cart_ch2_addr`/`_din`/`_req`/`_rnw`/`_be` generation (`:1441-1446`)
* the single `sdram` instance

### Replace `status[127:0]`

Every `status[n]` read becomes either a module parameter (compile-time) or an
input port fed from a bridge register. For Milestone 1, parameters with these
values:

| `status` bit(s) | Meaning | M1 value |
|---|---|---|
| `[4]` | PAL | 0 (NTSC) |
| `[30]` | homebrew support off | 0 → `max_compat = 1` |
| `[2]` | patch checksums | 1 |
| `[52]` | force CD | 0 |
| `[55]` | force music CD | 0 |
| `[56]` | force MemoryTrack | 0 |
| `[82]` | CD timing | 0 |
| `[87]` | visual area | 0 (active) |
| `[6:5]`, `[21:20]`, `[33:32]`, `[41:40]`, `[83]`, `[85]`, `[86]` | input options | 0 |
| `[15]`, `[0]`, `[22]` | resets / pause action | 0 |
| `[36:34]`, `[39:37]` | FastRAM window select | n/a (`FAST_SDRAM` off) |

## 9.4 `jaguar_video.sv` (the one genuinely new module)

```
in  : clk_sys, vid_ce, vga_r/g/b, vga_hs, vga_vs, hblank, vblank, pix_double
in  : clk_vid
out : video_rgb[23:0], video_de, video_hs, video_vs
```

Latch pixels in `clk_sys` on `vid_ce`; re-emit one per `clk_vid` edge, twice
when `pix_double`. Same PLL, exact /4 ratio, so this is a constrained
same-domain transfer, not a CDC. See doc 06 §6.3.

For Milestone 1 a **constant-colour generator** is acceptable and arguably
better: it keeps `jaguar_video.sv` out of the first fit so the resource report
attributes everything to `jaguar`.

## 9.5 Quartus project

`projects/jaguar_pocket.qsf`, derived from `core-template/src/fpga/ap_core.qsf`:

```tcl
set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE 5CEBA4F23C8
set_global_assignment -name TOP_LEVEL_ENTITY apf_top
set_global_assignment -name GENERATE_RBF_FILE ON
# ... all pin assignments from the template, UNCHANGED ...

set_global_assignment -name SEARCH_PATH ../rtl/upstream/nuked-68k
set_global_assignment -name SEARCH_PATH ../rtl/upstream/fx68k
set_global_assignment -name SEARCH_PATH ../rtl/upstream

set_global_assignment -name QIP_FILE ../platform/pocket/apf.qip
set_global_assignment -name QIP_FILE ../target/pocket/core.qip
set_global_assignment -name QIP_FILE ../rtl/jaguar_pocket.qip
```

`rtl/jaguar_pocket.qip` is `files.qip` minus the MiSTer-only entries:

```tcl
set_global_assignment -name SYSTEMVERILOG_FILE jaguar_top.sv
set_global_assignment -name QIP_FILE           upstream/jaguar.qip
set_global_assignment -name VERILOG_FILE       upstream/nuked-68k/68k.v
set_global_assignment -name VERILOG_FILE       upstream/jag_controller_mux.v
set_global_assignment -name VERILOG_FILE       upstream/jag_team_tap.v
set_global_assignment -name VERILOG_FILE       upstream/gamedrive.v
set_global_assignment -name VERILOG_FILE       upstream/ps2_mouse.v
set_global_assignment -name SYSTEMVERILOG_FILE upstream/jag_lightgun.sv
set_global_assignment -name VERILOG_FILE       upstream/eeprom_93c46_x16.v
set_global_assignment -name VERILOG_FILE       upstream/tda1545a.v
set_global_assignment -name SYSTEMVERILOG_FILE upstream/mem/sdram_dual.sv
set_global_assignment -name VHDL_FILE          upstream/mem/bram.vhd
# dropped vs upstream: Jaguar.sdc, auto_crt_ar.sv, numstick.sv,
#                      cheatcodes.sv, cd_stream.sv, save_slot.sv, mem/ddram.sv
```

Note `jag_controller_mux`, `jag_team_tap`, `ps2_mouse`, `jag_lightgun`,
`gamedrive`, `eeprom_93c46_x16`, `tda1545a` are all instantiated **inside**
`jaguar.v` and therefore cannot be dropped from the file list even though their
inputs are tied off. The fitter will prune most of their logic.

## 9.6 Known pitfalls, pre-identified

| Pitfall | Mitigation |
|---|---|
| `altsyncram` in `ab8016a.v`, `ab8616a.v`, `aba032a.v` declares `intended_device_family = "Cyclone II"/"Cyclone III"` | Quartus accepts this and retargets; it only affects simulation models. Leave it. If the fitter complains, override to `"Cyclone V"`. |
| `$readmemb("68k_ucode.txt")` with a bare filename | needs `SEARCH_PATH` pointing at `rtl/upstream/nuked-68k`. **Most likely first failure.** |
| Mixed VHDL (`bram.vhd`) + named parameter override of VHDL generics (`spram #(.ADDR_WIDTH(11), …)`) | works in Quartus Lite; note that `bram.vhd` declares generics as lowercase `addr_width` while `Jaguar.sv:1628` uses uppercase `ADDR_WIDTH` — VHDL is case-insensitive so this is fine, but **watch for it** if Quartus version changes. |
| `altddio_out` for `SDRAM_CLK` in `sdram_dual.sv:472` | fine on Cyclone V E; the SNES port uses the same approach |
| `(*noprune*)` and `// altera message_off 10036` pragmas scattered through the netlist RTL | leave them |
| APF `.sdc` must constrain `clk_74a`/`clk_74b` as asynchronous to `clk_sys` | `apf_constraints.sdc` handles the APF side; our `core_constraints.sdc` must add `set_clock_groups -asynchronous` |
| `.rbf` needs bit-reversal for APF | `tools/` step at M3; template ships `bitstream.rbf_r` |
| **`vblank` is an APF *input port* of `core_top`** (dock-driven sync), so the console's `vblank` output cannot keep its name | **hit for real** while linting `core_top.sv`; the console's blanking nets are `jag_hblank`/`jag_vblank` |
| Template declares `target_dataslot_read/write/getfile/openfile/id/slotoffset/bridgeaddr/length` as `reg`, so an `assign` on them is illegal | converted to constant `wire`s for M1; they become real registers when saves land at M5/M6 |
| `data_loader.sv` instantiates Altera `dcfifo` | Verilator cannot resolve it; Quartus can. Expected, same class as the `altsyncram` references in §1.7 |
| **A module missing from the `.qip` passes the local lint** | `sound_i2s` needs `sync_fifo.sv`, which was vendored but never added to `core.qip`; Quartus failed with `Error (12006) undefined entity sync_fifo`. Verilator auto-resolves modules from `<name>.sv` in any include path *or the directory of any file on its command line*, with no flag to disable it. **`quartus_map` is the only authority here** — use the ~3 min `m1-map` workflow. |
| **`cd_valid` and `cd_sector2448` are *inputs* to `jaguar`** (`jaguar.v:114-115`), despite sitting among the CD outputs | **hit for real** in M1: the `NO_JAGUAR_CD` branch tried to drive them. `jaguar_top` drives them instead. **Verilator's `--lint-only` did not flag assigning to an input port; Quartus errors with `Error (10231)`.** Do not trust the local lint for port-direction mistakes. |

## 9.7 Definition of done for the wrapper

* `quartus_map` completes with zero errors (Milestone 1).
* `quartus_fit` completes **or** fails with a resource-overflow message that
  names the resource and the amount (Milestone 2). A clean overflow error is a
  **successful** Milestone 2 outcome — it is the measurement we came for.
* `quartus_sta` emits Fmax for `clk_sys`.
* All numbers recorded.
