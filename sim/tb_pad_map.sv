// Unit test for target/pocket/pad_map.sv.
`timescale 1ns/1ps
module tb_pad_map;
    reg clk = 0; always #5 clk = ~clk;
    reg [15:0] k = 0; reg [3:0] lk = 0, rk = 1, xk = 2; reg sh = 1;
    wire [31:0] j;
    pad_map dut (.clk(clk), .k(k), .l_key(lk), .r_key(rk), .x_key(xk), .shift_en(sh), .jag(j));
    int fails = 0;
    task automatic chk(input string what, input bit cond);
        if (!cond) begin fails++; $display("FAIL: %s  (jag=%08x)", what, j); end
    endtask
    task automatic tick(int n = 2); repeat (n) @(posedge clk); #1; endtask
    initial begin
        tick();
        k = 16'h0010; tick(); chk("A -> A",           j[4] && !j[7]);
        k = 16'h0040; tick(); chk("X -> keypad 0",    j[18]);
        k = 16'h0100; tick(); chk("L -> * (default)", j[19]);
        k = 16'h0200; tick(); chk("R -> # (default)", j[20]);
        rk = 4'd11; k = 16'h0200; tick(); chk("R -> 9 when set", j[17] && !j[20]);
        lk = 4'd6;  k = 16'h0100; tick(); chk("L -> 4 when set", j[12]);
        lk = 0; rk = 1; k = 0; tick();
        // Select held: layer. Select+Left = 4, no D-pad left, no Option.
        k = 16'h4000; tick(); chk("Select alone: no Option yet", !j[7]);
        k = 16'h4004; tick(); chk("Select+Left -> 4", j[12] && !j[1] && !j[7]);
        k = 16'h4000; tick(); k = 0; tick(4); chk("chorded release: no Option", !j[7]);
        // bare Select tap: Option pulse
        k = 16'h4000; tick(); k = 0; tick(); chk("bare Select -> Option", j[7]);
        tick(100); chk("Option still held shortly after", j[7]);
        // walking right, tap Select bare: still Option (held button does not count)
        k = 16'h0008; tick(); k = 16'h4008; tick(); k = 16'h0008; tick(); chk("Select tap while walking -> Option", j[7] && j[0]);
        // layer corners
        k = 16'h4080; tick(); chk("Select+Y -> 1", j[9]);
        k = 16'h4040; tick(); chk("Select+X -> 3", j[11] && !j[18]);
        k = 16'h4020; tick(); chk("Select+B -> 7", j[15] && !j[5]);
        k = 16'h4010; tick(); chk("Select+A -> 9", j[17] && !j[4]);
        k = 16'hC000; tick(); chk("Select+Start -> 5, no Pause", j[13] && !j[8]);
        k = 16'h4300; tick(); chk("Select+L+R -> 0, no * #", j[18] && !j[19] && !j[20]);
        k = 0; tick(); xk = 4'd12; k = 16'h0040; tick(); chk("X set to none -> nothing", (j & ~32'h80) == 32'd0);   // bit 7: an earlier Option pulse may still be running
        xk = 4'd5; tick(); chk("X set to 3 -> keypad 3", j[11]);
        xk = 4'd2; k = 0; tick(8);
        // modifier off: Select is an instant Option
        sh = 0; k = 0; tick(); k = 16'h4000; tick(); chk("modifier off: instant Option", j[7]);
        k = 16'h4004; tick(); chk("modifier off: Select+Left still moves", j[1] && !j[12]);
        if (fails == 0) $display("PAD MAP: PASS");
        else            $display("PAD MAP: %0d FAILURES", fails);
        $finish;
    end
endmodule
