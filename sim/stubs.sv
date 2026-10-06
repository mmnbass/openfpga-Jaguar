// Simulation stubs for Quartus/Altera primitives and the VHDL BRAM wrappers
// used by rtl/mem/sdram_dual.sv. Synthesis never sees this file.
`timescale 1ns/1ps

module altddio_out #(
    parameter extend_oe_disable  = "OFF",
    parameter intended_device_family = "Cyclone V",
    parameter invert_output      = "OFF",
    parameter lpm_hint           = "UNUSED",
    parameter lpm_type           = "altddio_out",
    parameter oe_reg             = "UNREGISTERED",
    parameter power_up_high      = "OFF",
    parameter width              = 1
) (
    input  wire [width-1:0] datain_h,
    input  wire [width-1:0] datain_l,
    input  wire             outclock,
    input  wire             outclocken,
    input  wire             aclr,
    input  wire             aset,
    input  wire             sclr,
    input  wire             sset,
    input  wire             oe,
    output wire [width-1:0] dataout
);
    // Behavioural DDR output: high half on the clock, low half on its inverse.
    assign dataout = outclock ? datain_h : datain_l;
endmodule

// Stand-in for the VHDL `dpram` in rtl/mem/bram.vhd (true dual port, write-first).
module dpram #(
    parameter addr_width = 8,
    parameter data_width = 8
) (
    input  wire                   clock,
    input  wire [addr_width-1:0]  address_a,
    input  wire [data_width-1:0]  data_a,
    input  wire                   wren_a,
    output reg  [data_width-1:0]  q_a,
    input  wire [addr_width-1:0]  address_b,
    input  wire [data_width-1:0]  data_b,
    input  wire                   wren_b,
    output reg  [data_width-1:0]  q_b
);
    reg [data_width-1:0] mem [0:(1<<addr_width)-1];
    always @(posedge clock) begin
        if (wren_a) mem[address_a] <= data_a;
        q_a <= wren_a ? data_a : mem[address_a];
        if (wren_b) mem[address_b] <= data_b;
        q_b <= wren_b ? data_b : mem[address_b];
    end
endmodule
