// Self-selecting block cache for Tom's DRAM reads.
//
// Replaces upstream's FAST_SDRAM fixed-region caches (two 256 KB regions
// chosen by an OSD/menu setting). The same BRAM -- the upper 32 bits of
// 64 Ki DRAM words -- is split into 8 slots of one 64 KB DRAM block each,
// and the slots follow the game's hot blocks by themselves:
//
//   * every Tom read counts against its 64 KB block (32 blocks);
//   * at the end of each window (2^23 clk = 79 ms) the hottest block that has
//     no slot is compared with the coldest slotted block; if it is at least
//     twice as hot (and not trivially cold), that slot is reassigned: its
//     valid bits are swept to 0 (8 Ki clk), then it serves the new block;
//   * a slot fills from Tom's own reads: a read of a not-yet-valid word
//     stalls as upstream does, and when SDRAM delivers the full word its
//     upper half is written into the slot and marked valid. No extra SDRAM
//     traffic is ever generated;
//   * every Tom write to a slotted block is written through (byte enables);
//     a write of all four upper bytes also marks the word valid.
//
// Hit (Tom not stalled, upper half from BRAM) = the block has an active slot
// and the word's valid bit is set -- a registered decision made from the
// registered sdram_addr, in the same shape as upstream's
// ram_rdy = ~ch1_req || use_fastram. By design, no raw Tom strobe reaches any
// state here except through one input register.
//
// Timing (E0 = the edge sampling dram_go_rd, when cas_latch takes the column):
// lookup address from sdram_addr after E0, BRAM q and valid at E2, hit
// registered at E3, CAS at E5, Tom consumes at E8. The lower half
// still comes from SDRAM at E6, exactly as with upstream's caches.

