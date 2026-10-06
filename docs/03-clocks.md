# 3. Clocks and required clock frequencies

## 3.1 What MiSTer generates

`rtl/pll/pll_0002.v`, from `CLK_50M`:

| Output | Frequency | Used for |
|---|---|---|
| `outclk_0` | **106.363636 MHz** | `clk_106m` → `clk_sys` (with `FAST_CLOCK`) **and** `clk_ram` |
| `outclk_1` | 26.590909 MHz | `clk_26m` — declared in `Jaguar.sv:62` but **not connected to anything** |
| `outclk_2` | 53.181818 MHz | `clk_53m` — `clk_sys` only on the dead `!FAST_CLOCK` path |

`Jaguar.sv:73-80`:
```verilog
`ifdef FAST_CLOCK
wire clk_sys = clk_106m;
`else
wire clk_sys = clk_53m;
`endif
wire clk_ram = clk_106m;
```
`FAST_CLOCK` is defined unconditionally at `Jaguar.sv:58`.

Also present but separate: `sys/pll_audio*` (MiSTer HDMI/audio), `sys/pll_cfg`
(PLL reconfiguration for HDMI modes). Neither is needed on Pocket.

## 3.2 Why 106.363636 MHz is not negotiable

The Jaguar video clock is

```
26.590909… MHz = (315/88 MHz NTSC colour burst) × 52/7 = 1170/44 MHz
```

and `rtl/jaguar.v` derives all four internal CE phases by a **fixed /4** of
`sys_clk` with a hard-coded 2-bit counter (doc 01 §1.4). Therefore:

```
clk_sys = 4 × 26.590909… = 106.363636… MHz      (= 1170/11 MHz)
```

Changing this requires editing the netlist-derived timing assumptions, which is
exactly what we are not doing. Treat 106.363636 MHz as a hard constraint on the
Pocket build.

PAL: the core takes an `ntsc` input and changes *counters*, not the clock
(`Jaguar.sv:85`, `jaguar.v .ntsc()`). Real Jaguar PAL clock is 26.593900 MHz —
within 0.01 % — so a single PLL config covers both. No PAL PLL variant needed
(unlike the SNES port, which ships two).

## 3.3 Pocket clock sources

APF gives the core two reference clocks (`core_top` ports):

* `clk_74a` — 74.25 MHz, the bridge/host domain. **All `bridge_*`, `cont*_key`,
  `dataslot_*`, `target_dataslot_*` signals are synchronous to this.**
* `clk_74b` — a second 74.25 MHz, *not phase aligned* to `clk_74a`.

> **CORRECTED after the first hardware test.** This document originally said
> `clk_74b` was "conventionally used as the core PLL reference". That was my
> assumption and it was never checked against a working core. **Analogue's
> core-template and openfpga-SNES both reference the PLL to `clk_74a`.** The
> first build that used `clk_74b` failed on hardware with *"Load error in
> 'core' / Error in core setup"* — consistent with the PLL never locking, so
> `status_boot_done` never asserting and the host's setup handshake timing out.
> Use `clk_74a`.

## 3.4 Required Pocket PLL configuration

One `altera_pll` (fractional mode), reference **`clk_74a`** = 74.25 MHz:

| Output | Target | Purpose | Notes |
|---|---|---|---|
| `outclk_0` | **106.363636 MHz** | `clk_sys` **and** `clk_ram` (SDRAM controller) | hard requirement |
| `outclk_1` | **26.590909 MHz** | `video_rgb_clock` | must be phase-related to `clk_sys` (it is: same PLL, /4) |
| `outclk_2` | **26.590909 MHz, +90°** | `video_rgb_clock_90` | APF requirement |
| `outclk_3` | 106.363636 MHz, phase-shifted | SDRAM `dram_clk` if the DDIO trick proves insufficient | hold in reserve |

74.25 → 106.363636 is `M/N = 520/363`, not realisable with integer M/N inside
Cyclone V limits. It **is** realisable with the fractional PLL, which is exactly
how the reference SNES port makes 85.909080 MHz / 21.477270 MHz from 74.25 MHz
(`refs/openfpga-SNES/target/pocket/mf_pllbase/mf_pllbase_0002.v`). Generate ours
the same way: Quartus IP Catalog → *Altera PLL* → fractional mode, and type the
frequency in. **Record the achieved frequency and ppm error from the PLL
summary in the engineering log** — a few ppm is fine, a few hundred is not.

## 3.5 Clock domain crossings in the Pocket design

| From | To | Crossing | Mechanism |
|---|---|---|---|
| `clk_74a` (bridge writes) | `clk_sys` (106.36) | ROM/BIOS data, config registers | `data_loader` already does this (toggle/handshake); config regs via standard 2-FF sync |
| `clk_74a` (`cont1_key` etc.) | `clk_sys` | controller state | 2-FF sync per bit; no coherency requirement (buttons) |
| `clk_sys` | `clk_74a` | `datatable_*`, `target_dataslot_*` | `data_unloader` / explicit handshake |
| `clk_sys` | 26.59 video | pixel data | **none** — same PLL, integer ratio, treat as synchronous and constrain accordingly |

## 3.6 Timing risk — be explicit about it

| | MiSTer | Pocket |
|---|---|---|
| Device | `5CSEBA6U23I7` | `5CEBA4F23C8` |
| Speed grade | **7** (industrial) | **8** (commercial) — slower |
| `clk_sys` requirement | 106.36 MHz | 106.36 MHz (same) |

So we must hit the same frequency on a slower part. That is the single biggest
*timing* unknown (area is the biggest *fitting* unknown — doc 08). It is not a
reason to assume failure: the netlist-derived logic is shallow by construction
(it was a gate-level netlist), and the known-hard paths are likely to be the
SDRAM controller and the blitter's inner loop, both of which are localised.

Mitigations, in the order we should try them:

1. Let the fitter tell us. Get `quartus_sta` to emit the real failing paths
   before guessing.
2. Raise fitter effort / seed sweep (`SEED`, `OPTIMIZATION_MODE`), as upstream
   already does (`Jaguar.qsf` has an aggressive physical-synthesis block — port
   those assignments across).
3. Pipeline the SDRAM controller's address/data paths (it is our code to touch,
   unlike the netlist).
4. If the 68000 is on a critical path, swap `m68kcpu` → `fx68k` (`ACCURATE_CPU`),
   accepting the known memtrack/FC inaccuracy.
5. Only then consider touching netlist-derived logic.

## 3.6a MEASURED — Milestone 2

| Output | Target | Achieved | Error |
|---|---|---|---|
| `outclk_0` (`clk_sys`/`clk_ram`) | 106.363636 MHz | **106.4283 MHz** | **+608 ppm** |
| `outclk_1`/`outclk_2` (`clk_vid`) | 26.590909 MHz | 26.6057 MHz | +556 ppm |
| VCO | — | 638.5696 MHz | — |

608 ppm = 0.06 %: NTSC field rate 59.976 Hz instead of 59.940, audio pitch off
by about one cent. Imperceptible, so acceptable — but larger than necessary.
The VCO landed near the bottom of its usable range, which limits fractional
resolution; more decimal places in `output_clock_frequency0` or a higher VCO
should improve it.

**The speed-grade worry in §3.6 did not materialise.** Pocket (grade 8) closed
3.8 ns *better* than MiSTer (grade 7) — −9.352 ns against −13.146 ns — because
the Pocket design is 12,726 ALMs instead of 30,349 and the fitter has far more
room. The mitigation ladder in §3.6 was not needed; in particular the
nuked-68k → FX68K swap (step 4) is not required.

Still unconstrained, and now the main clocking risk: the **external** SDRAM I/O
timing (§3.7 / `target/pocket/core_constraints.sdc` carries the delays
commented out). That is an M3 question.

## 3.7 Measurement checklist

Record for every build:

* PLL achieved frequencies + ppm error
* `quartus_sta` Fmax for `clk_sys`, `clk_ram`, video clock
* Worst setup slack and the top 10 failing paths, with the owning module
* Whether `dram_clk` used DDIO (`altddio_out`) or a phase-shifted PLL output
