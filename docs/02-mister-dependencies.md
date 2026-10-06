# 2. MiSTer-specific dependencies that must be replaced

Everything in this list sits **above** `rtl/jaguar.v`. Nothing below it is
MiSTer-specific.

## 2.1 Hard dependencies (the core will not compile on Pocket without these)

| MiSTer thing | Where it enters | Pocket replacement | Difficulty |
|---|---|---|---|
| `sys_top` board top-level | `Jaguar.qsf: TOP_LEVEL_ENTITY sys_top` | `apf_top` (provided by APF, do not modify) | trivial |
| `emu` port list | `Jaguar.sv:28 \`include "sys/emu_ports.vh"` | `core_top` port list | mechanical |
| `sys/sys.tcl`, `sys/sys_dual_sdram.tcl`, `sys/sys.qip` | `Jaguar.qsf` | `platform/pocket/*.qip` + our own `.qsf` | mechanical |
| `hps_io` (OSD, CONF_STR, ioctl, SD blocks, joysticks, PS/2) | `Jaguar.sv:303` | APF **bridge**: `core_bridge_cmd` + `data_loader`/`data_unloader` + `interact.json`/`data.json` | **substantial** — this is the main rewrite |
| `CONF_STR` menu language | `Jaguar.sv:117-192` | `interact.json` variables + bridge register decode | substantial but mechanical |
| `video_mixer` + `video_freak` (scandoubler, HQ2x, gamma, scaler, crop) | `Jaguar.sv:917, 950` | **delete**. APF's hardware scaler does this; core emits raw RGB + DE/HS/VS | deletion |
| `AUDIO_L/R` + MiSTer `audio_out`/`i2s`/`spdif` | `Jaguar.sv:971-974` | `sound_i2s`-style I²S master driving `audio_mclk/dac/lrck` | small |
| `ddram` + Avalon DDR3 (`DDRAM_*`) | `Jaguar.sv:978-1000`, `rtl/mem/ddram.sv` | **Pocket has no DDR3.** Re-target to SDRAM or PSRAM (doc 04) | **substantial** |
| `SDRAM2_*` second module | `Jaguar.sv:1502-1551` | **Pocket has one SDRAM.** Either drop (single-SDRAM regime) or re-target ch1-upper to PSRAM (doc 04) | **substantial** |
| `rtl/pll.v` (Altera PLL from 50 MHz) | `Jaguar.sv:64` | new `altera_pll` from 74.25 MHz (doc 03) | small |
| `rtl/mem/bram.vhd` (`spram`/`dpram` VHDL wrappers) | many | keep, but confirm the Pocket `.qsf` allows mixed VHDL. Quartus Lite does. | trivial |
| `build_id.v` / `sys/build_id.tcl` | `Jaguar.sv:115` | APF's `apf/build_id_gen.tcl` + `build_id.mif` | trivial |
| `sys/sys_top.sdc`, `Jaguar.sdc` | timing | `apf_constraints.sdc` (given) + our `core_constraints.sdc` | small, then iterative |

## 2.2 Soft dependencies (features that exist only because MiSTer has them)

These should all be **stubbed to constants for Milestone 1** and reintroduced
selectively later. Each one is also an area saving (doc 08).

