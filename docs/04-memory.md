# 4. Memory interfaces and bandwidth requirements

This is the hardest part of the port. Read §4.4 first if you only read one
section.

## 4.1 What the Jaguar hardware needs

| Region | Size | Width | Notes |
|---|---|---|---|
| Main DRAM | 2 MB | **64 bit** | 4 × 16-bit fast-page-mode DRAM on the real board (`rtl/notes.txt` identifies them as OKI M514170 / HM514260 class). Driven by Tom's own RAS/CAS controller. |
| Cartridge ROM | up to 16 MB (6 MB typical max for retail) | 32 bit | `cart_ce_n`, `cart_q[31:0]` |
| Boot ROM (jagboot) | 128 KB | 8 bit | `os_rom_ce_n`, `os_rom_q[7:0]` |
| CD BIOS (jagcd) | 256 KB | — | optional, Jaguar CD |
| Memory Track BIOS | 128 KB | — | optional |
| Memory Track save RAM | 128 KB | 16 bit | window at `0x900000-0x91FFFF` |
| Cart NVRAM (EEPROM 93C46) | 128 B | 16 bit | BRAM |
| CD EEPROM | 128 B | 16 bit | BRAM |

## 4.2 How Jaguar_MiSTer maps that

`rtl/mem/sdram_dual.sv:22-36` is the authoritative comment block:

```
-BA 0 and 1 used for DRAM
-Original DRAM uses columns A0-A7 and rows A0-A9 x16 = 256 addresses per active, 4 chips
-SDRAM uses columns SA3-SA10 which map to A0-A7. SA0 selects between 2 chips.
 BA0 swaps the other chips in single RAM. Dual RAM uses the other SDRAM chip.
-BA 2 and 3 used for ROM and BIOSes
-Jag M BIOS       : Bank 3, row 7F
-NVROM BIOS       : Bank 3, row 7E
-CDROM BIOS       : Bank 3, rows 7C-7D
-Cart ROM (≤16MB) : Banks 2 and 3, rows 00-7F
-For 64MB SDRAM, BIOSes move to rows FC-FF so there is no overlap
```

Three logical channels on one controller:

| Ch | Width | Client | Interface style |
|---|---|---|---|
| `ch1` | 64 bit (or 32 + 32 across two chips) | Jaguar DRAM | **raw RAS/CAS passthrough** — `ch1_act`, `ch1_pch`, `ch1_ref`, `ch1_reqr`, `ch1_reqw`, `ch1_caddr`. Tom drives the DRAM protocol; the controller translates it to SDRAM commands. |
| `ch2` | 16 bit write / 32 bit read | cart ROM, BIOSes, ROM loading | request/ready with auto-precharge |
| `ch3` | — | tied off (`ch3_req=1'b1`, dout unused); only `ch3_addr` is used, as a side channel into `ch_tmp` address remapping | vestigial |

Plus a **DDR3 path** (`Jaguar.sv:976-1000`) used for CD audio/data reads
(`audbus_out`) and as the staging target during BIOS download. Pocket has no
DDR3 at all.

And a **BRAM "fastcache"** layer (`Jaguar.sv:1254-1349`) active only when
`FAST_SDRAM` is defined (i.e. single-SDRAM builds): three
`spram_byte_32x15` instances, each 32768 × 32 bit = **128 KB**, each caching the
**upper 32 bits** of one 256 KB window of Jaguar DRAM, selected by
`sdram_addr[17:15]` against the OSD-chosen window numbers
(`status[36:34]`, `status[39:37]`). `use_fastram` then lets the SDRAM serve only
the lower 32 bits, restoring dual-chip-like latency inside those windows.

## 4.3 Bandwidth and latency arithmetic

**Jaguar demand.** Tom's DRAM controller can issue one 64-bit page-mode access
per video clock:

```
64 bit × 26.590909 MHz = 1.702 Gbit/s = 212.7 MB/s
budget per access      = 1 / 26.590909 MHz = 37.6 ns
```

**Supply, per 16-bit SDRAM at 106.363636 MHz:** the raw bus rate is also
`1.702 Gbit/s = 212.7 MB/s`, i.e. identical to demand — so there is no margin
even before protocol overhead. The *achieved* rate is considerably worse.

**Measured turnaround** — `sim/run-sdram-tb.sh` simulates the real controller
(`CAS_LATENCY=2`, `BURST_LENGTH=2`, `self_refresh=1`) at 106.363636 MHz with the
request line held permanently asserted, and observes the SDRAM command bus:

