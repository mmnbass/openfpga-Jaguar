# 8. Expected Cyclone V resources and likely Pocket constraints

> **Status: MEASURED ON POCKET.** Milestone 2 fitted the real Pocket project
> for `5CEBA4F23C8` on 2026-10-02 (Quartus 21.1.1, Fitter Successful).
>
> **IT FITS: 12,726 / 18,480 ALMs (69 %), 39 / 308 M10K (13 %), 7 / 66 DSP.**
>
> The raw milestone build reports behind these figures are kept in the
> development archive, not in this repository. Regenerate breakdowns with
> `tools/parse-fit.py`. See §8.1b for the Pocket numbers and §8.8 for timing.

## 8.1 The two devices

| | MiSTer | Analogue Pocket |
|---|---|---|
| Device | `5CSEBA6U23I7` | `5CEBA4F23C8` |
| Family | Cyclone V SoC (SE) | Cyclone V E |
| ALMs | 41,910 | **18,480** (44 %) |
| LEs (marketing) | ~110 K | ~49 K |
| M10K blocks | 553 (5,530 Kbit ≈ 692 KB) | **308** (3,080 Kbit ≈ 385 KB) (56 %) |
| DSP blocks (18×18) | 112 | 66 |
| Speed grade | 7 (industrial) | **8** (commercial) — slower |
| Hard memory controller | yes (DDR3 via HPS) | **no usable DDR** |
| Framework overhead | MiSTer `sys/` — `hps_io`, `ascal`, HDMI, OSD, `video_mixer`, YC, ALSA, I²C, …  (large) | APF — `io_bridge_peripheral`, `io_pad_controller`, `mf_datatable`, DDIO (small) |

Pocket is **smaller, slower, and has less BRAM**, but its framework overhead is
much lower. The framework delta works in our favour; the device delta does not.

## 8.1a MEASURED — Milestone 0 fitter results

MiSTer `Jaguar_Single`, device `5CSEBA6U23I7`, Quartus 17.1, fitter successful:

| | ALMs | M10K | BRAM bits | DSP | PLLs |
|---|---|---|---|---|---|
| `sys_top` (whole MiSTer design) | 30,349 / 41,910 (72 %) | **539 / 553 (97 %)** | 4,151,905 (73 %) | 40 / 112 | 3 / 6 |
| `emu` (the core as MiSTer defines it) | 23,293 | 480 | 3,767,360 | 7 | — |
| **`jaguar` (the console itself)** | **17,608** | **46** | **242,240** | **7** | — |
| MiSTer framework (`sys_top` − `emu`) | 7,056 | 59 | 384,545 | 33 | 3 |

The dual-SDRAM build agrees to within rounding: `jaguar` = 17,600 ALMs, 46 M10K.
Identical RTL, so this is a good cross-check on the measurement.

### Inside `emu` (single-SDRAM build)

| Entity | ALMs | M10K | Keep for Pocket? |
|---|---|---|---|
| `jaguar:jaguar_inst` | **17,608** | 46 | **yes — this is the console** |
| `CODES:codes_68k` (cheats) | 779 | 0 | no (M6+) |
| `numstick:numstick_inst` | 914 | 0 | no (M6) |
| `hps_io:hps_io` | 905 | 0 | **no — replaced by APF bridge** |
| `video_mixer:video_mixer` | 810 | 27 | **no — APF scales** |
| `jaguar_cd_stream:cd_stream_inst` | 662 | 16 | no (M6+) |
| `auto_crt_ar` | 345 | 0 | no |
| `video_freak` | 315 | 0 | **no — APF scales** |
| `sdram:sdram` | **238** | 0 | **yes** |
| 3 × `spram_byte_32x15` (`FAST_SDRAM`) | 121 | **384** | **no — cannot fit (§8.2)** |
| `jaguar_save_slot` × 3 | 216 | 0 | no (M5/M6) |
| `spram:debug_rom` | 36 | 4 | no |
| `dpram:cart_backram` / `cd_eeprom_backram` | 0 | 3 | yes (M5) |

