// Unit test for target/pocket/kbd_map.sv, merged with pad_map by joy_merge as in core_top.
`timescale 1ns/1ps
module tb_kbd_map;
    reg clk = 0; always #5 clk = ~clk;
    reg [3:0]  ty = 0;
    reg [47:0] c  = 0;                 // six HID slots, slot 1 in [47:40]
    reg [15:0] k  = 0;                 // Pocket buttons into pad_map
    wire [31:0] jk, jp, j;
    kbd_map dut (.clk(clk), .type_in(ty), .codes_hi(c[47:16]), .codes_lo(c[15:0]), .jag(jk));
    joy_merge mrg (.pad(jp), .kbd(jk), .jag(j));
    pad_map pad (.clk(clk), .k(k), .l_key(4'd0), .r_key(4'd1), .x_key(4'd2), .shift_en(1'b1), .jag(jp));

    // Jaguar bits
    localparam R=0, L=1, D=2, U=3, A=4, B=5, C=6, OPT=7, PAU=8, K0=18, STAR=19, HASH=20;
    function int kp(int n); return n == 0 ? K0 : 8 + n; endfunction   // keypad digit -> bit
    function [31:0] bits(int b0, int b1 = -1, int b2 = -1, int b3 = -1, int b4 = -1, int b5 = -1);
        bits = 32'd0;
        if (b0 >= 0) bits[b0] = 1; if (b1 >= 0) bits[b1] = 1; if (b2 >= 0) bits[b2] = 1;
        if (b3 >= 0) bits[b3] = 1; if (b4 >= 0) bits[b4] = 1; if (b5 >= 0) bits[b5] = 1;
    endfunction
    // HID usages
    function [7:0] row(int n);  return n == 0 ? 8'h27 : 8'h1D + n; endfunction
    function [7:0] npad(int n); return n == 0 ? 8'h62 : 8'h58 + n; endfunction

    int fails = 0;
    // the console must never see both directions of a pair, on any cycle
    int opp = 0;
    always @(posedge clk) if ((j[R] & j[L]) | (j[U] & j[D])) opp++;
    task automatic chk(input string what, input [31:0] got, input [31:0] want);
        if (got !== want) begin fails++; $display("FAIL: %s  got=%08x want=%08x", what, got, want); end
    endtask
    task automatic tick(int n = 4); repeat (n) @(posedge clk); #1; endtask
    task automatic send(input [7:0] s1, s2 = 0, s3 = 0, s4 = 0, s5 = 0, s6 = 0);
        c = {s1, s2, s3, s4, s5, s6}; tick();
    endtask

    initial begin
        tick();
        chk("nothing connected", j, 0);
        ty = 4;
        send(0); chk("keyboard, no keys", j, 0);

        // every keypad key, number row and numpad, one at a time
        for (int n = 0; n <= 9; n++) begin
            send(row(n));  chk($sformatf("row %0d", n),    j, bits(kp(n)));
            send(npad(n)); chk($sformatf("numpad %0d", n), j, bits(kp(n)));
        end
        send(8'h2D); chk("- -> *", j, bits(STAR));
        send(8'h55); chk("numpad * -> *", j, bits(STAR));
        send(8'h2E); chk("= -> #", j, bits(HASH));
        send(8'h57); chk("numpad + -> #", j, bits(HASH));

        // simultaneous keypad presses: all six slots, every slot position used
        send(row(1), row(2), row(3), row(4), row(5), row(6));
        chk("six row keys at once", j, bits(kp(1), kp(2), kp(3), kp(4), kp(5), kp(6)));
        send(npad(7), npad(8), npad(9), npad(0), 8'h55, 8'h57);
        chk("six numpad keys at once (7 8 9 0 * #)", j, bits(kp(7), kp(8), kp(9), K0, STAR, HASH));
        send(row(1), npad(2), row(3), npad(4), 8'h2D, 8'h57);
        chk("row and numpad mixed", j, bits(kp(1), kp(2), kp(3), kp(4), STAR, HASH));
        send(row(5), npad(5)); chk("same digit on row and numpad", j, bits(kp(5)));
        send(8'h00, 8'h00, 8'h00, 8'h00, 8'h00, npad(9)); chk("key in slot 6 only", j, bits(kp(9)));
        send(8'h00, 8'h00, 8'h00, row(3)); chk("key in slot 4 only (joy/trig split)", j, bits(kp(3)));
        // releasing one key of a held chord keeps the rest
        send(row(1), row(2), row(3)); send(row(1), row(3));
        chk("release 2 of 1+2+3", j, bits(kp(1), kp(3)));
        send(0); chk("all released", j, 0);

        // joystick keys and keypad together
        send(8'h52, 8'h4F, 8'h1D, row(8));
        chk("Up+Right+Z+8", j, bits(U, R, A, kp(8)));
        send(8'h50, 8'h51, 8'h1B, 8'h06); chk("Left+Down+X+C", j, bits(L, D, B, C));
        send(8'h2B); chk("Tab -> Option", j, bits(OPT));
        send(8'h28); chk("Enter -> Pause", j, bits(PAU));
        send(8'h58); chk("numpad Enter -> Pause", j, bits(PAU));
        send(8'h04, 8'h3A, 8'hE1); chk("unmapped keys (a, F1, LShift) ignored", j, 0);

        // rollover: ErrorRollOver holds the last good state
        send(row(1), row(2), row(3), row(4), row(5), row(6));
        send(8'h01, 8'h01, 8'h01, 8'h01, 8'h01, 8'h01);
        chk("ErrorRollOver holds the chord", j, bits(kp(1), kp(2), kp(3), kp(4), kp(5), kp(6)));
        send(row(1)); chk("after rollover, next report taken", j, bits(kp(1)));

        // a report seen for one cycle only (half-written across clocks) is not taken
        send(row(2));
        begin
            bit seen = 0;
            c = {row(9), 40'd0}; @(posedge clk); #1; c = {row(2), 40'd0};
            repeat (6) begin if (j[kp(9)]) seen = 1; @(posedge clk); #1; end
            chk("one-cycle glitch never reaches the output", {31'd0, seen}, 0);
            chk("state after glitch", j, bits(kp(2)));
        end
        send(0);

        // keyboard + Pocket gamepad
        k = 16'h0010; send(row(1), row(2));
        chk("pad A + kbd 1 2", j, bits(A, kp(1), kp(2)));
        k = 16'h0009; send(8'h1B);
        chk("pad Up+Right + kbd X(B)", j, bits(U, R, B));
        k = 16'h0002; send(8'h52, 8'h1D); chk("pad Down + kbd Up cancel, kbd Z still A", j, bits(A));
        k = 16'h4080; send(row(9));              // Select held: pad keypad layer, Y = 1
        chk("pad layer 1 + kbd 9", j, bits(kp(1), kp(9)));
        k = 16'h0000; tick(); send(0);
        tick(1 << 23);                           // let the chorded-Select Option window pass
        chk("pad and keyboard released", j, 0);
        k = 16'h0100; send(row(4)); chk("pad L(*) + kbd 4", j, bits(STAR, kp(4)));
        k = 0; send(0);

        // opposite directions: both of a pair pressed = neither, from any source
        // (Pocket k: [0]up [1]down [2]left [3]right [4]A)
        send(8'h50, 8'h4F); chk("kbd Left+Right", j, 0);
        send(8'h52, 8'h51); chk("kbd Up+Down", j, 0);
        send(8'h50, 8'h4F, 8'h52); chk("kbd Left+Right+Up -> Up", j, bits(U));
        send(8'h50, 8'h4F, 8'h52, 8'h51); chk("kbd all four arrows", j, 0);
        send(8'h50, 8'h4F, 8'h1D, row(5), 8'h28);
        chk("kbd Left+Right with Z, 5, Enter: buttons kept", j, bits(A, kp(5), PAU));
        send(0);
        k = 16'h000C; tick(); chk("pad Left+Right (Dock pad)", j, 0);
        k = 16'h0003; tick(); chk("pad Up+Down (Dock pad)", j, 0);
        k = 16'h001D; tick(); chk("pad Up+Left+Right+A -> Up+A", j, bits(U, A));
        k = 0; tick();
        k = 16'h0004; send(8'h4F); chk("pad Left + kbd Right (the Rayman crash)", j, 0);
        send(0);          chk("  release kbd Right: pad Left remains", j, bits(L));
        send(8'h4F);      chk("  press kbd Right again", j, 0);
        k = 0; tick();    chk("  release pad Left: kbd Right remains", j, bits(R));
        send(0);          chk("  all released", j, 0);
        k = 16'h0001; send(8'h51); chk("pad Up + kbd Down", j, 0);
        k = 0; tick();    chk("  release pad Up: kbd Down remains", j, bits(D));
        send(0);
        k = 16'h0004; send(8'h50); chk("pad Left + kbd Left: still Left", j, bits(L));
        k = 16'h0008; send(8'h52); chk("pad Right + kbd Up: diagonal kept", j, bits(R, U));
        k = 16'h0010; send(8'h50, 8'h52); chk("pad A + kbd Left+Up: move and jump", j, bits(A, L, U));
        k = 0; send(0);
        // rapid direction changes, one or two cycles apart, from both sources
        for (int n = 0; n < 64; n++) begin
            k = (n % 3 == 0) ? 16'h0004 : (n % 3 == 1) ? 16'h0008 : 16'h000C;
            c = {((n % 4) < 2) ? 8'h4F : 8'h50, ((n % 5) == 0) ? 8'h52 : 8'h51, 32'd0};
            repeat (1 + n % 2) @(posedge clk); #1;
        end
        k = 0; c = 0; tick(); chk("rapid changes, then release: nothing stuck", j, 0);

        // disconnect
        send(row(1), row(2), 8'h52);
        ty = 0; tick(); chk("unplug while keys held: cleared", j, 0);
        tick(20); chk("stays clear with stale codes", j, 0);
        k = 16'h0020; tick(); chk("pad still works after unplug", j, bits(B));
        k = 0;
        ty = 4; send(0); chk("replug, no keys", j, 0);
        send(row(7)); chk("replug, 7", j, bits(kp(7)));
        ty = 0; tick(); send(row(7), row(8)); chk("codes change while unplugged: ignored", j, 0);
        // slot 3 holding a docked gamepad: its stick bytes must not read as keys
        ty = 3; c = {8'h1E, 8'h52, 8'h4F, 8'h27, 8'h55, 8'h57}; tick();
        chk("analog gamepad on slot 3 not decoded", j, 0);
        ty = 2; tick(); chk("digital gamepad on slot 3 not decoded", j, 0);
        ty = 5; tick(); chk("mouse on slot 3 not decoded", j, 0);

        chk("opposite pair never reached the console", opp, 0);

        if (fails == 0) $display("KBD MAP: PASS");
        else            $display("KBD MAP: %0d FAILURES", fails);
        $finish;
    end
endmodule
