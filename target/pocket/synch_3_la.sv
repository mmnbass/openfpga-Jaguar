// synch_3 (platform/pocket/common.v) with its middle flop brought out: o_next is the value o takes on
// the next clock. POCKET_DRAMINIT uses it to register the SDRAM self-refresh request one clock early,
// so the registered value equals the synchronised signals on every clock (jaguar_top sr_ext).
module synch_3_la (
    input  wire i,        // asynchronous input
    output reg  o,        // synchronised, as synch_3's o
    output reg  o_next,   // synch_3's stage_2: o on the next clock
    input  wire clk
);
    reg stage_1;
always @(posedge clk)
    {o, o_next, stage_1} <= {o_next, stage_1, i};
endmodule
