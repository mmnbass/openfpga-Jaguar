# 1. Jaguar_MiSTer module hierarchy and top-level architecture

Source of truth: `refs/Jaguar_MiSTer` @ `43a761d` ("flatten out the rework folder (#46)", 2026-08-12).

## 1.1 Provenance

Three distinct code lineages live in this repository, and they have very different
porting characteristics:

| Lineage | Files | Nature |
|---|---|---|
| **Torlus / Gregory Estrade netlist conversion** | `rtl/Tom/`, `rtl/Jerry/`, `rtl/jaguar_common/` | Machine translation of the *original Atari Tom & Jerry netlists* into Verilog. Gate-level style, flat `assign`, one module per original `.NET` file. Comments carry the original net names (`// PIX.NET (201) - red : ra8008a`). |
| **MiSTer-era additions** | `rtl/Butch/`, `rtl/cd_stream.sv`, `rtl/gamedrive.v`, `rtl/save_slot.sv`, `rtl/cheatcodes.sv`, `rtl/numstick.sv`, `rtl/jag_*.v`, `rtl/eeprom_93c46_x16.v`, `rtl/tda1545a.v` | Hand-written behavioural RTL by ElectronAsh / Kitrinx / GreyRogue. Jaguar CD (Butch), CD streaming, Memory Track, cheats, input plumbing. |
| **Imported CPU cores** | `rtl/nuked-68k/68k.v`, `rtl/fx68k/` | Two interchangeable 68000 implementations (see §1.5). |

The netlist-derived part is **not** idiomatic RTL and should be treated as
black-box: do not refactor it. The whole netlist tree has been converted to a
**clock-enable discipline on one clock** (`sys_clk`), with the original Jaguar
`pclk`/`vclk` edges expressed as CE pulses. Every leaf module carries a
`sys_clk` port annotated `// Generated`.

## 1.2 Top-level layering

```
sys_top                           (sys/sys_top.v)       MiSTer board top — HDMI, HPS, DDR3, SDRAM pins
└── emu                           (Jaguar.sv)           the "core" as MiSTer defines it
    ├── pll                       (rtl/pll.v)           106.36 / 26.59 / 53.18 MHz
    ├── hps_io                    (sys/hps_io.sv)       OSD, config string, ioctl, SD-card blocks, inputs
    ├── jaguar                    (rtl/jaguar.v)        ◄── the actual console
    ├── jaguar_cd_stream          (rtl/cd_stream.sv)    CD image streaming + TOC synthesis + 16 KB sector cache
    ├── CODES                     (rtl/cheatcodes.sv)   cheat engine on the 68k bus
    ├── jaguar_save_slot ×3       (rtl/save_slot.sv)    cart NVRAM / Memory Track / CD EEPROM → HPS files
    ├── numstick                  (rtl/numstick.sv)     on-screen keypad overlay (video mixer stage)
    ├── auto_crt_ar               (rtl/auto_crt_ar.sv)  measures sync to derive aspect ratio
    ├── video_mixer, video_freak  (sys/)                scandoubler, HQ2x, gamma, scaling, crop
    ├── sdram                     (rtl/mem/sdram_dual.sv) ×1 or ×2 (see doc 04)
    ├── spram_byte_32x15 ×1..3    (rtl/mem/sdram_dual.sv) 128 KB BRAM blocks (see doc 08)
    ├── dpram / spram             (rtl/mem/bram.vhd)    VHDL BRAM wrappers
    └── ddram                     (rtl/mem/ddram.sv)    DDR3 Avalon master (cart ROM + BIOS staging)
```

`Jaguar.sv` is 1902 lines and is roughly 15 % "console" and 85 % "platform
glue". That ratio is the whole porting job.

## 1.3 Inside `jaguar` (rtl/jaguar.v)

`rtl/jaguar.v` is the real console board: it instantiates the two custom chips,
the CPU, the CD controller, the DACs, the controller multiplexers and the
EEPROMs, and it generates the clock-enable phases.

