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
//       .fifo_out_wr_en  (fifoOutWr_ro),
//       .threshold_value (threshold_value_ro),
//       .window_timeout  (window_timeout_ro),
//       .transition_count(transition_count_ro)
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
    input wire        fifo_out_wr_en = 1'b0,
    // WireIn configuration registers (0x03/0x04/0x05) -- see Input Assumptions below
    input wire [31:0] threshold_value   = 32'd0,
    input wire [31:0] window_timeout    = 32'd0,
    input wire [31:0] transition_count  = 32'd0
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

    // WINDOW_TIMEOUT (WireIn 0x04) vs. 16-bit channel_continuous_counter
    property p_window_timeout_fits;
        @(posedge clk) disable iff (!rst_n)
        window_timeout <= 32'h0000_FFFF;
    endproperty
    assert property (p_window_timeout_fits)
        else $warning("[SVA WARN] window_timeout=%0d exceeds 16-bit continuous_counter range (max 65535), seizure-end may never fire at t=%0t",
                      window_timeout, $time);

    // TRANSITION_COUNT (WireIn 0x05) vs. 8-bit channel_detection_counter
    // FSM checks detection_counter >= (transition_count - 1), so the largest
    // satisfiable value is transition_count == 256 (detection_counter maxes at 255).
    property p_transition_count_fits;
        @(posedge clk) disable iff (!rst_n)
        transition_count <= 32'd256;
    endproperty
    assert property (p_transition_count_fits)
        else $warning("[SVA WARN] transition_count=%0d exceeds 8-bit detection_counter range (max 256), seizure-start may never fire at t=%0t",
                      transition_count, $time);

    // THRESHOLD_VALUE (WireIn 0x03) is compared directly against the 34-bit
    // neo_abs_next pipeline register.

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
