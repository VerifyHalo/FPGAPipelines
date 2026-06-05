`timescale 1ns / 1ps
// SVA assertions for datapath, bind into DUT with Questa or Vivado sim.
// Usage (Questa): vlog datapath_assertions.sv; vsim -assertdebug
//
// FIFO overflow assertions (p_fifo_in_no_overflow, p_fifo_out_no_overflow)
// Bind example (Questa):
//   bind First datapath_assertions #() u_assert (
//       .clk             (okClk),
//       .rst_n           (rst_n),
//       .data_valid      (1'b0), .channel_id(6'd0),   // unused at top level
//       .data_valid_pipe (1'b0), .detected_pipe(1'b0),
//       .output_valid    (1'b0), .output_event(1'b0), .output_channel(6'd0),
//       .fifo_in_full    (fifoInFull_ro),
//       .fifo_in_wr_en   (fifoInWrite_ri),
//       .fifo_out_full   (fifoOutFull_ro),
//       .fifo_out_wr_en  (fifoOutWr_ro)
//   );

module datapath_assertions (
    input wire        clk,
    input wire        rst_n,
    input wire        data_valid,
    input wire [5:0]  channel_id,
    input wire        data_valid_pipe,
    input wire        detected_pipe,
    input wire        output_valid,
    input wire        output_event,
    input wire [5:0]  output_channel,
    // FIFO overflow ports
    input wire        fifo_in_full  = 1'b0,
    input wire        fifo_in_wr_en = 1'b0,
    input wire        fifo_out_full = 1'b0,
    input wire        fifo_out_wr_en = 1'b0
);

    // output_valid is a single-cycle pulse
    property p_valid_one_cycle;
        // one pulse = one transaction (start or end) to FIFO Out
        @(posedge clk) disable iff (!rst_n)
        output_valid |=> !output_valid;
    endproperty
    assert property (p_valid_one_cycle)
        else $error("[SVA FAIL] output_valid held high >1 cycle at t=%0t", $time);

    // detection gated by pipeline valid
    property p_detect_needs_pipe;
        // if there's no valid sample in the pipeline, there should be no detection
        @(posedge clk) disable iff (!rst_n)
        !data_valid_pipe |-> !detected_pipe;
    endproperty
    assert property (p_detect_needs_pipe)
        else $error("[SVA FAIL] detected_pipe without data_valid_pipe at t=%0t", $time);

    // I/P channel_id always in range when valid
    property p_channel_range;
        @(posedge clk) disable iff (!rst_n)
        data_valid |-> (channel_id < 32);
    endproperty
    assert property (p_channel_range)
        else $error("[SVA FAIL] channel_id=%0d out of range at t=%0t", channel_id, $time);

    // O/P channel in range when output fires
    property p_out_channel_range;
        @(posedge clk) disable iff (!rst_n)
        output_valid |-> (output_channel < 32);
    endproperty
    assert property (p_out_channel_range)
        else $error("[SVA FAIL] output_channel=%0d out of range at t=%0t", output_channel, $time);
    
    // add: timout -> 16bit 
    // add: count -> 

    // -----------------------------------------------------------
    // FIFO Overflow Assertions
    // -----------------------------------------------------------

    // FIFO In must never be written while full (bind to First.sv)
    property p_fifo_in_no_overflow;
        @(posedge clk) disable iff (!rst_n)
        !(fifo_in_full && fifo_in_wr_en);
    endproperty
    assert property (p_fifo_in_no_overflow)
        else $error("[SVA FAIL] FIFO In overflow: written while full at t=%0t", $time);

    // FIFO Out must never be written while full (bind to First.sv)
    property p_fifo_out_no_overflow;
        @(posedge clk) disable iff (!rst_n)
        !(fifo_out_full && fifo_out_wr_en);
    endproperty
    assert property (p_fifo_out_no_overflow)
        else $error("[SVA FAIL] FIFO Out overflow: written while full at t=%0t", $time);

endmodule