### Inside `jaguar` — where the 17,608 ALMs actually go

| Entity | ALMs | % of console | M10K |
|---|---|---|---|
| **`_butch` (Jaguar CD controller)** | **6,814** | **39 %** | 10 |
| `_tom` | 4,604 | 26 % | 12 |
| &nbsp;&nbsp;`_graphics` (GPU + blitter) | 2,952 | 17 % | 6 |
| &nbsp;&nbsp;`_lbuf`, `_obdata`, `_pix`, `_vid`, `_dbus`, `_abus`, `_mem`, … | ~1,650 | 9 % | 6 |
| `m68kcpu` (nuked-68k) | 3,119 | 18 % | 14 |
| `_j_jerry` | 1,953 | 11 % | 10 |
| &nbsp;&nbsp;`_j_dsp` | 1,524 | 9 % | 10 |
| EEPROMs, Team-Tap, `gamedrive`, `ps2_mouse`, `tda1545a`, glue | ~1,100 | 6 % | 0 |

**`_butch` being bigger than Tom was the surprise of M0.** 3,114 lines of
hand-written CD controller cost more than the entire netlist-derived video,
blitter and object-processor chip.

### The verdict against Pocket (18,480 ALMs, 308 M10K, 66 DSP)

| Configuration | ALMs | % of Pocket | M10K | % |
|---|---|---|---|---|
| `jaguar` as-is (CD included) | 17,608 | **95 %** | 46 | 15 % |
| **`jaguar` minus `_butch` (cart-only)** | **10,794** | **58 %** | 36 | 12 % |
| cart-only + `sdram` + saves + EEPROMs | ~11,050 | 60 % | ~43 | 14 % |

So:

* **Q1 answered — yes, it fits, cart-only.** A cart-only console leaves roughly
  **7,400 ALMs** for the APF framework, the SDRAM controller, two
  `data_loader`s and `jaguar_video`. That is ample: the entire MiSTer framework
  — which is far heavier than APF — was 7,056 ALMs.
* **With CD support it does not fit**: 17,608 of 18,480 leaves 872 ALMs for the
  whole wrapper, which is not enough. Jaguar CD therefore becomes a separate
  question, not a v1 feature (§8.4 lever 7).
* **BRAM is a non-issue**, decisively. 43 of 308 blocks for a cart-only core.
  doc 08's earlier estimate of 34-41 M10K for the console proper was accurate
  (measured 46 including Butch, 36 without).
* **DSP is a non-issue**: 7 of 66.

### What `FAST_SDRAM` actually costs — confirmed

`539 / 553` RAM blocks on MiSTer, i.e. **97 % of a device with 553 blocks**,
because the three `spram_byte_32x15` caches take **384** of them. Pocket has
308 *in total*. The single-SDRAM configuration is therefore unportable exactly
as predicted, and the dual build's single cache (128 blocks) would still be
42 % of Pocket's BRAM. doc 04 §4.5 Stage B (cache in the external SRAM chip)
stands.

## 8.1b MEASURED ON POCKET — Milestone 2

`5CEBA4F23C8`, Quartus 21.1.1, cart-only (`NO_JAGUAR_CD`), **Fitter Successful**:

| | Used | Available | % |
|---|---|---|---|
| **ALMs** | **12,726** | 18,480 | **69 %** |
| Registers | 11,308 | — | — |
| **M10K blocks** | **39** | 308 | **13 %** |
| Block memory bits | 236,672 | 3,153,920 | 8 % |
| **DSP blocks** | **7** | 66 | 11 % |
| PLLs | 1 | 4 | 25 % |
| Pins | 224 | 224 | 100 % |

### Where the ALMs go