```
jaguar                                   (rtl/jaguar.v, 1730 lines)
├── _tom                                 Tom  — video, blitter, object processor, GPU, DRAM controller
│   ├── _clk                             pclk/vclk/tlw fan-out (pure wires + CE)
│   ├── _mem                             DRAM controller: RAS/CAS generation, arbitration
│   │   ├── _arb, _bus, _cpu, _memwidth
│   │   └── _rasgen ×2
│   ├── _abus, _dbus (_up, _down)        external address/data bus
│   ├── _graphics                        ◄── the big one
│   │   ├── _blit                        Blitter
│   │   │   ├── _address (_addamux, _addradd, _addrcomp, _addrgen)
│   │   │   ├── _data    (_addarray→_add16sat ×4, _daddamux, _daddbmux,
│   │   │   │             _data_mux, _srcshift, _zedcomp)
│   │   │   ├── _state   (_acontrol, _blitstop, _comp_ctrl, _dcontrol,
│   │   │   │             _inner→_inner_cnt, _mcontrol, _outer)
│   │   │   └── _blitgpu
│   │   ├── _gpu_ram → _aba032a          4 KB GPU local RAM (1024×32 TDP)
│   │   ├── _ins_exec                    GPU instruction execute
│   │   │   ├── _execon, _interrupt, _prefetch→_pc, _srcdgen, _systolic
│   │   │   └── _ra6032a                 64×32 microcode ROM
│   │   ├── _registers → _rd64x32        64×32 register file
│   │   ├── _arith (_alu32, _brlshift→_barrel32, _mp16, _saturate, _j_saturate)
│   │   ├── _divider, _gateway, _gpu_cpu, _gpu_ctrl, _gpu_mem, _sboard
│   ├── _ob, _obdata → _ab8016a ×2       Object Processor + 2×256×16 CLUT
│   ├── _lbuf → _ab8616a ×4              line buffer, 512×16 ×4 = 512×64
│   ├── _pix → _cryrgb                   CRY→RGB
│   │   ├── _ra8008a/b/c                 3×256×8 CRY lookup ROMs (inferred, initial block)
│   │   └── _mp1010a ×3                  10×10 multipliers → DSP blocks
│   ├── _vid                             video timing generator
│   ├── _iodec, _misc, _wbk
├── _j_jerry                             Jerry — DSP, sound, timers, I²S, UART, joypad I/O
│   ├── _j_dsp                           same GPU core generics as Tom's GPU:
│   │   ├── _arith, _divider, _gateway, _gpu_cpu, _gpu_ctrl, _gpu_mem,
│   │   │   _ins_exec(+_ra6032a), _registers(+_rd64x32), _sboard
│   │   └── _j_dsp_ram
│   │       ├── _gpu_ram ×2 → _aba032a ×2    8 KB DSP local RAM
│   │       └── _j_sinerom → _raa016a        1024×16 sine ROM
│   ├── _j_dac → _j_pulse ×4             PWM DAC
│   ├── _j_i2s, _j_jbus, _j_jclk, _j_jiodec, _j_jmem, _j_jmisc
│   └── _j_uart2 (_j_rxer, _j_txer, _j_u2pscl)   JagLink
├── _butch, _butch_i2s                   Jaguar CD controller (3114 lines, MiSTer-era)
├── m68kcpu            (nuked-68k)       default CPU
├── fx68k              (fx68k/)          alternative CPU, `ACCURATE_CPU`
├── tda1545a                             audio DAC model
├── eeprom_93c46_x16 ×2                  cart EEPROM + CD EEPROM
├── jag_controller_mux ×2                joypad matrix
├── jag_team_tap ×2 → tap_controller_mux ×4
├── jaguar_lightgun, ps2_mouse, gamedrive
└── flipflop ×3                          (local helper in jaguar.v)
```

Full machine-generated tree: regenerate any time with

```bash
python3 tools/hier.py refs/Jaguar_MiSTer/rtl jaguar
```

128 distinct module types under `jaguar`.

## 1.4 Clock-enable architecture (critical for the port)

`rtl/jaguar.v:176-205`:

