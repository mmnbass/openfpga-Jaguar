# 5. ROM loading path

## 5.1 MiSTer path (what we are replacing)

```
SD card file
  → HPS (Linux userspace, Main)
  → hps_io ioctl_* interface                        (Jaguar.sv:344-349)
      ioctl_download, ioctl_wr, ioctl_addr[24:0],
      ioctl_data[15:0], ioctl_index[7:0], ioctl_wait
  → loader_addr / loader_wr / loader_data_bs        (Jaguar.sv:375-581)
      byte-swapped: {loader_data[7:0], loader_data[15:8]}   (:989)
  → two destinations in parallel:
      (a) SDRAM ch2   at cart_ch2_addr              (:1441-1446)
      (b) DDR3        at legacy_ddram_addr          (:990-1000)
  → back-pressure: ioctl_wait = !cart_wrack,
      cart_wrack = sdram_ch2_ready                  (:424, :1124)
```

### ioctl_index decode (`Jaguar.sv:394-422`)

| `ioctl_index[5:0]` | Meaning | SDRAM ch2 base (`cart_ch2_addr | …`) |
|---|---|---|
| 0, `[7:6]==0` | legacy `boot.rom` / `boot0.rom` — Jaguar BIOS | `23'h7F0000` |
| 0, `[7:6]==1` | legacy `boot1.rom` — CD BIOS | `23'h7C0000` |
| 0, `[7:6]==2` | legacy `boot2.rom` — Memory Track BIOS | `23'h7E0000` |
| 1 | **cartridge** (`.jag .j64 .rom .bin`) | `23'h000000` |
| 2 | explicitly assigned Jaguar BIOS | `23'h7F0000` |
| 3 | explicitly assigned CD BIOS | `23'h7C0000` |
| 4 | explicitly assigned Memory Track BIOS | `23'h7E0000` |
| `0xFF` | cheat codes | → `CODES` |

Plus `cart_mask[22:20]` derived from the final `loader_addr` to size-mask the
cart (`Jaguar.sv:523-538`): 1 MB / 2 MB / 4 MB / "not exact, don't modify".

Three latching side-effects happen *during* the download stream and must be
preserved:

* `bios_m` — detects K vs M BIOS by sniffing opcode `0x67` at byte offsets
  `0x136E` and `0x19C6` (`:1140-1145`).
* `cart_b` / `bios_b` / `nvme_b` — detects 8/16/32-bit cart bus width by
  sniffing words at `0x400`/`0x402` (`:1147-1180`).
* `persistent_*_loaded` — so an explicitly assigned BIOS is not later clobbered
  by the legacy `boot*.rom` probe (`:402-417`).

## 5.2 APF path (what we build)

```
SD card file  /Assets/jaguar/common/<file>
  → Pocket OS, per data.json slot
  → bridge writes, 32-bit words, synchronous to clk_74a
      bridge_wr, bridge_addr[31:0], bridge_wr_data[31:0]
  → data_loader  (target/pocket/data_loader.sv, from agg23/openfpga-SNES)
      ADDRESS_MASK_UPPER_4 = <slot's address nibble>
      OUTPUT_WORD_SIZE     = 2      → 16-bit writes, matching ioctl_data
      clk_74a → clk_memory CDC is handled inside
  → write_en / write_addr / write_data   (in clk_sys domain)
  → same loader_addr / loader_wr / loader_data state machine, reused verbatim
  → SDRAM ch2 (Stage A) or PSRAM (Stage B)
```

### Mapping APF signals onto the MiSTer signals

| MiSTer | APF equivalent | Notes |
|---|---|---|
| `ioctl_download` | `dataslot_requestwrite` … `dataslot_allcomplete` | APF signals *start* per slot and a global *all complete*; there is no per-word "download active" flag. Hold a registered `download_active` between them. |
| `ioctl_index` | the slot id carried by `dataslot_requestwrite_id`, or simply the `bridge_addr[31:28]` nibble per slot | Prefer **one `data_loader` per slot** with a distinct address nibble — that is how the SNES port separates cart from save. |
| `ioctl_wr` | `write_en` from `data_loader` | |
| `ioctl_addr` | `write_addr` | |
| `ioctl_data[15:0]` | `write_data[15:0]` with `OUTPUT_WORD_SIZE=2` | |
| `ioctl_wait` | **no equivalent** | APF does not accept back-pressure. See §5.4. |
| `sdram_sz` | n/a | fixed |

### Proposed `data.json`

