// Behavioural altsyncram, enough for the three live instantiations in the
// Jaguar netlist RTL: Tom/ab8016a (256x16), Tom/ab8616a (512x16) and
// jaguar_common/aba032a (1024x32). All three drive only port A; port B is tied
// off, so a single-port model is sufficient.
//
// read_during_write_mode_port_a is "NEW_DATA_NO_NBE_READ" in all three, i.e.
// write-first: q_a returns the data just written. Getting this backwards would
// silently corrupt the line buffer, the object-processor CLUTs and the GPU/DSP
// local RAM, so it matters.
//
// Not synthesised -- simulation only. Quartus uses the real megafunction.
`timescale 1ns/1ps

module altsyncram #(
    parameter                operation_mode              = "SINGLE_PORT",
    parameter integer        width_a                     = 16,
    parameter integer        widthad_a                   = 8,
    parameter integer        numwords_a                  = 256,
    parameter integer        width_b                     = 1,
    parameter integer        widthad_b                   = 1,
    parameter integer        numwords_b                  = 1,
    parameter integer        width_byteena_a             = 1,
    parameter integer        width_byteena_b             = 1,
    parameter                intended_device_family      = "Cyclone V",
    parameter                lpm_type                    = "altsyncram",
    parameter                lpm_hint                    = "",
    parameter                init_file                   = "",
    parameter                outdata_reg_a               = "CLOCK0",
    parameter                outdata_reg_b               = "CLOCK0",
    parameter                outdata_aclr_a              = "NONE",
    parameter                outdata_aclr_b              = "NONE",
    parameter                address_reg_b               = "CLOCK0",
    parameter                indata_reg_b                = "CLOCK0",
    parameter                wrcontrol_wraddress_reg_b   = "CLOCK0",
    parameter                clock_enable_input_a        = "BYPASS",
    parameter                clock_enable_input_b        = "BYPASS",
    parameter                clock_enable_output_a       = "BYPASS",
    parameter                clock_enable_output_b       = "BYPASS",
    parameter                power_up_uninitialized      = "FALSE",
    parameter                read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
    parameter                read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
    parameter                read_during_write_mode_mixed_ports = "DONT_CARE",
    parameter                ram_block_type              = "AUTO",
    parameter                byte_size                   = 8,
    parameter                maximum_depth               = 0,
    parameter                width_eccstatus             = 3
) (
    input  wire                        clock0,
    input  wire                        clock1,
    input  wire                        clocken0,
    input  wire                        clocken1,
    input  wire                        clocken2,
    input  wire                        clocken3,
    input  wire                        aclr0,
    input  wire                        aclr1,
    input  wire [widthad_a-1:0]        address_a,
    input  wire [width_a-1:0]          data_a,
    input  wire                        wren_a,
    input  wire                        rden_a,
    input  wire                        addressstall_a,
    input  wire [width_byteena_a-1:0]  byteena_a,
    output wire [width_a-1:0]          q_a,
    input  wire [widthad_b-1:0]        address_b,
    input  wire [width_b-1:0]          data_b,
    input  wire                        wren_b,
    input  wire                        rden_b,
    input  wire                        addressstall_b,
    input  wire [width_byteena_b-1:0]  byteena_b,
    output wire [width_b-1:0]          q_b,
    output wire [width_eccstatus-1:0]  eccstatus
);
    reg [width_a-1:0] mem [0:numwords_a-1];
    reg [width_a-1:0] q_a_r;

    integer i;
    initial begin
        for (i = 0; i < numwords_a; i = i + 1) mem[i] = '0;
        q_a_r = '0;
    end

    always @(posedge clock0) begin
        if (wren_a) begin
            mem[address_a] <= data_a;
            q_a_r          <= data_a;        // write-first
        end else begin
            q_a_r          <= mem[address_a];
        end
    end

    assign q_a       = q_a_r;

    // Port B: only for BIDIR_DUAL_PORT (the cart EEPROM backing RAM in
    // rtl/jaguar_top.sv). Same width as port A there.
    // The netlist RAMs above keep port B tied off and q_b reads 0 for them.
    reg [width_b-1:0] q_b_r = '0;
    generate if (operation_mode == "BIDIR_DUAL_PORT") begin : g_portb
        always @(posedge clock0) begin
            if (wren_b) begin
                mem[address_b] <= data_b;
                q_b_r          <= data_b;    // write-first
            end else begin
                q_b_r          <= mem[address_b];
            end
        end
    end endgenerate
    assign q_b       = q_b_r;
    assign eccstatus = '0;
endmodule
