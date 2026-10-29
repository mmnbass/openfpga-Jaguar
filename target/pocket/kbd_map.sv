// Dock USB keyboard -> Jaguar joystick bits (player 1, OR-ed with pad_map).
//
// The Dock reports a keyboard on controller slot 3 (Analogue bus docs):
//   cont3_key[31:28] = 4 (keyboard)
//   cont3_joy[31:0]  = HID scan codes 1-4, one per byte
//   cont3_trig[15:0] = HID scan codes 5-6
// Codes are USB HID usage IDs in no particular order; 0 = empty slot.
// Up to six keys at once, so the whole keypad can be held together.
//
// Layout (MiSTer Jaguar.sv keyboard_joystick, plus the number row):
//   number row 1-9 0     -> keypad 1-9 0       - -> *     = -> #
//   numpad     1-9 0     -> keypad 1-9 0       * -> *     + -> #
//   arrows -> D-pad   Z X C -> A B C   Tab -> Option   Enter / numpad Enter -> Pause
// Numpad usages do not depend on NumLock: the keyboard sends the same codes
// either way and only the host interprets the lock.
//
// Rollover: a keyboard that cannot tell which keys are down fills every slot
// with ErrorRollOver (0x01). That report is ignored and the last good state
// held, so a seventh key does not drop the six already held.
//
// The inputs cross from clk_74a through a plain 2-FF sync in core_top, so a
// multi-byte update can be seen half-written for a cycle. A report is only
// taken once it has been identical for two clk cycles. Disconnecting (type no
// longer 4) clears the output at once.

`default_nettype none

module kbd_map (
    input  wire        clk,
    input  wire [3:0]  type_in,        // synchronised cont3_key[31:28]
    input  wire [31:0] codes_hi,       // synchronised cont3_joy
    input  wire [15:0] codes_lo,       // synchronised cont3_trig
    output reg  [31:0] jag = 32'd0
);
    // Jaguar bit set by one HID usage
    function [31:0] key_bits(input [7:0] u);
        key_bits = 32'd0;
        case (u)
            8'h4F: key_bits[0]  = 1'b1;               // Right
            8'h50: key_bits[1]  = 1'b1;               // Left
            8'h51: key_bits[2]  = 1'b1;               // Down
            8'h52: key_bits[3]  = 1'b1;               // Up
            8'h1D: key_bits[4]  = 1'b1;               // Z -> A
            8'h1B: key_bits[5]  = 1'b1;               // X -> B
            8'h06: key_bits[6]  = 1'b1;               // C -> C
            8'h2B: key_bits[7]  = 1'b1;               // Tab -> Option
            8'h28, 8'h58: key_bits[8] = 1'b1;         // Enter, numpad Enter -> Pause
            8'h27, 8'h62: key_bits[18] = 1'b1;        // 0, numpad 0
            8'h2D, 8'h55: key_bits[19] = 1'b1;        // -, numpad * -> *
            8'h2E, 8'h57: key_bits[20] = 1'b1;        // =, numpad + -> #
            default:
                if (u >= 8'h1E && u <= 8'h26)         // number row 1-9
                    key_bits[5'd9 + u[4:0] - 5'h1E] = 1'b1;
                else if (u >= 8'h59 && u <= 8'h61)    // numpad 1-9
                    key_bits[5'd9 + u[4:0] - 5'h19] = 1'b1;
        endcase
    endfunction

    wire [47:0] rpt = {codes_hi, codes_lo};
    reg  [47:0] rpt_d = 48'd0;
    wire        is_kbd = (type_in == 4'd4);

    reg [31:0] dec;
    reg        rollover;
    integer    i;
    always @(*) begin
        dec = 32'd0;
        rollover = 1'b0;
        for (i = 0; i < 6; i = i + 1) begin
            dec = dec | key_bits(rpt[i*8 +: 8]);
            if (rpt[i*8 +: 8] == 8'h01) rollover = 1'b1;
        end
    end

always @(posedge clk) begin
    rpt_d <= rpt;
    if (!is_kbd)                           jag <= 32'd0;
    else if (rpt == rpt_d && !rollover)    jag <= dec;
end

endmodule

// Player 1 = pad_map | kbd_map, with opposite directions cancelled.
// A Jaguar d-pad cannot report Left+Right or Up+Down, and games are not written
// for it: Rayman crashes on pad Left + keyboard Right (hardware, 2026-10-28).
// Either source can produce it (keyboard arrows, or one on each device), so
// it is cleaned after the merge: both of a pair pressed = neither. The
// buttons and keypad pass through unchanged.
module joy_merge (
    input  wire [31:0] pad,
    input  wire [31:0] kbd,
    output wire [31:0] jag
);
    wire [31:0] m = pad | kbd;
    wire lr = m[0] & m[1];                    // Right + Left
    wire ud = m[2] & m[3];                    // Down + Up
    assign jag = m & ~{28'd0, ud, ud, lr, lr};
endmodule

`default_nettype wire
