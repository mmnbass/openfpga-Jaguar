# 10. Staged plan

Mapped onto the agreed milestones. **The first objective is successful Quartus
synthesis, not booting a game.** Every milestone has a falsifiable exit
criterion and a logged measurement.

## Toolchain reality check (macOS)

Quartus does not run natively on macOS. Confirmed on this machine:

```
$ which quartus_sh quartus_map   → not found
$ sw_vers -productVersion        → 26.6.2
$ uname -m                       → arm64
$ which docker colima podman     → none installed
```

Two synthesis routes, and we want both:

| Route | Use for | Setup |
|---|---|---|
| **Docker, local** (`raetro/quartus:21.1`) | fast iteration, `quartus_map` loops | needs Docker Desktop or Colima. The image is `linux/amd64`, so on Apple Silicon it runs under emulation — correct but slow (expect a multiplier, not a rounding error, on fit times). |
| **GitHub Actions** (x86 runners) | authoritative full fits, timing reports, release builds | zero local setup; this is exactly how `agg23/openfpga-SNES` builds (`.github/workflows/build.yml` → `docker run raetro/quartus:21.1 quartus_sh -t generate.tcl`) |

Recommendation: **do `quartus_map` locally in Docker, do `quartus_fit`/`sta` in
Actions.** Mapping is where the iteration is; fitting is where the emulation
penalty hurts.

Prerequisite task (do this first, it gates everything):

```bash
brew install colima docker
colima start --vm-type vz --rosetta --cpu 8 --memory 12 --disk 80
```

`--vm-type vz --rosetta` boots an **ARM** VM under Apple's Virtualization
framework and lets Rosetta translate the `linux/amd64` Quartus binaries. Do
**not** use `colima start --arch x86_64`: that selects vmType `qemu` and
emulates the whole CPU, which is dramatically slower.

**Disk requirement: ~15 GB extracted** (`raetro/quartus:21.1` is 5.91 GB
compressed), plus VM overhead. Verify with `diskutil info /System/Volumes/Data`
before pulling — macOS behaves badly below a few GB free.

### Quartus version: the two builds need different images

**Measured, not assumed** (Milestone 0):

| Build | Image | Why |
|---|---|---|
| **Upstream Jaguar_MiSTer (M0)** | `raetro/quartus:17.1` | **required** |
| **Our Pocket project (M1+)** | `raetro/quartus:21.1` | matches the reference SNES port |

`sys/sys.qip` line 1 selects the PLL IP by Quartus *major version number*:

```tcl
set_global_assignment -name QIP_FILE \
  [join [list $::quartus(qip_path) pll_q [regexp -inline {[0-9]+} $quartus(version)] .qip] {}]
```