| Entity | ALMs | M10K | DSP |
|---|---|---|---|
| `apf_top` (everything) | **12,726** | 39 | 7 |
| `core_top:ic` | 12,538 | 39 | 7 |
| &nbsp;&nbsp;`jaguar_top` | 12,054 | 36 | 7 |
| &nbsp;&nbsp;&nbsp;&nbsp;**`jaguar` (the console)** | **11,688** | 36 | 7 |
| &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;`_tom` | 5,706 | 12 | 5 |
| &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;`m68kcpu` (nuked-68k) | 3,202 | 14 | 0 |
| &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;`_j_jerry` | 2,334 | 10 | 2 |
| &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;EEPROM, `gamedrive`, `tda1545a`, flip-flops | ~240 | 0 | 0 |
| &nbsp;&nbsp;&nbsp;&nbsp;`jaguar_top` glue (incl. the `sdram` controller) | 366 | 0 | 0 |
| &nbsp;&nbsp;`core_bridge_cmd` | 176 | 2 | 0 |
| &nbsp;&nbsp;`data_loader` ×2 | 199 | 0 | 0 |
| &nbsp;&nbsp;`sound_i2s` | 72 | 1 | 0 |
| &nbsp;&nbsp;`jaguar_video` | 29 | 0 | 0 |
| `io_pad_controller` + `io_bridge_peripheral` | 179 | 0 | 0 |

**The APF framework is ~355 ALMs**, against the 1,000-2,000 estimated before M0
and the 7,056 that MiSTer's framework consumed. That is the single biggest
reason this fits.

### Versus the M0 prediction

M0 predicted cart-only `jaguar` at 17,608 − 6,814 = **10,794 ALMs**. Measured:
**11,688** — 894 higher, +8 %.

The difference is almost entirely `_tom` (4,604 → 5,706) and `_j_jerry`
(1,953 → 2,334). Same RTL, so this is synthesis settings, not design:
**upstream's `Jaguar.qsf` carries an aggressive optimisation block that was
not ported into `projects/jaguar_pocket.qsf`** —
`OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"`,
`PHYSICAL_SYNTHESIS_COMBO_LOGIC`, `PHYSICAL_SYNTHESIS_REGISTER_RETIMING`,
`ROUTER_LCELL_INSERTION_AND_LOGIC_DUPLICATION`, `MUX_RESTRUCTURE`,
`ADV_NETLIST_OPT_SYNTH_WYSIWYG_REMAP`, `PRE_MAPPING_RESYNTHESIS` and others.
Porting those is an open lever worth roughly 1,000 ALMs and possibly some
timing (§8.8).

## 8.2 BRAM inventory (computed from the RTL, pre-M0)

M10K configurations used below: single/simple-dual-port up to ×40
(256×40), true-dual-port up to ×16 (512×16).

### Inside `jaguar` (the console itself)

| Memory | Geometry | Instances | Bits each | Est. M10K |
|---|---|---|---|---|
| `_aba032a` — GPU RAM (Tom) + DSP RAM ×2 (Jerry) | 1024×32 true-dual-port | 3 | 32,768 | **12** |
| `_ab8616a` — line buffer (A/B × lo/hi) | 512×16 single-port | 4 | 8,192 | **4** |
| `_ab8016a` — Object Processor CLUT 1/2 | 256×16 single-port | 2 | 4,096 | **2** |
| `_raa016a` — Jerry sine ROM | 1024×16 ROM | 1 | 16,384 | **2** |
| `_ra8008a/b/c` — CRY→RGB ROMs | 256×8 inferred ROM | 3 | 2,048 | 0-3 (may land in MLAB) |
| `_ra6032a` — GPU/DSP microcode ROM | 64×32 ROM | 2 | 2,048 | 0-2 (MLAB) |
| `_rd64x32` — GPU/DSP register file | 64×32 true-dual-port | 2 | 2,048 | 0-2 (MLAB) |
| nuked-68k `ucode` | 64×272, `ramstyle="M10K"` | 1 | 17,408 | **7** (⌈272/40⌉) |
| nuked-68k `ncode` | 256×272, `ramstyle="M10K"` | 1 | 69,632 | **7** |
| Butch CD: `cuet/cues/cuep/cuel` | 128×32 / 128×24 | 4 | 3-4 K | **4** |
| Butch CD: `audbufram` | 64×64 true-dual-port | 1 | 4,096 | **4** |
| Butch CD: misc (`bcd[100]`, `i2s_fifo`, `cue*t[64]` reg arrays, subcode) | small | — | — | 0-6 (mostly registers/MLAB) |
| **Subtotal, cart-only console** (no Butch) | | | | **≈ 34-41** |
| **Subtotal, with Butch** | | | | **≈ 42-55** |