`default_nettype none

module blkcache (
    input  wire        clk,
    input  wire        rst,            // console reset: forget all slots

    input  wire [17:0] sdram_addr,     // {ras_latch, cas_latch}: 64-bit word address
    input  wire        rd_cas,         // ch1_req (raw): a read's CAS edge
    input  wire        wr_go,          // old_ch1_reqw (a register): write-through cycle
    input  wire [31:0] wr_data,        // ch1_din[63:32]
    input  wire [3:0]  wr_be,          // ch1_be[7:4], active high
    input  wire        rd_done,        // sdram: a ch1 read's full word just latched
    input  wire [31:0] rd_data,        // ch1_dout[63:32]

    output reg         hit,            // registered; valid from E3 to the next read
    output wire [31:0] q,              // cached upper half

    output wire [31:0] cached_blocks,  // diag: one bit per 64 KB block
    output reg  [7:0]  n_reassign      // diag: slot reassignments (saturating)
);
    initial begin hit = 1'b0; n_reassign = 8'd0; end

    // ---- slot table ---------------------------------------------------------
    reg  [4:0] slot_blk [0:7];
    reg  [7:0] slot_act = 8'd0;          // slot serves slot_blk
    integer    i;
    initial for (i = 0; i < 8; i = i + 1) slot_blk[i] = i[4:0];

    wire [4:0] blk  = sdram_addr[17:13];
    wire [12:0] wrd = sdram_addr[12:0];
    reg  [2:0] sidx;
    reg        sfound;
    always @(*) begin
        sidx = 3'd0; sfound = 1'b0;
        for (i = 0; i < 8; i = i + 1)
            if (slot_act[i] && slot_blk[i] == blk) begin sidx = i[2:0]; sfound = 1'b1; end
    end
    genvar g;
    generate for (g = 0; g < 32; g = g + 1) begin : cb
        assign cached_blocks[g] = (slot_act[0] && slot_blk[0] == g) || (slot_act[1] && slot_blk[1] == g) ||
                                  (slot_act[2] && slot_blk[2] == g) || (slot_act[3] && slot_blk[3] == g) ||
                                  (slot_act[4] && slot_blk[4] == g) || (slot_act[5] && slot_blk[5] == g) ||
                                  (slot_act[6] && slot_blk[6] == g) || (slot_act[7] && slot_blk[7] == g);
    end endgenerate

    // ---- memories: data 64 Ki x 32 (4 x 8-bit lanes), valid 64 Ki x 1 -------
    // Port A: lookup reads. Port B: all writes (write-through, fill, sweep).
    wire [15:0] la = {sidx, wrd};
    reg  [15:0] wb_addr;
    reg  [31:0] wb_data;
    reg  [3:0]  wb_be;
    reg         wb_vwr, wb_vbit;
    wire        v_q;
    generate for (g = 0; g < 4; g = g + 1) begin : lane
        dpram #(.addr_width(16), .data_width(8)) d (
            .clock     ( clk ),
            .address_a ( la ),
            .data_a    ( 8'd0 ),
            .wren_a    ( 1'b0 ),
            .q_a       ( q[8*g +: 8] ),
            .address_b ( wb_addr ),
            .data_b    ( wb_data[8*g +: 8] ),
            .wren_b    ( wb_be[g] ),
            .q_b       ( )
        );
    end endgenerate
    dpram #(.addr_width(16), .data_width(1)) vram (
        .clock     ( clk ),
        .address_a ( la ),
        .data_a    ( 1'b0 ),
        .wren_a    ( 1'b0 ),
        .q_a       ( v_q ),
        .address_b ( wb_addr ),
        .data_b    ( wb_vbit ),
        .wren_b    ( wb_vwr ),
        .q_b       ( )
    );

    // ---- input registers ----------------------------------------------
    // rd_cas is Tom's raw CAS strobe and is registered here. wr_go
    // (old_ch1_reqw) and rd_done are registers already, so the write-through
    // and fill use them directly -- one stage less on the write path, which
    // narrows the write-then-read window guarded below.
    reg        cas_r = 1'b0, done_r = 1'b0;
    reg [31:0] rd_data_r = 32'd0;
    always @(posedge clk) begin
        cas_r  <= rd_cas;
        done_r <= rd_done;  rd_data_r <= rd_data;
    end
    // A write-through reaches the RAM 2 clk after wr_go. Until it has, a
    // lookup of that word could return the old upper half marked valid, so
    // a hit on an address with a write in flight is refused (Tom stalls).
    reg [17:0] wf_addr0 = 18'd0, wf_addr1 = 18'd0;
    reg        wf0 = 1'b0, wf1 = 1'b0;
    always @(posedge clk) begin
        wf0 <= wr_go;  wf_addr0 <= sdram_addr;
        wf1 <= wf0;    wf_addr1 <= wf_addr0;
    end
    wire wr_inflight = (wr_go && 1'b1) || (wf0 && wf_addr0 == sdram_addr) || (wf1 && wf_addr1 == sdram_addr);

    // ---- hit: registered from the registered lookup --------------------------
    // la follows sdram_addr; q/v_q are the RAM outputs one clock later. sfound
    // is delayed to match.
    reg sfound_d = 1'b0;
    reg [17:0] addr_d = 18'd0;
    always @(posedge clk) begin
        sfound_d <= sfound;
        addr_d   <= sdram_addr;
        // valid only if the address the RAM looked up is still the current one
        hit <= sfound_d && v_q && (addr_d == sdram_addr) && !wr_inflight && !rst;
    end

    // ---- fill on miss ---------------------------------------------------------
    reg        fill_pend = 1'b0;
    reg [15:0] fill_addr = 16'd0;
    reg [4:0]  fill_blk = 5'd0;

    // ---- heat counters and reassignment --------------------------------------
    reg  [15:0] heat [0:31];
    initial for (i = 0; i < 32; i = i + 1) heat[i] = 16'd0;
    reg  [22:0] win = 23'd0;
    reg  [5:0]  scan = 6'd63;           // 0..31 scanning blocks, 32..39 scanning slots, 63 idle
    reg  [15:0] hot_v, cold_v;
    reg  [4:0]  hot_b;
    reg  [2:0]  cold_s;
    reg         hot_ok;
    reg  [4:0]  req_blk = 5'd0;
    reg         sweeping = 1'b0;
    reg  [2:0]  sw_slot = 3'd0;
    reg  [12:0] sw_idx = 13'd0;
    reg  [4:0]  sw_newblk = 5'd0;

    function in_any_slot(input [4:0] b);
        integer k;
        begin
            in_any_slot = 1'b0;
            for (k = 0; k < 8; k = k + 1)
                if ((slot_act[k] || (sweeping && sw_slot == k)) && slot_blk[k] == b) in_any_slot = 1'b1;
        end
    endfunction

always @(posedge clk) begin
    wb_be <= 4'd0; wb_vwr <= 1'b0;

    // count reads per block (registered CAS, registered address)
    if (cas_r && ~&heat[addr_d[17:13]]) heat[addr_d[17:13]] <= heat[addr_d[17:13]] + 1'b1;

    // a read that missed in a slotted block: fill it when SDRAM delivers
    if (cas_r && sfound_d && !hit) begin
        fill_pend <= 1'b1;
        fill_addr <= {sidx, addr_d[12:0]};
        fill_blk  <= addr_d[17:13];
    end

    // port B, in priority order: write-through, fill, sweep
    if (wr_go && sfound) begin
        wb_addr <= {sidx, sdram_addr[12:0]};
        wb_data <= wr_data;
        wb_be   <= wr_be;
        if (&wr_be) begin wb_vwr <= 1'b1; wb_vbit <= 1'b1; end
        if (fill_pend && fill_addr == {sidx, sdram_addr[12:0]}) fill_pend <= 1'b0;   // superseded
    end else if (fill_pend && done_r) begin
        fill_pend <= 1'b0;
        // only if the slot still serves that block
        if (slot_act[fill_addr[15:13]] && slot_blk[fill_addr[15:13]] == fill_blk) begin
            wb_addr <= fill_addr;
            wb_data <= rd_data_r;
            wb_be   <= 4'hF;
            wb_vwr  <= 1'b1; wb_vbit <= 1'b1;
        end
    end else if (sweeping) begin
        wb_addr <= {sw_slot, sw_idx};
        wb_vwr  <= 1'b1; wb_vbit <= 1'b0;
        sw_idx  <= sw_idx + 1'b1;
        if (&sw_idx) begin
            sweeping <= 1'b0;
            slot_blk[sw_slot] <= sw_newblk;
            slot_act[sw_slot] <= 1'b1;
            if (~&n_reassign) n_reassign <= n_reassign + 1'b1;
        end
    end

    // window: scan blocks for the hottest unslotted one, then slots for the
    // coldest; decide; reset the counters.
    win <= win + 1'b1;
    if (&win && scan == 6'd63 && !sweeping) begin
        scan <= 6'd0; hot_v <= 16'd0; hot_ok <= 1'b0; cold_v <= 16'hFFFF; cold_s <= 3'd0;
    end else if (scan < 6'd32) begin
        if (!in_any_slot(scan[4:0]) && heat[scan[4:0]] > hot_v) begin
            hot_v <= heat[scan[4:0]]; hot_b <= scan[4:0]; hot_ok <= 1'b1;
        end
        scan <= scan + 1'b1;
    end else if (scan < 6'd40) begin
        // an inactive slot counts as perfectly cold
        if (!slot_act[scan[2:0]]) begin
            if (cold_v != 16'd0) begin cold_v <= 16'd0; cold_s <= scan[2:0]; end
        end else if (heat[slot_blk[scan[2:0]]] < cold_v) begin
            cold_v <= heat[slot_blk[scan[2:0]]]; cold_s <= scan[2:0];
        end
        scan <= scan + 1'b1;
    end else if (scan == 6'd40) begin
        if (hot_ok && hot_v >= 16'd256 && {1'b0, hot_v} > {cold_v, 1'b0} && !sweeping) begin
            slot_act[cold_s] <= 1'b0;                       // stop serving the old block now
            sw_slot <= cold_s; sw_idx <= 13'd0; sw_newblk <= hot_b;
            sweeping <= 1'b1;
        end
        for (i = 0; i < 32; i = i + 1) heat[i] <= 16'd0;
        scan <= 6'd63;
    end

    if (rst) begin
        slot_act <= 8'd0; sweeping <= 1'b0; fill_pend <= 1'b0; scan <= 6'd63; win <= 23'd0;
        for (i = 0; i < 32; i = i + 1) heat[i] <= 16'd0;
    end
end

endmodule

`default_nettype wire
