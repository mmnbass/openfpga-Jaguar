> Historical: the port overview as it stood at Milestone 2 (2026-10-02). Kept for the engineering record; the top-level README describes the released core.

# Atari Jaguar for Analogue Pocket (openFPGA)

A port of [**Jaguar_MiSTer**](https://github.com/MiSTer-devel/Jaguar_MiSTer) to
the Analogue Pocket's openFPGA platform.

This is a **platform-porting and FPGA resource/timing problem**, not a
clean-room Jaguar implementation. The MiSTer core is the reference and is
preserved wherever possible: `rtl/jaguar.v` and everything below it is intended
to be used unmodified.

> **Current state: Milestone 2 complete — the core fits and is built.**
> A cart-only Jaguar fits `5CEBA4F23C8` at **12,347 / 18,480 ALMs (67 %)**,
> **39 / 308 M10K (13 %)**, 7 / 66 DSP — Fitter Successful on Quartus 21.1.1.
> Timing is *better* than the shipping MiSTer core (−9.35 ns vs −13.15 ns) on a
> slower speed grade, and every failing path is clock-enable-gated blitter logic
> with 4× the budget it is being measured against.
> Next: Milestone 3, load it on hardware.
> (The engineering log is kept in the development archive.)

## Why this is believed to be feasible

* The entire console (`rtl/jaguar.v` and below, 128 module types) is a single
  clock domain with clock enables, and it elaborates cleanly standalone —
  verified with Verilator.
* All MiSTer coupling lives in `Jaguar.sv`, which is roughly 15 % console and
  85 % platform glue.
* Pocket's external memory is *better* than MiSTer's single-SDRAM
  configuration: 64 MB SDRAM + 2 × 16 MB PSRAM + an SRAM chip that no reference
  core uses.
* A Jaguar core has reportedly been demonstrated on Pocket hardware.

## Measured facts

**On Pocket** (`5CEBA4F23C8`, Quartus 21.1.1, cart-only, Fitter Successful):

| | Used | Available | % |
|---|---|---|---|
| ALMs | **12,347** | 18,480 | **67 %** |
| M10K | **39** | 308 | **13 %** |
| DSP | 7 | 66 | 11 % |
| PLLs | 1 | 4 | 25 % |

Of which `jaguar` itself is **11,415 ALMs**; `_tom` 5,600, nuked-68k 3,201,
`_j_jerry` 2,205. The whole APF framework is ~355 ALMs, against MiSTer's 7,056
— which is the single biggest reason this fits.

**Why cart-only:** on MiSTer, `_butch` (the Jaguar CD controller) measures
**6,814 ALMs — 39 % of the console**, more than Tom. With it, `jaguar` is
17,608 of Pocket's 18,480 (95 %) and leaves no room for the wrapper.

## The remaining hard problems

1. **Timing, understood but not finished.** `clk_sys` shows −9.58 ns worst
   setup slack. All 2,000 sampled failing endpoints are inside `jaguar`, and
   every one of the worst 50 is the **blitter address-generator carry chain** —
   clock-enable-gated logic that has 37.6 ns in hardware against the 9.4 ns STA
   measures it with, so ~18.8 ns of real margin. Nothing fails in the SDRAM
   controller or wrapper. [`docs/08` §8.8](08-resources-and-constraints.md).
2. **SDRAM bandwidth.** Simulated: one 16-bit SDRAM sustains **121.6 MB/s**
   against Jaguar DRAM's 212.7 MB/s demand (57 %); two chips reach 170.2 MB/s
   (80 %). The fix moves cart ROM to PSRAM and the upper-32-bit cache to
   Pocket's unused external SRAM — [`docs/04` §4.5](04-memory.md).
3. **External SDRAM I/O timing** is not yet constrained at all — an M3
   question ([`docs/03` §3.7](03-clocks.md)).

## Documentation

| | |
|---|---|
| [01 — MiSTer architecture & hierarchy](01-mister-architecture.md) | module tree, netlist provenance, the CE clocking scheme |
| [02 — MiSTer dependencies to replace](02-mister-dependencies.md) | `hps_io`, `video_mixer`, DDR3, dual SDRAM, … |
| [03 — Clocks](03-clocks.md) | why 106.363636 MHz is non-negotiable |
| [04 — Memory & bandwidth](04-memory.md) | **read this one**; the SDRAM arithmetic and the Pocket mapping |
| [05 — ROM loading](05-rom-loading.md) | `ioctl_*` → APF data slots + `data_loader` |
| [06 — Video & audio](06-video-audio.md) | CE → pixel clock, I²S |
| [07 — Input](07-input.md) | 17 Jaguar buttons onto 9 Pocket buttons |
| [08 — Resources & constraints](08-resources-and-constraints.md) | device comparison, BRAM inventory, area-shedding levers |
| [09 — Minimum viable wrapper](09-minimum-viable-wrapper.md) | exactly what to write to reach `quartus_map` |
| [10 — Staged plan](10-staged-plan.md) | milestones M0-M7 with exit criteria |

## Milestones

| | Goal |
|---|---|
| **M0** | Jaguar_MiSTer builds unchanged *(blocked: no Quartus on macOS — see below)* |
| **M1** | Pocket project + Jaguar RTL reaches Quartus synthesis |
| **M2** | Fitter tells us whether it fits and what resources are killing us |
| **M3** | Pocket loads the bitstream without exploding |
| **M4** | Get anything recognisable on screen |
| **M5** | BIOS / game execution |
| **M6** | Audio / input / compatibility / timing cleanup |
| **M7** | Package a public openFPGA release |

M2's exit criterion deserves emphasis: **a resource-overflow error that names
the resource and the amount is a successful outcome.** It is the measurement the
whole project is waiting on.

## Getting set up

```bash
tools/fetch-refs.sh      # clone Jaguar_MiSTer, core-template, openfpga-SNES into refs/
tools/lint-jaguar.sh     # Verilator elaboration check — runs natively on macOS
```

### Quartus on macOS

Quartus is Windows/Linux only, so builds go through Docker:

```bash
brew install colima docker
colima start --vm-type vz --rosetta --cpu 8 --memory 12 --disk 80
tools/quartus.sh quartus_sh --version
```

`--vm-type vz --rosetta` runs an ARM VM and translates the `linux/amd64` Quartus
image with Rosetta. Do **not** use `colima start --arch x86_64` — that forces
QEMU and full CPU emulation, which is far slower.

**Disk: the extracted Quartus image needs ~15 GB.** Check `diskutil info
/System/Volumes/Data` first; macOS needs real headroom left over.

Plan: **`quartus_map` locally in Docker, `quartus_fit`/`quartus_sta` on GitHub
Actions x86 runners** (`.github/workflows/m0-upstream.yml`), which is how the
reference SNES port builds. CI needs no local disk at all.

Note the two builds need **different Quartus versions**: upstream Jaguar_MiSTer
requires **17.1** (`sys/sys.qip` selects its PLL IP by major version and only
ships `pll_q13`/`pll_q17`), while our Pocket project will use **21.1**. See
[docs/10](10-staged-plan.md).

## Reference material

| Repo | Role |
|---|---|
| [`MiSTer-devel/Jaguar_MiSTer`](https://github.com/MiSTer-devel/Jaguar_MiSTer) | the source project |
| [`open-fpga/core-template`](https://github.com/open-fpga/core-template) | APF, pin assignments, metadata schema |
| [`agg23/openfpga-SNES`](https://github.com/agg23/openfpga-SNES) | Rosetta Stone: a large MiSTer core on Pocket using SDRAM *and* both PSRAMs, with reusable `data_loader` / `data_unloader` / `psram` / `sound_i2s` |

Analogue's official docs (openFPGA Overview, Getting Started, Packaging a Core)
are the authority on APF semantics and `.json` schemas — re-check `parameters`
bitfields against the current docs before release.

## Licence and attribution

Jaguar_MiSTer is **GPL-2.0-or-later**, so this port is GPL and its full source
will be published. Support modules borrowed from `openfpga-SNES` are MIT.

Credit due to **Torlus (Gregory Estrade)** for the original Jaguar core,
**ElectronAsh, Kitrinx and GreyRogue** for the MiSTer port, **Sorgelig** for the
MiSTer framework and SDRAM controller, **agg23 (Adam Gastineau)** for the Pocket
support modules, and **Nuked** / **Jorge Cwik** for the 68000 implementations.

**The Jaguar BIOS is not redistributed.** Users must supply `jagboot.rom`
themselves.
