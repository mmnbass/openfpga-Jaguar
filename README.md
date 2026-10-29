# Atari Jaguar for Analogue Pocket

An openFPGA core that runs **Atari Jaguar cartridge games** on the Analogue
Pocket, ported from [Jaguar_MiSTer](https://github.com/MiSTer-devel/Jaguar_MiSTer).

The Jaguar's custom chips, Tom and Jerry, are recreated in FPGA logic from
Atari's original chip netlists, rather than emulated in software.

## What works

* Cartridge games: tested titles boot and run (see Known limitations for
  audio).
* Saves: games that save to the cartridge EEPROM (Rayman's save slots, for
  example) persist between sessions.
* Full controller support, including the 12-key number pad (see Controls).
* **Dock USB keyboard** as player 1, alongside the gamepad, with the full
  number pad on the number row or numpad (see Dock USB keyboard).
* Dock output.

## Installation

1. Copy the `Cores`, `Platforms` and `Assets` folders from the release zip
   to the root of your Pocket's SD card.
2. **Supply the Jaguar boot ROM yourself.** It is copyrighted and not
   included. Place it at

       Assets/jaguar/common/jagboot.rom

   The core supports both the K and M BIOS revisions, as Jaguar_MiSTer does.
3. Put your cartridge images in `Assets/jaguar/common/` or a subfolder.
   Use **`.j64`** images (full cartridge dumps including the 8 KB header).
4. On the Pocket: openFPGA → Atari Jaguar → choose a game.

The Jaguar logo screen pauses for several seconds while the BIOS checks the
cartridge. That is normal.

## Controls

| Pocket | Jaguar |
|---|---|
| D-pad | D-pad |
| A / B / Y | A / B / C |
| Start | Pause |
| Select (tap) | Option |
| X | Keypad 0 (changeable) |
| L / R | Keypad * / # (changeable) |

**Number pad: hold Select.** While Select is held, the buttons become the
Jaguar keypad, laid out like the real one:

```
   Y = 1      Up = 2      X = 3
 Left = 4   Start = 5   Right = 6
   B = 7    Down = 8      A = 9
   L = *    L+R = 0       R = #
```

Tapping Select on its own (pressing nothing else) still sends Option.

### Dock USB keyboard

Plug a USB keyboard into the Analogue Dock. It controls **player 1**,
together with the player 1 gamepad: both work at the same time.

| Keyboard | Jaguar |
|---|---|
| Arrow keys | D-pad |
| Z / X / C | A / B / C |
| Enter (main or numpad) | Pause |
| Tab | Option |
| 0–9 (number row or numpad) | Keypad 0–9 |
| `-` or numpad `*` | Keypad * |
| `=` or numpad `+` | Keypad # |

* Up to six keys can be held at once, so keypad combinations work.
* Pressing opposite directions together (Left+Right or Up+Down) counts as
  neither, as on a real Jaguar d-pad, which can't press both. This applies to
  every player 1 input, keyboard and gamepad, and to one direction on each.
* The keyboard can be plugged in or unplugged during a game. Unplugging
  releases any keys it was holding. The Pocket can also leave and rejoin the
  Dock mid-game.
* The key layout is fixed. The L, R and X Core Settings apply to the gamepad
  only.

### Core Settings

| Setting | Choices | Default |
|---|---|---|
| L Button | Keypad *, #, 0–9 | * |
| R Button | Keypad *, #, 0–9 | # |
| X Button | Keypad *, #, 0–9, None | 0 |
| Keypad Modifier | Select (hold), Off | Select |

Examples: in **Doom**, set L = 4 and R = 6 to cycle weapons with the
shoulder buttons. In **Alien vs Predator**, set R = 9 for one-press motion
tracker. Setting X to None stops Rayman's music toggle (keypad 0) being
pressed by accident. Keypad Modifier = Off makes Select a plain, instant
Option button. Remapped buttons still work through the Select layer as well.

## Compatibility

Tested on hardware:

* Alien vs Predator
* Atari Karts
* Cannon Fodder
* Cybermorph
* Doom, and Doom II (unofficial 2011 port)
* Iron Soldier
* Missile Command 3D
* NBA Jam Tournament Edition
* Raiden
* Rayman (saves work)
* Tempest 2000
* Wolfenstein 3D
* Zool 2

More compatibility reports are very welcome!

## Known limitations

* **Cartridge only.** No Jaguar CD (it does not fit alongside the console in
  the Pocket's FPGA).
* **No save states, Memories or sleep.** Not yet supported.
* **Memory bandwidth.** The Jaguar reads memory 64 bits at a time; the Pocket
  has a single 16-bit SDRAM, the setup MiSTer documents as the hardest case.
  A self-tuning cache follows each game's busiest memory and removes the
  slowdowns seen in testing, but a scene that hammers an unusually large
  amount of memory could still slow briefly.
* The boot ROM must be supplied by the user.
* **Audio issues are still under investigation**, including Atari Karts
  playing without music. Keyboard support does not change the audio.
* **Dock keyboard:** one keyboard, as player 1 only. Tested with one keyboard
  and one gamepad on the Dock; setups with more controllers are untested.
* **Headerless `.rom` dumps** (8 KB shorter than the cartridge, missing its
  header) are not supported yet. Use the `.j64` version of the game.

## Credits

* **Torlus (Gregory Estrade)**: the original Jaguar FPGA core, Tom and Jerry
  converted from Atari's netlists.
* **ElectronAsh, Kitrinx, GreyRogue**: the MiSTer port, Jaguar_MiSTer.
* **Sorgelig**: the MiSTer framework and SDRAM controller.
* **Nuked (nukeykt)**: the 68000 model.
* **agg23 (Adam Gastineau)**: openFPGA support modules (data loading,
  saves, audio).
* **Spiritualized1997**: the Atari Jaguar platform artwork, from the
  Spiritualized1997 openFPGA Platform Pack.
* Pocket port: **mmnbass (Michael Merida-Nicolich)**.

## License

GPL-2.0-or-later, inherited from Jaguar_MiSTer (see [LICENSE](LICENSE)).
Pocket modules by agg23 are MIT. Analogue's openFPGA framework files are
used under Analogue's license. The Jaguar BIOS and games are not included.

Atari and Jaguar are trademarks of their respective owners. This project is
not affiliated with or endorsed by Atari.

## For developers

Design notes are in [docs/](docs/).
Builds run on GitHub Actions (`.github/workflows/m2-fit.yml`, Quartus 21.1);
the fitter seed is a workflow input (release v0.1.3 used seed 10).
simulation runs locally with Verilator (`sim/run-all.sh`, `sim/run-boot-tb.sh`).

Build switches (Verilog macros), all off by default:

| Macro | Effect |
|---|---|
| `POCKET_DIAG` | On-screen diagnostic overlay (status squares, memory-traffic bars) |
| `POCKET_FIXED_CACHE` | Upstream's fixed-region caches instead of the self-tuning cache |
| `POCKET_SRAM_CACHE` | Experimental external-SRAM cache (shelved: glitches on hardware) |
| `POCKET_STALL_ONTIME` | Experimental shorter memory stall (fails on hardware) |
| `POCKET_NO_CART_WAIT` | Upstream's cartridge-read timing |
