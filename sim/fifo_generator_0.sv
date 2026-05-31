`timescale 1ns / 1ps

// Behavioral FIFO stub replacing Xilinx fifo_generator_0 for simulation.
// Sync FIFO, 32-bit wide, 1024 depth.
module fifo_generator_0 #(
    parameter DEPTH = 1024
) (
    input  wire        clk,
    input  wire        srst,
    input  wire [31:0] din,
    input  wire        wr_en,
    input  wire        rd_en,
    output reg  [31:0] dout,
    output wire        full,
    output wire        empty
);
    reg [31:0] mem [0:DEPTH-1];
    reg [$clog2(DEPTH):0] wr_ptr = 0, rd_ptr = 0, count = 0;

    assign full  = (count == DEPTH);
    assign empty = (count == 0);

    always @(posedge clk) begin
        if (srst) begin
            wr_ptr <= 0; rd_ptr <= 0; count <= 0; dout <= 0;
        end else begin
            if (wr_en && !full) begin
                mem[wr_ptr[$clog2(DEPTH)-1:0]] <= din;
                wr_ptr <= wr_ptr + 1;
                count  <= count + 1;
            end
            if (rd_en && !empty) begin
                dout   <= mem[rd_ptr[$clog2(DEPTH)-1:0]];
                rd_ptr <= rd_ptr + 1;
                count  <= count - (wr_en && !full ? 0 : 1);
            end
        end
    end
endmodule