```verilog
reg [1:0] clkdiv = 0;
always @(posedge sys_clk) begin
    clkdiv   <= clkdiv + 2'd1;
    ce_26_6_p0 <= &clkdiv[1:0];
    ce_26_6_p1 <= ce_26_6_p0;
    ce_26_6_p2 <= ce_26_6_p1;
    ce_26_6_p3 <= ce_26_6_p2;
    ...
end
assign xvclk  = ce_26_6_p0;   // Jaguar video clock, as a CE
assign tlw    = ce_26_6_p3;   // "transparent latch write" == negedge pclk, as a CE
assign vid_ce = xvclk & pix_pp;
```

**`clkdiv` is 2 bits wide and is not parameterised.** The four CE phases only
land on 26.590909 MHz if `sys_clk` is exactly 4×, i.e. **106.363636 MHz**.
`Jaguar.sv` has a `` `ifdef FAST_CLOCK `` that would select a 53.18 MHz
`clk_sys`, but that path would produce a 13.3 MHz `xvclk` — it is stale/broken.
Conclusion: **there is no "run the core slower" escape hatch.** Pocket must
close timing at 106.36 MHz. See doc 03.

## 1.5 CPU selection

`rtl/jaguar.v:1553`:

```verilog
`define ACCURATE_CPU
`ifdef ACCURATE_CPU
m68kcpu m68k_inst ( ... )        // rtl/nuked-68k/68k.v   ← the default
`endif
...
`ifndef ACCURATE_CPU
fx68k fx68k_inst ( ... )         // rtl/fx68k/            ← the alternative
`endif
```

`ACCURATE_CPU` is **unconditionally defined inside `jaguar.v` itself**, so:

* default build → `m68kcpu` (`rtl/nuked-68k/68k.v`, 6299 lines, gate-level Nuked
  model; `ucode[0:63]` and `ncode[0:255]` × 272 bits marked
  `(* ramstyle = "M10K" *)`, loaded from `68k_ucode.txt` / `68k_ncode.txt` via
  `$readmemb`)
* comment out line 1553 → `fx68k` (2710 + 843 + 2194 lines, microcoded)

Only one is ever compiled — the hierarchy dump above shows both because
`tools/hier.py` ignores preprocessor directives. **There is no free area win
here**, but swapping nuked → FX68K is a real area/timing lever (doc 08), at the
cost upstream describes: FX68K has "differences in FC signals [that] will cause
inaccuracies including memtrack checksums to fail."

## 1.6 Build variants that already exist upstream

| Project | SDC | Macro | Meaning |
|---|---|---|---|
| `Jaguar.qpf/.qsf` | `Jaguar.sdc` | `MISTER_DUAL_SDRAM` (via `sys/sys_dual_sdram.tcl`) | two SDRAM modules, no BRAM "fastcache" |
| `Jaguar_Single.qpf/.qsf` | `Jaguar_Single.sdc` | — | one SDRAM module, `FAST_SDRAM` defined → 3 × 128 KB BRAM cache |

Upstream README on the single-SDRAM build: *"all boot, some with glitches or
slow down, and others that might crash to a black screen"*. Pocket has one
SDRAM, so this is the regime we start from — but with a different resource
budget (doc 04, doc 08).

## 1.7 Verified: the console RTL elaborates standalone

Run `tools/lint-jaguar.sh`. With `--top-module jaguar` and only the console
files (no `sys/`, no `Jaguar.sv`), Verilator 5.050 reports **zero** unresolved
modules, zero width/connectivity errors. The only errors are
`Dotted reference to instance that refers to missing module: 'altsyncram'` in
exactly three files:

* `rtl/Tom/ab8016a.v` — 256×16 (CLUT, ×2)
* `rtl/Tom/ab8616a.v` — 512×16 (line buffer, ×4)
* `rtl/jaguar_common/aba032a.v` — 1024×32 true-dual-port (GPU/DSP RAM, ×3)

These are live Altera `altsyncram` megafunction instantiations and resolve
automatically under Quartus. (By contrast `ra8008a/b/c.v`, `ra6032a.v`,
`rd64x32.v`, `raa016a.v` have their `altsyncram` block commented out and infer
memory from an `initial` block instead — no `.mif` files are required or
present anywhere in the repo.)

**Implication for the port:** `rtl/jaguar.v` and everything below it can be
lifted into a Pocket project *unmodified*. All the work is above it.
