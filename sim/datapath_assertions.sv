`timescale 1ns / 1ps
// SVA assertions for datapath, bind into DUT with Questa or Vivado sim.
// Usage (Questa): vlog datapath_assertions.sv; vsim -assertdebug

module datapath_assertions (
    input wire        clk,
    input wire        rst_n,
    input wire        data_valid,
    input wire [5:0]  channel_id,
    input wire        data_valid_pipe,
    input wire        detected_pipe,
    input wire        output_valid,
    input wire        output_event,
    input wire [5:0]  output_channel
);
    // output_valid is a single-cycle pulse
    property p_valid_one_cycle;
        @(posedge clk) disable iff (!rst_n)
        output_valid |=> !output_valid;
    endproperty
    assert property (p_valid_one_cycle)
        else $error("[SVA FAIL] output_valid held high >1 cycle at t=%0t", $time);

    // detection gated by pipeline valid
    property p_detect_needs_pipe;
        @(posedge clk) disable iff (!rst_n)
        !data_valid_pipe |-> !detected_pipe;
    endproperty
    assert property (p_detect_needs_pipe)
        else $error("[SVA FAIL] detected_pipe without data_valid_pipe at t=%0t", $time);

    // channel_id always in range when valid
    property p_channel_range;
        @(posedge clk) disable iff (!rst_n)
        data_valid |-> (channel_id < 32);
    endproperty
    assert property (p_channel_range)
        else $error("[SVA FAIL] channel_id=%0d out of range at t=%0t", channel_id, $time);

    // output_channel in range when output fires
    property p_out_channel_range;
        @(posedge clk) disable iff (!rst_n)
        output_valid |-> (output_channel < 32);
    endproperty
    assert property (p_out_channel_range)
        else $error("[SVA FAIL] output_channel=%0d out of range at t=%0t", output_channel, $time);

endmodule
