# 7. Controller / input handling

## 7.1 The Jaguar controller

The Jaguar pad is a **3×… matrix-scanned** device: 3 face buttons (A/B/C),
Option, Pause, D-pad, plus a **12-key numeric keypad** (1-9, 0, `*`, `#`).
The Pro Controller adds shoulder buttons and more face buttons. Scanning is done
by Jerry through `jag_controller_mux.v`.

`jaguar.v` bit order (documented at `Jaguar.sv:207`):

```
joystick_N[31:0] =
  [31:21] unused
  [20: 9] keypad:  # * 0 9 8 7 6 5 4 3 2 1
  [    8] Pause
  [    7] Option
  [    6] C
  [    5] B
  [    4] A
  [ 3: 0] Up, Right, Left, Down
```

Core inputs (`jaguar.v:61-77`):

| Port | Purpose |
|---|---|
| `joystick_0..4` | 5 controllers (2 direct + Team-Tap expansion) |
| `analog_0..3` | unsigned 0-255, two axes × two players (analog/numstick) |
| `spinner_0/1`, `spinner_speed` | rotary controllers |
| `team_tap_port1/2` | enable the 4-port Team-Tap on port 1 or 2 |
| `lightgun_mode`, `lightgun_crosshair` | light gun (currently commented out of the MiSTer menu) |
| `ps2_mouse`, `mouse_ena_1/2` | Jaguar mouse |

## 7.2 MiSTer side (what we replace)

`hps_io` supplies `joystick_0..4[31:0]`, `joystick_l_analog_0..4`,
`joystick_r_analog_0..4`, `spinner_0/1`, `ps2_key`, `ps2_mouse`. The MiSTer
`CONF_STR` maps them:

```
"J1,A,B,C,Option,Pause,1,2,3,4,5,6,7,8,9,0,Star,Hash;"
"jn,Y,B,A,Select,Start;"
```

Plus, in `Jaguar.sv`:
* `keyboard_joystick` — a PS/2 keyboard mapped onto player 1 including the
  full keypad (`:858-887`). **The only way to reach the keypad without an
  overlay.**
* `numstick` (`rtl/numstick.sv`, 759 lines) — an on-screen keypad overlay
  driven by the analog sticks, composited into the video path. This is
  MiSTer's answer to "the Jaguar pad has 17 buttons and your gamepad has 8".
* `swap_p1p2`, Team-Tap routing, `p1p2pause_active` (a menu action that pulses
  Pause on both pads).

## 7.3 The Pocket problem

Pocket's built-in controls:

```
cont1_key[31:0]: dpad_up/down/left/right, face_a/b/x/y,
                 trig_l1/r1/l2/r2/l3/r3, face_select, face_start, [31:28] type
cont1_joy[31:0]: lstick_x/y, rstick_x/y   (unsigned)
cont1_trig[15:0]: ltrig, rtrig
```

Handheld: D-pad, A, B, X, Y, L, R, Start, Select — **9 usable buttons for a
17-button controller.** Dock adds `cont2..4` and analog sticks.

So input is not a plumbing problem, it is a **mapping design** problem, and it
is the one area where a straight port is genuinely impossible.

### Mapping plan

| Jaguar | Pocket handheld | Notes |
|---|---|---|
| D-pad | D-pad | direct |
| A | A (`cont1_key[4]`) | |
| B | B (`cont1_key[5]`) | |
| C | Y (`cont1_key[7]`) | X/Y choice is a taste call; expose via `interact.json` |
| Option | Select (`cont1_key[14]`) | |
| Pause | Start (`cont1_key[15]`) | |
| keypad 1-9, 0, `*`, `#` | **`numstick` overlay**, driven by the analog sticks on a docked controller; and/or an L/R-modifier scheme on the handheld | see below |

The `numstick` overlay is the right answer and it is **already written, is
self-contained, and does not depend on `hps_io`** — it takes `clk_sys`,
`ce_pix`, `hblank`, `vblank`, RGB in/out and the four analog axes, and returns
`keypad_press[11:0]`. It composites into the video stream, which on Pocket means
inserting it before our `jaguar_video` stage rather than before `video_mixer`.
Keep it.

For handheld-only play, add a modifier scheme: hold L → D-pad/face buttons
select keypad 1-9; hold R → `0`/`*`/`#`. Cheap in logic, configurable from
`interact.json`.

### `input.json`

Purely cosmetic — it tells the Pocket OS what to *call* each button in its
remapping UI. Model on the SNES port:

```json
{ "input": { "magic": "APF_VER_1", "controllers": [
  { "type": "default", "mappings": [
    { "id": 0,  "name": "A",       "key": "pad_btn_a" },
    { "id": 1,  "name": "B",       "key": "pad_btn_b" },
    { "id": 3,  "name": "C",       "key": "pad_btn_y" },
    { "id": 10, "name": "Keypad L","key": "pad_trig_l" },
    { "id": 11, "name": "Keypad R","key": "pad_trig_r" },
    { "id": 20, "name": "Pause",   "key": "pad_btn_start" },
    { "id": 21, "name": "Option",  "key": "pad_btn_select" }
  ]}
]}}
```

## 7.4 Clock domain

All `cont*_key/joy/trig` are synchronous to **`clk_74a`**. The core runs at
106.36 MHz. Resynchronise with a 2-flop sync per bit — button state has no
cross-bit coherency requirement, so no handshake is needed. (Keypad-via-overlay
state is generated inside `clk_sys` already.)

## 7.5 Dropped for now

| Feature | Pocket path | Milestone |
|---|---|---|
| Players 2-4 | dock, `cont2..4_key` | 6 |
| Team-Tap (up to 8 players) | dock supports 4 | 6, partial |
| Analog sticks / Pro Controller | `cont1_joy` | 6 |
| Spinners | map to analog stick deltas | 6, optional |
| Jaguar mouse | map to analog stick; `ps2_mouse.v` can be driven from a synthesised PS/2-format vector — its interface is just `ps2_mouse[24:0]`, not an actual PS/2 bus | 6, optional |
| Light gun | no Pocket analogue | drop |
| PS/2 keyboard | no Pocket analogue | drop (replaced by overlay + modifiers) |
| JagLink | Pocket link port `port_tran_*` | 7+, speculative |

## 7.6 Milestone 1-2 stance

Tie **all** input ports on `jaguar_inst` to constants. Input contributes
essentially nothing to the resource question, and leaving it out removes
`numstick` (759 lines plus a video path), `jag_team_tap`, `jag_lightgun`,
`ps2_mouse` and the keyboard decoder from the first fit — which is useful
precisely because it tells us the floor.