Only `sys/pll_q13.qip` and `sys/pll_q17.qip` exist. On Quartus 21 this resolves
to `sys/pll_q21.qip`, which does not exist, so **all four PLLs — `pll`,
`pll_hdmi`, `pll_cfg_hdmi`, `pll_audio` — come out undefined** and Analysis &
Synthesis fails with four `Error (12006)`s. `pll_q17.qip` is also what pulls in
`rtl/pll.qip` (the core's own 106.36/26.59/53.18 MHz PLL), which `files.qip`
never references directly.

So `LAST_QUARTUS_VERSION "17.0.2 Lite Edition"` in `Jaguar.qsf` is a **real
constraint**, not informational.

This coupling does **not** apply to the Pocket port, because our project does not
use `sys/` at all — we generate our own PLL against `clk_74b` (doc 03 §3.4) and
source APF's `platform/pocket/apf.qip` instead. Quartus 21.1 is therefore fine
for M1 onwards, and preferable since it is what `openfpga-SNES` is known to build
with.

---

## Milestone 0 — Jaguar_MiSTer builds unchanged

**Purpose:** establish that the toolchain works and that upstream is sane,
before we change anything. Also produces the MiSTer-side resource numbers that
make every later comparison meaningful.

| Task | Exit criterion |
|---|---|
| Stand up Colima + `raetro/quartus:21.1`, verify `quartus_sh --version` | version prints |
| Build upstream `Jaguar_Single.qpf` **unmodified** | `output_files/Jaguar.rbf` produced |
| Capture `Jaguar.fit.rpt` → *Resource Utilization by Entity* | **ALM/M10K/DSP per entity recorded in the log.** This single table is the most valuable artefact of M0 — it replaces every estimate in doc 08. |
| Capture `Jaguar.sta.rpt` Fmax for `clk_sys` on speed grade 7 | number recorded |
| Also build the dual-SDRAM `Jaguar.qpf` for comparison | both reports logged |

**Already done (no Quartus needed):** `tools/lint-jaguar.sh` proves the console
RTL elaborates standalone — zero unresolved modules, errors confined to three
files' `altsyncram` megafunction instances (doc 01 §1.7).

**Risk:** none that blocks. If upstream does not build, the problem is our
toolchain, which is exactly what M0 is for.

---

## Milestone 1 — Pocket project + Jaguar RTL reaches Quartus synthesis

**Purpose:** `quartus_map` with zero errors.

| Task | Notes |
|---|---|
| Create the repo layout of doc 09 §9.1 | `rtl/upstream/` is a verbatim copy, scripted so it can be re-synced |
| Copy `platform/pocket/` from core-template verbatim | never edited |
| Write `projects/jaguar_pocket.qsf` from `ap_core.qsf` | **pin assignments untouched** |
| Generate the PLL (106.363636 / 26.590909 / 26.590909@90°) from `clk_74b` | record achieved freq + ppm (doc 03 §3.4) |
| Write `rtl/jaguar_top.sv` per doc 09 §9.3 | delete list is explicit |
| Write `target/pocket/core_top.sv` per doc 09 §9.2 | video = constant colour; audio/PSRAM/SRAM tied off |
| Wire `data_loader` ×2 (cart, BIOS) | `OUTPUT_WORD_SIZE = 2` |
| Instantiate the single `sdram` with Pocket pin names | `FAST_SDRAM` **undefined**, `MISTER_DUAL_SDRAM` **undefined** |

**Exit criterion:** `quartus_map` returns 0 errors. Warnings are expected and
fine.

**Predicted failure modes, in likelihood order:**
1. `$readmemb("68k_ucode.txt")` cannot find the file → `SEARCH_PATH`.
2. Mixed-language VHDL (`bram.vhd`) not enabled → add `VHDL_FILE` properly.
3. Leftover `status[...]`, `ioctl_*`, `DDRAM_*`, `SDRAM2_*`, `USER_IN/OUT`,
   `HDMI_*` references in `jaguar_top.sv` → iterate.
4. `altsyncram` `intended_device_family = "Cyclone II"` rejected → override.

**Deliberately not done:** anything that could work. No audio, no real video, no
input, no CD, no saves.

---

## Milestone 2 — Fitter tells us whether it fits and what is killing us

**Purpose:** replace doc 08's estimates with measurements. **A resource-overflow
error that names the resource is a successful outcome.**

| Task | Exit criterion |
|---|---|
| `quartus_fit` | completes, or overflows with a named resource and amount |
| Extract *Resource Utilization by Entity* | logged, per doc 08 §8.7 |
| `quartus_sta` | Fmax for `clk_sys`/`clk_ram`, worst slack, top 10 failing paths with owning entity |
| Diff against the M0 MiSTer numbers | per-entity delta tells us what the framework removal actually bought |

**Then, and only then**, decide. Decision tree:

```
fits, timing closes          → M3
fits, timing fails           → doc 03 §3.6 ladder: SDC first, then seed/effort,
                               then pipeline the SDRAM controller, then fx68k
overflows ALMs < 1.3×        → doc 08 §8.4 levers 3 then 4 (cart-only core)
overflows ALMs > 1.5×        → levers 3+4+5 together, and reconsider whether a
                               cart-only variant is the only shippable target
overflows M10K               → confirm FAST_SDRAM is off; then levers 3, 4
```

**Updated by M0 (2026-10-02).** That prediction — "BRAM comfortably fits, ALMs
are the binding constraint, cart-only is what ships" — was correct on all three
counts. Measured: cart-only `jaguar` is **10,794 / 18,480 ALMs (58 %)** and
**36 / 308 M10K (12 %)**; with `_butch` it is 17,608 (95 %) and does not fit.

So M2's area question is largely pre-answered and its real job is **timing**:
run `report_timing -setup -npaths 50 -detail full_path` and establish whether
the ~13 ns setup failure seen in M0 is confined to CE-gated paths (doc 08 §8.8,
open question Q8). Also add the multicycle constraints that make STA honest.

---

## Milestone 3 — Pocket loads the bitstream without exploding

**Purpose:** prove the bitstream is structurally valid on real hardware.

| Task | Notes |
|---|---|
| `.rbf` → bit-reversed `.rbf_r` | `pocketpublish/reverse.py` or equivalent |
| Minimal `core.json` / `data.json` / `video.json` / `input.json` / `audio.json` / `interact.json` / `variants.json` | doc 05 §5.2, doc 06 §6.3 |
| Load on Pocket; core must not hang the Pocket OS | `status_boot_done`/`status_setup_done`/`status_running` from `core_bridge_cmd` must be driven correctly |
| **Side-task: SDRAM self-test bitstream** | the controller's own `ram64` probe (`sdram_dual.sv:239-275`) already writes and reads back column 0 vs column bit-9. Expose `ram64` on a bridge register. This answers "is Pocket's SDRAM 64 MB and correctly wired at 106 MHz" directly. |
| **Side-task: SRAM probe bitstream** | write/read the external SRAM over the full `sram_a[16:0]` range and report pass/fail + detected size via a bridge register. **Resolves the 128 KB vs 256 KB ambiguity in doc 04 §4.4 and measures achievable access time** — a prerequisite for Stage B. |

**Exit criterion:** core loads, constant-colour screen appears, Pocket OS stays
responsive, SDRAM and SRAM probes report pass.

---

## Milestone 4 — Get anything recognisable on screen

| Task | Notes |
|---|---|
| Write `jaguar_video.sv` (doc 09 §9.4) | 26.59 MHz pixel clock, pixel-double in /2 mode |
| Wire `video_rgb`/`de`/`hs`/`vs` from the real core | |
| Verify sync timing against `video.json` scaler modes | |
| Expect garbage first — that is progress | garbage with correct geometry means the video path is right and the console is not running yet |

**Exit criterion:** stable, correctly-sized raster with the core's own sync.
Content may be noise.

---

## Milestone 5 — BIOS / game execution

The first milestone where "does it work" is the question.

| Task | Notes |
|---|---|
| ROM + BIOS load verified | byte-order self-test via the `bios_m` / `cart_b` sniffers (doc 05 §5.3) |
| Bridge read-back of SDRAM contents | doc 05 §5.5 — decouples "did the ROM load" from "does the core run" |
| Restore `cart_backram`, `debug_rom` if dropped at M1 | |
| Boot the Jaguar BIOS to the rotating-cube logo | **this is the real M5 target** |
| Then a simple cart (Cybermorph is the pack-in and the usual first test) | |

**Exit criterion:** BIOS logo animates. Note that reaching the logo exercises
68k, Tom's video path, DRAM via SDRAM, the OP and the blitter — i.e. almost
everything. Expect to live here a while.

**Known hazard:** the single-SDRAM latency regime (doc 04 §4.3) without the
`FAST_SDRAM` caches is *worse* than MiSTer's single-SDRAM build. If the BIOS
boots but games glitch or hang, that is the expected failure and the answer is
doc 04 §4.5 Stage B (cart ROM → PSRAM, upper-32-bit cache → external SRAM), not
more debugging of the console RTL.

---

## Milestone 6 — Audio / input / compatibility / timing cleanup

| Area | Work |
|---|---|
| Audio | `sound_i2s`; measure the real `dac_sample_strobe` rate; `osnotify_inmenu` mute (doc 06 §6.4) |
| Input | map Pocket pad (doc 07 §7.3); restore `numstick` overlay; L/R keypad modifier scheme; dock players 2-4 |
| Memory | implement doc 04 Stage B if M5 showed the need; re-measure |
| Config | `interact.json` variables + bridge register decode, replacing the M1 parameters (doc 09 §9.3) |
| Saves | `data_unloader` + `nonvolatile` slots for cart NVRAM; Memory Track |
| Timing | close `clk_sys` at 106.36 MHz properly; eliminate SDC exceptions |
| Compatibility | run a game list; log per-game status |
| CD (stretch) | `cd_stream.sv` re-homed onto `target_dataslot_read` + PSRAM. Large. Likely a separate `.rbf` variant (doc 08 §8.4 lever 7). |

---

## Milestone 7 — Package a public openFPGA release

| Task | Notes |
|---|---|
| Finalise all seven `.json` files | model on `refs/openfpga-SNES/pkg/pocket/Cores/agg23.SNES/` |
| `Platforms/jaguar.json` + platform image | |
| Multiple `cores[]` entries if we ship cart-only + CD variants | |
| GitHub Actions release workflow | adapt `openfpga-SNES/.github/workflows/build.yml` |
| Licensing | **Jaguar_MiSTer is GPL-2.0-or-later. Our port must be GPL too, with full source published.** `data_loader`/`psram`/`sound_i2s` from openfpga-SNES are MIT — compatible, keep their notices. |
| Attribution | Torlus (Gregory Estrade) original core; ElectronAsh, Kitrinx, GreyRogue, Sorgelig for MiSTer; agg23 for the Pocket support modules. Non-negotiable. |
| BIOS | **must not be redistributed.** Document that users supply `jagboot.rom` themselves, as MiSTer and the GBA Pocket core do. |

---

## Cross-cutting rules

1. **`rtl/upstream/` is never hand-edited.** Changes that must touch upstream
   RTL go in a patch file under `patches/` plus a note in UPSTREAM.txt, so
   upstream syncs stay possible. Set up the equivalent of the SNES port's
   nightly `upstream.yml` once the port is alive.
2. **No RTL rewrites before M2.** The fitter decides what gets rewritten.
3. **Every build is recorded** with date, commit, config, and the seven
   measurements of doc 08 §8.7 — even failed builds, especially failed builds.
4. **One variable per build.** When chasing timing or area, change one thing.
5. **Claims about fitting are measurements or they are nothing.**