If `fx68k` is selected instead of nuked: `uRom` (1024×17) ≈ 2 + `nanoRom`
(336×68) ≈ 4 = **6 M10K**, replacing nuked's 14. A net **8-block saving**
plus an ALM saving.

### Above `jaguar` (in `Jaguar.sv`)

| Memory | Geometry | Bits | Est. M10K |
|---|---|---|---|
| `cd_stream.sv` sector cache — `dpram #(11,16)` ×4 | 2048×16 ×4 | 131,072 | **16** |
| `cart_backram` — `dpram #(13,16)` | 8192×16 | 131,072 | **16** |
| `debug_rom` — `spram #(11,16)` | 2048×16 | 32,768 | **4** |
| `cd_eeprom_backram` — `dpram #(6,16)` | 64×16 | 1,024 | 0-1 |
| **`spram_byte_32x15`** (= 4 × `dpram #(15,8)`) | 32768×32 | 1,048,576 | **128 each** |

**`fastcache2` is dead code in the non-`FAST_SDRAM` build.** Its only read path
is `os_rom_q` (`Jaguar.sv:1230`), which selects `fastram2` *only* when
`bios_overwrote` is set — and `bios_overwrote` is declared `reg ... = 0` at
`:438` with its single assignment commented out at `:536`. So it is a constant
zero, `os_rom_q` always comes from `cart_qsc` (SDRAM ch2), and Quartus will
strip the whole 128-block instance. **The Jaguar BIOS needs no BRAM at all** —
it is read from SDRAM like the cart. Confirmed by signal tracing, to be
confirmed again against the M0 entity table.

### The headline number