```json
{ "data": { "magic": "APF_VER_1", "data_slots": [
  { "name": "Cartridge",   "id": 1,  "required": true,  "parameters": "0x109",
    "extensions": ["jag","j64","rom","bin","abs","cof"], "address": "0x10000000" },
  { "name": "Jaguar BIOS", "id": 2,  "required": true,  "parameters": "0x101",
    "extensions": ["rom","bin"], "address": "0x20000000",
    "size_maximum": "0x20000" },
  { "name": "CD BIOS",     "id": 3,  "required": false, "parameters": "0x101",
    "extensions": ["rom","bin"], "address": "0x30000000",
    "size_maximum": "0x40000" },
  { "name": "MemTrack BIOS","id": 4, "required": false, "parameters": "0x101",
    "extensions": ["rom","bin"], "address": "0x40000000",
    "size_maximum": "0x20000" }
]}}
```

Address nibbles 1/2/3/4 deliberately echo the MiSTer `ioctl_index` values so the
existing decode logic stays readable. `parameters` bit meanings come from the
APF docs — copy the SNES values and adjust (`0x109` = core-specified filename +
required + instance JSON; confirm against the current *Packaging a Core* doc
before release).

For Milestone 1-2 only the Cartridge and Jaguar BIOS slots are needed.

## 5.3 Byte order — get this right once

* APF: `assign bridge_endian_little = 0;` (big-endian), per the template.
* MiSTer applies an explicit swap at `Jaguar.sv:989`:
  `loader_data_bs = {loader_data[7:0], loader_data[15:8]}`.
* Jaguar ROMs are big-endian 68000 images.

So there are three independent places a swap can be introduced (bridge endian
flag, `data_loader`'s own word splitting, the `loader_data_bs` swap). **Pick one
and verify with a known ROM header.** The verification target: a Jaguar cart
image has `0x802000` / `0x601C` style boot vectors and the universal header
string at offset `0x400`; the BIOS sniffers in §5.1 look for the literal word
`0x0202` and `0x0000` at word addresses `0x200`/`0x201`. **If those sniffers
latch correctly, byte order is right** — a free built-in self-test, and worth
exposing on a debug register.

## 5.4 Back-pressure: the one real design problem

MiSTer throttles the HPS with `ioctl_wait`. APF has no such mechanism — the
`data_loader` header notes *"APF sends data every ~75 74 MHz cycles, so you
cannot send data slower than this"*. 75 cycles @74.25 MHz ≈ 1010 ns, during
which `clk_sys` advances ~107 cycles. One 16-bit SDRAM ch2 write costs ~6
cycles. With `OUTPUT_WORD_SIZE=2` we emit two 16-bit words per bridge word, so
~12 cycles of SDRAM work per ~107 cycles available.

**Conclusion: there is ~9× headroom and `ioctl_wait` can simply be dropped.**

> **WRONG, found on hardware.** The average is fine,
> but the two 16-bit writes from one bridge word arrive ~5 `clk_sys` apart,
> and `sdram_dual` holds a single pending ch2 request that it serves only
> from IDLE. When the first lands during a refresh (~8 cycles, every 780) the
> second overwrites it, and ~0.3% of words are never written. The port now
> queues loader writes and issues one per 32 cycles (`rtl/jaguar_top.sv`,
> "Loader write queue"). Headroom on average is not headroom against a burst.
Set `cart_wrack` permanently high during loading and delete the wait path. This
must be re-checked if ROM loading ever targets PSRAM (Stage B), whose write
cycle is ~45-70 ns ≈ 5-8 cycles — still fine.

The one thing that *does* need care: `data_loader`'s `WRITE_MEM_CLOCK_DELAY`
must be ≥ the memory's write turnaround, or writes will be dropped. Start at the
SNES port's value and increase if the loaded image does not verify.

## 5.5 Verifying a load without a working console

Milestone 2-3 side-task, cheap and high value: add a **bridge read-back path**
so the host can read what landed in SDRAM.

* Reserve `bridge_addr[31:28] == 4'hF0` → a read port into SDRAM ch2.
* Use `data_unloader.sv` from the SNES port (it already does
  `clk_sys → clk_74a` and `target_dataslot_write`), or just expose a
  32-bit window at a bridge address and read it with the Pocket's own
  debug facilities.

This decouples "did the ROM load" from "does the console run", which is exactly
the separation we want across Milestones 3-5.

## 5.6 Deliberately out of scope until Milestone 6+

* CD images (`.cdi`). MiSTer streams these through the `hps_io` virtual-disk
  protocol with 4 VDs and a 16 KB sector cache in `cd_stream.sv`. The APF
  equivalent is `target_dataslot_read` with `target_dataslot_slotoffset`, which
  is a *core-initiated* pull — architecturally different and a substantial job.
* Save files (cart NVRAM, Memory Track, CD EEPROM) via `dataslot_requestwrite`
  / `data_unloader` and `"nonvolatile": true` slots.
* Cheat codes.