| Feature | MiSTer mechanism | Status for M1 | Eventual Pocket path |
|---|---|---|---|
| OSD menu / `status[127:0]` | `hps_io` | tie to compile-time defaults | `interact.json` + bridge regs |
| ROM/BIOS file loading | `ioctl_download/_wr/_addr/_dout/_index/_wait` | `data_loader` from bridge | doc 05 |
| CD image streaming (`.cdi`) | `sd_lba`/`sd_rd`/`sd_buff_*` virtual-disk protocol over 4 VDs | **cut entirely** | `target_dataslot_read` + a block-request engine (large job) |
| Save files (cart NVRAM, Memory Track, CD EEPROM) | `jaguar_save_slot` + VD writes | **cut** | `data_unloader` + `dataslot_requestwrite`, or APF "Memories" |
| Cheats | `CODES` + `ioctl_index==0xFF` | **cut** | optional data slot |
| PS/2 keyboard & mouse | `ps2_key`, `ps2_mouse` | tie off | Pocket has no PS/2. Map to controller/dock only |
| Spinners, analog sticks, Team-Tap, light gun | `hps_io` `spinner_*`, `joystick_l_analog_*` | tie off | `cont1_joy`/`cont1_trig`, dock controllers (doc 07) |
| `numstick` on-screen keypad overlay | video mixer stage | **cut for M1** | re-add; it is self-contained and cheap |
| JagLink over SNAC | `USER_IN[2]`/`USER_OUT[1]` | tie off | Pocket link port (`port_tran_*`) — plausible later |
| `sdram_sz` (HPS tells core the module size) | `hps_io` | hard-wire | Pocket SDRAM is fixed (doc 04) |
| `HDMI_WIDTH/HEIGHT`, `VIDEO_ARX/ARY`, vcrop, scale | `sys_top` + `video_freak` | **cut** | `video.json` scaler modes |
| `forced_scandoubler`, scanlines, HQ2x, gamma | `video_mixer` | **cut** | Pocket scaler / display modes |
| `auto_crt_ar` | derives aspect from sync | keep (tiny) or cut | `video.json` static modes |
| RTC | — | n/a | APF provides `rtc_*` if ever needed |

## 2.3 APF facilities with no MiSTer equivalent (new work, not replacement)

| APF facility | Why we need it |
|---|---|
| `core_bridge_cmd` host/target command protocol | mandatory; boot/reset handshake, data slots |
| `dataslot_requestwrite` / `dataslot_allcomplete` | tells the core when ROM/BIOS transfer starts & finishes — replaces `ioctl_download` edges |
| `datatable_*` (`mf_datatable`) | core publishes slot sizes back to the host |
| `video_rgb_clock` + `video_rgb_clock_90` | APF samples RGB on an explicitly supplied pixel clock *and* a 90°-shifted copy |
| `video_skip` | lets a core drop a pixel clock to reconcile non-integer pixel rates |
| `osnotify_inmenu` | pause/mute while the Pocket menu is up |
| `reset_n` from host | core-wide reset; replaces `RESET`/`status[0]`/`buttons[1]` |
| `bridge_endian_little` | APF is big-endian by default; matters for ROM byte order (doc 05) |
| `cart_tran_*`, `port_tran_*` level-translator direction control | must be driven to safe values even when unused |
| `.json` metadata set (`core/data/input/video/audio/interact/variants`) | packaging; no MiSTer analogue (doc 09) |

## 2.4 Things that look like dependencies but are not

* `rtl/mem/sdram_dual.sv` — Sorgelig's controller, but **heavily specialised to
  Jaguar** (comments at `:22-36` document the exact bank/row map). Keep it; it is
  effectively part of the Jaguar core now. Only its pin names and the dual-chip
  instantiation are MiSTer-shaped.
* `rtl/mem/bram.vhd` — generic VHDL BRAM wrappers, portable as-is.
* `rtl/fx68k/` — upstream third-party, portable as-is.
* `rtl/nuked-68k/68k.v` — portable as-is; needs `68k_ucode.txt`/`68k_ncode.txt`
  on the Quartus search path (`SEARCH_PATH` assignment).
* `altddio_out` in `sdram_dual.sv:472` for `SDRAM_CLK` — an Altera primitive,
  not a MiSTer one. Works on Pocket; the reference SNES port uses the same
  technique (`mf_ddio_bidir_12`).

## 2.5 Strategy

Mirror `agg23/openfpga-SNES`, which is the closest public analogue:

```
rtl/upstream/      ← Jaguar_MiSTer rtl/ verbatim, synced from upstream
rtl/mister_top/    ← a trimmed Jaguar.sv kept recognisably MiSTer-shaped
target/pocket/     ← core_top.sv, data_loader, psram, sound_i2s, PLL, SDC
platform/pocket/   ← APF, verbatim from core-template
projects/          ← .qpf/.qsf/.qip/.sdc
```

That layout keeps a diffable relationship with upstream (they even run a nightly
`upstream.yml` workflow to PR upstream changes in). We adopt it.