| Configuration | Est. M10K | vs Pocket's 308 |
|---|---|---|
| Cart-only console, nuked 68k, no Butch/CD/saves/caches | **≈ 40** | 13 % |
| + Butch + `cd_stream` + saves + debug | **≈ 90** | 29 % |
| + **one** `spram_byte_32x15` (Memory Track window) | **≈ 218** | 71 % |
| *(`fastcache2`, the BIOS cache, is dead code and costs nothing — see above)* | — | — |
| + **three** `spram_byte_32x15` (`FAST_SDRAM`, i.e. MiSTer's single-SDRAM build) | **≈ 346** | **113 % — does not fit** |

**Conclusion 1: the MiSTer single-SDRAM configuration cannot be ported
literally.** `FAST_SDRAM`'s three 128 KB caches alone are 384 KB against
Pocket's 385 KB total BRAM.

**Conclusion 2: that is a solvable problem, not a wall.** The three caches hold
the *upper 32 bits* of three 256 KB windows of Jaguar DRAM. Pocket has an
otherwise completely unused external SRAM chip of exactly the right shape
(16-bit, fast, 128-256 KB). Moving the cache off-chip reclaims 128-384 M10K
blocks. See doc 04 §4.5 Stage B.

**Conclusion 3: BRAM is not the binding constraint once `FAST_SDRAM` is
off-chip.** A cart-only core with Butch and saves lands near 90 blocks (29 %).

## 8.3 ALM budget — measured

Superseded by §8.1a. The pre-M0 reasoning bounded the console at
"≲ 32,000-36,000 ALMs, and could be far less"; the measurement is **17,608**,
near the bottom of that range. The framework estimate of "6,000-10,000 ALMs"
measured **7,056**.

The qualitative calls held up too: `_mp1010a`×3 and `_mp16`×2 did map to DSP
blocks (7 used, not ALMs), and nuked-68k was indeed a large block — but
`_butch`, which the pre-M0 notes listed only as "3,114 lines of hand-written CD
controller", turned out to be the single biggest consumer at 6,814 ALMs.

## 8.4 Area-shedding levers, in order of cost/benefit

Apply only as the fitter demands, cheapest first:

| # | Lever | Est. saving | Cost |
|---|---|---|---|
| 1 | Delete `video_mixer`, `video_freak`, `hps_io`, `ddram`, second `sdram` | large (framework, not core) | none — mandatory anyway |
| 2 | Drop `FAST_SDRAM` BRAM caches | 384 KB BRAM | performance (doc 04) |
| 3 | Drop `debug_rom`, `cheatcodes`, `numstick`, `jag_lightgun`, `ps2_mouse`, `jag_team_tap`, keyboard decoder | small-medium ALM, 4 M10K | features |
| 4 | Drop `Butch` + `butch_i2s` + `cd_stream` + `save_slot` (cart-only core) | medium-large ALM, ~30 M10K | **no Jaguar CD, no saves** |
| 5 | `nuked-68k` → `fx68k` | medium ALM, 8 M10K | FC-signal inaccuracy, memtrack checksums |
| 6 | Drop the GPU **or** the DSP | large | breaks most games — not viable |
| 7 | Ship multiple `.rbf` variants in one `core.json` (`cores[]` array, as the SNES port does with main/PAL/SPC) | — | lets us ship a cart-only core *and* a CD core without one fitting constraint dominating | 

Lever 7 is strategically important: APF supports several bitstreams per core
package, selected by the user. **A cart-only Jaguar that fits is a shippable
product**, with CD support as a separate variant if and only if it fits.

## 8.5 Other Pocket-specific constraints

| Constraint | Impact |
|---|---|
| No DDR3 | the entire `ddram` path must be re-homed (doc 04) |
| One SDRAM | single-SDRAM latency regime (doc 04 §4.3) |
| PLLs: Cyclone V E A4 has a limited fPLL count, and APF uses some | one core PLL with 3-4 outputs should be enough (doc 03 §3.4); **verify PLL availability in the fit report** |
| `cart_tran_*` / `port_tran_*` level translators | must be driven to safe defaults or hardware can be damaged — copy the template's assignments verbatim |
| Pin assignments are fixed by APF | `ap_core.qsf` from the template; do not edit pin locations |
| `.rbf` must be bit-reversed (`.rbf_r` / `.rev`) for APF | the SNES port uses `pocketpublish/reverse.py`; APF template ships `bitstream.rbf_r` |
| Speed grade 8 | timing closure at 106.36 MHz is harder than on MiSTer (doc 03 §3.6) |
| Core must respond to host commands within APF's timeouts | `core_bridge_cmd` handles this; just do not stall `clk_74a` logic |

## 8.6 On "Jaguar cannot fit on Pocket" — settled

The claim is **false for a cart-only core and true for a CD core**, measured
rather than argued:

* cart-only console: **10,794 of 18,480 ALMs (58 %)**, 36 of 308 M10K (12 %)
* with Jaguar CD: 17,608 of 18,480 ALMs (95 %), leaving too little for the wrapper

Every pre-M0 prediction in this document held: BRAM comfortably fits, ALMs are
the binding constraint, and the cart-only configuration is what ships.

The remaining open risk is **timing, not area** — see §8.8.

## 8.8 Timing — MEASURED, and Q8 answered

Milestone 2, `5CEBA4F23C8`, Slow 1100mV 85C model:

| Clock | Achieved | Worst setup slack | TNS |
|---|---|---|---|
| `clk_sys` / `clk_ram` | **106.4283 MHz** | **−9.352 ns** | −26,580 ns |
| `clk_vid` (×2) | 26.6057 MHz | **+6.319 ns** | 0 |
| `clk_74a` | 74.2501 MHz | +2.505 ns | 0 |
| `bridge_spiclk` | 74.2501 MHz | +11.048 ns | 0 |

All **hold** slacks are positive (worst +0.218 ns), and minimum pulse width
passes (+0.783 ns).

### Pocket times BETTER than the shipping MiSTer core

| | Device | Speed grade | Worst setup slack |
|---|---|---|---|
| MiSTer `Jaguar_Single` | `5CSEBA6U23I7` | 7 | −13.146 ns |
| **Pocket `jaguar_pocket`** | `5CEBA4F23C8` | **8 (slower)** | **−9.352 ns** |

3.8 ns better on a *slower* part, because the design is 12,726 ALMs instead of
30,349 and the fitter has far more room. Doc 03 §3.6 treated the speed-grade
drop as the main timing risk; it turns out the area saving more than
compensates.

### Q8 ANSWERED: every failing path is in CE-gated blitter logic

`tools/timing-report.tcl` attributed the paths. **All 50 of the worst setup
paths — and all 2,000 sampled failing endpoints — are inside
`jaguar_inst`**, and every one of the worst 50 ends at the same place:

```
jaguar:jaguar_inst|_tom:tom_inst|_graphics:gpu_inst|_blit:blit_inst
  |_address:address_inst|_addrgen:addrgen_inst|Add3~61_...
```

the **blitter's address-generator carry chain**, launched from blitter A2
registers (`a2_flags[15]`, `a2_mask_y[1]`).

**Zero failing endpoints in the SDRAM controller, the wrapper, `data_loader`,
`sound_i2s` or APF** — i.e. zero in the logic that genuinely runs every
`clk_ram` cycle.

That confirms the hypothesis this section previously carried as an inference:

* The blitter is gated by `xvclk`, which fires once every **four** `clk_sys`
  cycles, so the hardware allows 4 × 9.4 = **37.6 ns**.
* The reported path takes 9.4 + 9.352 = **18.75 ns** — comfortably inside it,
  with about 18.8 ns of real margin.

### What this means for the SDC

Before M2 this document said the Pocket SDC "must carry real multicycle
constraints … so that STA separates genuine violations from artefacts". That
reasoning is now weaker, and the honest position is narrower: since **no
genuine single-cycle violations exist to be masked**, multicycle constraints
would make the report readable but would not change a single thing we know
about whether the core works. They are documentation, not a fix.

So they are **not** being added yet. The next real test is hardware (M3-M5),
not a prettier timing report. Revisit if and only if a genuine single-cycle
violation appears — in the SDRAM controller or the wrapper — at which point
the constraint has a job to do.

Remaining timing caveats, honestly stated:

* 18.75 ns assumes the blitter really is `xvclk`-gated end to end along that
  path. That follows from `_blit` being netlist-derived (doc 01 §1.4) but has
  not been proven per-register.
* The Slow 1100mV 85C corner is the right one to design to; the 0C and fast
  corners were not inspected.
* This says nothing about whether the SDRAM interface meets its *external* I/O
  timing, which is a board-level question the SDC does not yet constrain
  (doc 03 §3.7 / `core_constraints.sdc`). That is an M3 question.

### PLL accuracy

| Output | Target | Achieved | Error |
|---|---|---|---|
| `outclk_0` | 106.363636 MHz | **106.4283 MHz** | **+608 ppm** |
| `outclk_1`/`2` | 26.590909 MHz | 26.6057 MHz | +556 ppm |
| VCO | — | 638.5696 MHz | — |

608 ppm is a 0.06 % error: NTSC field rate becomes 59.976 Hz instead of 59.940,
and audio pitch shifts by about one cent. Both imperceptible, so this is
acceptable — but it is larger than it needs to be. The VCO landed at
638.57 MHz, near the bottom of the usable range, which limits fractional
resolution. Asking for more decimal places
(`"106.3636363636 MHz"`) or steering the VCO higher should improve it.
Logged as an open item, not a blocker.