| Case | Cycles | Time | vs 37.6 ns budget | Sustained |
|---|---|---|---|---|
| **64-bit read, one chip** (`ch1_64=1`) | **7** | 65.8 ns | **1.75×** | **121.6 MB/s** |
| **32-bit read, two chips in parallel** (`ch1_64=0`) | **5** | 47.0 ns | **1.25×** | **170.2 MB/s** |
| **64-bit write, one chip** | **4** | 37.6 ns | **1.00×** | 212.7 MB/s |
| ch2 read (`ACTIVE` + auto-precharge) | **6** | 56.4 ns | 1.50× | — |
| Refresh | 7 | 65.8 ns | — | every `cycles_per_refresh = 780` |

Three things fall out of this that the arithmetic alone did not show:

1. **Reads are the entire problem; writes are not.** A 64-bit write is four
   single-location `WRITE` commands issued back-to-back with no CAS latency to
   wait out — 4 cycles, exactly on budget. Reads pay CL=2 plus the burst, and on
   one chip they pay it twice.
2. **Even *dual* SDRAM only reaches 170.2 MB/s against Jaguar's 212.7 MB/s peak
   demand — 80 %.** So MiSTer's dual-SDRAM build does not work because the
   bandwidth is sufficient; it works because Tom does not actually issue a
   64-bit read every single video clock. This is a correction to the "exactly
   zero margin" framing: the honest figures are **57 % of demand on one chip and
   80 % on two**.
3. That 57 % is the quantitative form of upstream's "single RAM builds boot,
   some with glitches or slow down" — and it is *before* ch2 cart traffic steals
   6 cycles per access from the same bus, which is the strongest argument for
   Stage B moving cart ROM to PSRAM.

Reproduce with:

```bash
sim/run-sdram-tb.sh          # Verilator, runs natively on macOS, no Quartus
```

> Model caveat: `sim/sdram_model.sv` folds the address space down to 64 K words,
> so the controller's 32 MB-vs-64 MB startup probe (`sdram_dual.sv:239-275`)
> reports `ram64 = 0` under simulation. That is an artefact of the simplified
> model, **not** a statement about real hardware — the probe is still a useful
> runtime self-test on Pocket (doc 04 §4.6, resolved at M3).


Note also that **`ch1_ready` is not a usable busy flag for reads**: `STATE_IDLE`
asserts it every cycle and the ch1 read path never clears it (only the write
path does, at `STATE_RW2`). That is why `Jaguar.sv` derives its own
`ram_rdy` instead (`Jaguar.sv:1063`):
```verilog
wire ram_rdy = ~ch1_64 || ~ch1_req || use_fastram;   // "Latency kludge."
```
In dual-SDRAM mode (`ch1_64 = 0`) `ram_rdy` is permanently high and the core is
never stalled. In single-SDRAM mode it stalls Tom whenever a 64-bit access is
outstanding and not served from the fastcache.

## 4.4 Pocket memory inventory

From `core-template/src/fpga/core/core_top.v`, confirmed against
`agg23/openfpga-SNES`:

| Resource | Port group | Geometry | Characteristics |
|---|---|---|---|
| **SDRAM** | `dram_a[12:0]`, `dram_ba[1:0]`, `dram_dq[15:0]`, `dram_dqm[1:0]`, `dram_clk/cke/ras_n/cas_n/we_n` | **512 Mbit, 16-bit** → 13 row + 10 col + 2 bank = 64 MB | Same class of part MiSTer uses. Reference port runs it at 85.9 MHz; we need 106.36 MHz. |
| **PSRAM ×2** ("cellular RAM") | `cram0_*`, `cram1_*`; `a[21:16]` + address multiplexed onto `dq[15:0]`, `ce0_n`/`ce1_n`, `adv_n`, `cre`, `wait`, `oe_n`, `we_n`, `ub_n`, `lb_n` | "64 Mbit ×2 dual die per chip" = **16 MB per chip, 32 MB total**, 16-bit | Async access ≈ 70 ns (`psram.sv: MAX_ACCESS_TIME_FROM_ADV = 70`), or synchronous burst. **High random-access latency.** |
| **SRAM** | `sram_a[16:0]`, `sram_dq[15:0]`, `sram_oe_n/we_n/ub_n/lb_n` | address range implies 128 Ki × 16 = **256 KB**; template comment says "1mbit 16bit" (= 128 KB) — **verify on hardware** | Genuine fast async SRAM. Unused by every reference core we looked at. |
| **BRAM** | — | 308 × M10K = 3,080 Kbit = **385 KB** | vs MiSTer's 553 × M10K = 692 KB |
| DDR3 | — | **none** | |

