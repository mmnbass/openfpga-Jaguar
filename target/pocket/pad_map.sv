// Pocket controller -> Jaguar joystick bits, with a full keypad.
//
// Pocket cont*_key: [0]up [1]down [2]left [3]right [4]A [5]B [6]X [7]Y
//                   [8]L1 [9]R1 [10]L2 [11]R2 [12]L3 [13]R3 [14]select [15]start
// Jaguar bits (jaguar.v:804-824): [0]right [1]left [2]down [3]up [4]A [5]B
//   [6]C [7]Option [8]Pause [9..17] keypad 1-9 [18] keypad 0 [19]* [20]#
//
// Normal play: A=A, B=B, Y=C, Start=Pause; X, L and R = the keypad keys
// chosen in Core Settings (default 0, * and #; X may be none), Select=Option.
//
// Keypad layer (Keypad Modifier = Select): while Select is held the buttons
// become the keypad, laid out like the Jaguar's own pad:
//       Y=1   Up=2    X=3
//    Left=4   Start=5 Right=6
//       B=7   Down=8  A=9
//       L=*           R=#      L+R together = 0
// and their normal functions are suppressed. X without Select sends the key
// chosen in Core Settings (default keypad 0, or none), so 0 is also in the
// layer as L+R, and every key stays reachable whatever X is set to. Option is then sent when
// Select is released without any other button having been pressed during
// the hold, and held for about 80 ms (2^23 clk) so the game's per-frame poll
// sees it. With Keypad Modifier = Off, Select is a plain, instant Option.

`default_nettype none

module pad_map (
    input  wire        clk,
    input  wire [15:0] k,              // synchronised cont*_key
    input  wire [3:0]  l_key,          // L button: 0 *, 1 #, 2 '0', 3..11 '1'..'9'
    input  wire [3:0]  r_key,
    input  wire [3:0]  x_key,          // X button: same encoding, 12 = none
    input  wire        shift_en,       // 1: Select is the keypad modifier
    output reg  [31:0] jag = 32'd0
);
    // Jaguar bit for a menu keypad index
    function [4:0] kp_bit(input [3:0] v);
        case (v)
            4'd0:    kp_bit = 5'd19;          // *
            4'd1:    kp_bit = 5'd20;          // #
            4'd2:    kp_bit = 5'd18;          // 0
            default: kp_bit = 5'd9 + (v - 4'd3);   // 1..9 -> bits 9..17
        endcase
    endfunction

    wire sel = k[14];
    reg  sel_d = 1'b0, chord = 1'b0;
    reg  [15:0] k_d = 16'd0;
    reg  [22:0] opt_t = 23'd0;               // Option pulse after a bare Select
    // a button newly pressed while Select is held means the keypad was used
    wire [15:0] newp = k & ~k_d;
    wire pressed = |{newp[13:0], newp[15]};

    reg  [31:0] j;
    always @(*) begin
        j = 32'd0;
        if (shift_en && sel) begin
            // keypad layer
            j[9]  = k[7];   j[10] = k[0];  j[11] = k[6];     // 1 2 3
            j[12] = k[2];   j[13] = k[15]; j[14] = k[3];     // 4 5 6
            j[15] = k[5];   j[16] = k[1];  j[17] = k[4];     // 7 8 9
            if (k[8] && k[9]) j[18] = 1'b1;                  // L+R = 0
            else begin j[19] = k[8]; j[20] = k[9]; end       // *   #
            j[19] = j[19] | k[10];  j[20] = j[20] | k[11];   // docked L2/R2
        end else begin
            j[0] = k[3];  j[1] = k[2];  j[2] = k[1];  j[3] = k[0];
            j[4] = k[4];  j[5] = k[5];  j[6] = k[7];
            j[8] = k[15];
            if (x_key != 4'd12) j[kp_bit(x_key)] = j[kp_bit(x_key)] | k[6];   // X
            j[kp_bit(l_key)] = j[kp_bit(l_key)] | k[8];
            j[kp_bit(r_key)] = j[kp_bit(r_key)] | k[9];
            j[19] = j[19] | k[10];  j[20] = j[20] | k[11];   // docked L2/R2 = * #
            j[7]  = shift_en ? 1'b0 : sel;                   // instant Option when no layer
        end
        if (opt_t != 23'd0) j[7] = 1'b1;
    end

always @(posedge clk) begin
    sel_d <= sel;
    k_d   <= k;
    if (sel && !sel_d)        chord <= 1'b0;                  // new hold
    else if (sel && pressed)  chord <= 1'b1;
    if (shift_en && !sel && sel_d && !chord) opt_t <= 23'h7FFFFF;
    else if (opt_t != 23'd0) opt_t <= opt_t - 1'b1;
    jag <= j;
end

endmodule

`default_nettype wire