Note the asymmetry: Pocket's *external* memory is more generous than MiSTer's
single-SDRAM configuration (64 MB SDRAM + 32 MB PSRAM + SRAM vs 32/64 MB SDRAM),
but its *internal* BRAM is 56 % of MiSTer's and it has no DDR3.

## 4.5 Target Pocket memory architecture

### Stage A — "make it synthesise" (Milestones 1-2)

Simplest possible mapping. Do not optimise yet.

| Jaguar need | Pocket | How |
|---|---|---|
| ch1 Jaguar DRAM (64-bit) | SDRAM BA0/BA1 | `sdram_dual.sv` with `ch1_64 = 1`, single instance, pin names remapped |
| ch2 cart ROM + BIOSes | SDRAM BA2/BA3 | unchanged |
| `FAST_SDRAM` BRAM caches | **omitted** | 3 × 128 KB = 384 KB > 385 KB total BRAM. Cannot fit. See doc 08. |
| DDR3 CD path | **removed** | CD support cut for M1-M5 |
| Memory Track 128 KB cache | **omitted** | Memory Track cut for M1-M5 |

Expected consequence: worse than MiSTer's single-SDRAM build, because we lose
the fastcache too. That is acceptable — Stage A exists to produce a fitter
report, not a playable core.

### Stage B — the architecture we actually want

| Jaguar need | Pocket resource | Rationale |
|---|---|---|
| ch1 Jaguar DRAM lower 32 bits | **SDRAM**, all 4 banks | SDRAM does nothing else, so no ch2 contention and the full 212 MB/s is available to ch1 |
| ch1 Jaguar DRAM upper 32 bits, hot windows | **SRAM** (128-256 KB, fast async, 16-bit) | This is the `fastram[63:32]` role, moved from BRAM to the otherwise-idle SRAM chip. 256 KB of SRAM = 64 Ki × 32 bit = the upper half of **512 KB** of Jaguar DRAM = 2 of the 8 `sdram_addr[17:15]` windows — i.e. **2/3 of the MiSTer single-SDRAM fastcache coverage at zero BRAM cost.** |
| ch1 upper 32 bits, cold windows | SDRAM second burst | falls back to the 7-cycle path |
| ch2 cart ROM (≤16 MB) | **PSRAM `cram0`** | exact size match; 70 ns ≈ 7.5 cycles @106 MHz, comparable to the 6-cycle SDRAM ch2 path, and it removes all ch2 traffic from the SDRAM |
| BIOS / CD BIOS / MemTrack BIOS / MemTrack save | **PSRAM `cram1`** | 512 KB of BIOS + 128 KB save in 16 MB |
| CD sector staging (if CD support returns) | PSRAM `cram1` | replaces the DDR3 path |
| EEPROMs, line buffers, CLUTs, GPU/DSP RAM, 68k ucode | BRAM | unchanged |

Open risks in Stage B, all resolvable only by measurement:

1. **Is the SRAM actually 256 KB, and how fast?** 17 address bits are wired; the
   template comment disagrees with the pin count. A 10 ns async SRAM gives 32
   bits in 2-4 cycles at 106 MHz, which lands on the 37.6 ns budget. A slower
   part does not. **Test with a dedicated SRAM read/write loopback bitstream
   (Milestone 3 side-task) before designing around it.**
2. **PSRAM random-read latency for cart ROM.** The core has no ready/stall on
   `cart_q` (`.xwaitl(1'b1)` is tied off at `Jaguar.sv:739`). Either the latency
   fits inside the existing `cart_rd_trig` → `cart_qs` window or we must add a
   stall. `cart_wrack` already gates ROM *loading*; reads are the question.
3. **SDRAM at 106.36 MHz on a C8 part.** The reference SNES port runs 85.9 MHz.
   143 MHz-rated parts are normal here, but board routing and I/O timing must be
   proven. `altddio_out` for `dram_clk` (already in `sdram_dual.sv:472`) plus
   output-delay constraints in the SDC is the known-good recipe.

## 4.6 Things to delete, not port

* `rtl/mem/ddram.sv` and all `DDRAM_*` logic in `Jaguar.sv`.
* The `SDRAM2_*` instance (`Jaguar.sv:1502-1551`) — keep the source, `ifdef` it out.
* `sdram_sz` from `hps_io`; Pocket's SDRAM is fixed. The controller's own
  startup probe (`sdram_dual.sv:239-275`, writes column 0 and column bit-9 and
  reads back to set `ram64`) still works and should be left in — it is a useful
  self-test that the SDRAM is wired correctly, and it will tell us at runtime
  whether Pocket's part reports as 64 MB.
