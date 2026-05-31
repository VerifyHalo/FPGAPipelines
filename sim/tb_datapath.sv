`timescale 1ns / 1ps
`default_nettype none

// ============================================================
// Datapath unit test suite
// Run (from sim/): make sim
//
// NEO = x[n]^2 - x[n-1]*x[n+1] (all centered at 32768)
// IMPORTANT: constant-value spikes give NEO=0 once all 3 history
// slots are filled with the same value (S^2 - S*S = 0).
// Use alternating spike/mid to keep NEO non-zero.
// ============================================================
module tb_datapath;

    reg         clk   = 0;
    reg         rst_n = 0;
    reg  [31:0] threshold_value  = 32'd100;
    reg  [31:0] window_timeout   = 32'd5;
    reg  [31:0] transition_count = 32'd3;
    reg         data_valid = 0;
    reg  [15:0] data       = 0;
    reg  [5:0]  channel_id = 0;

    wire        output_valid;
    wire [31:0] output_timestamp;
    wire        output_event;
    wire [5:0]  output_channel;
    wire [16:0] neo_debug;
    wire        neo_debug_valid;
    wire        detected_debug;

    datapath dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .threshold_value (threshold_value),
        .window_timeout  (window_timeout),
        .transition_count(transition_count),
        .data_valid      (data_valid),
        .data            (data),
        .channel_id      (channel_id),
        .output_valid    (output_valid),
        .output_timestamp(output_timestamp),
        .output_event    (output_event),
        .output_channel  (output_channel),
        .neo_debug       (neo_debug),
        .neo_debug_valid (neo_debug_valid),
        .detected_debug  (detected_debug)
    );

    always #5 clk = ~clk;

    // --------------------------------------------------------
    // Background capture — catches output_valid at ANY cycle
    // --------------------------------------------------------
    reg        cap_valid     = 0;
    reg        cap_event     = 0;
    reg [5:0]  cap_channel   = 0;
    reg [31:0] cap_timestamp = 0;
    reg        cap_neo_fired = 0;
    reg [16:0] cap_neo_val   = 0;

    always @(posedge clk) begin
        if (output_valid) begin
            cap_valid     <= 1;
            cap_event     <= output_event;
            cap_channel   <= output_channel;
            cap_timestamp <= output_timestamp;
        end
        if (neo_debug_valid && neo_debug > 0) begin
            cap_neo_fired <= 1;
            cap_neo_val   <= neo_debug;
        end
    end

    task clear_capture;
        @(negedge clk);
        cap_valid     = 0; cap_event     = 0;
        cap_channel   = 0; cap_timestamp = 0;
        cap_neo_fired = 0; cap_neo_val   = 0;
    endtask

    // --------------------------------------------------------
    // Procedural assertion monitors
    // --------------------------------------------------------
    reg prev_output_valid = 0;
    always @(posedge clk) begin
        if (prev_output_valid && output_valid)
            $error("[ASSERT] output_valid held >1 cycle at t=%0t", $time);
        prev_output_valid <= output_valid;
        if (output_valid && output_channel >= 32)
            $error("[ASSERT] output_channel=%0d OOB at t=%0t", output_channel, $time);
        if (data_valid && channel_id >= 32)
            $error("[ASSERT] channel_id=%0d OOB at t=%0t", channel_id, $time);
    end

    // --------------------------------------------------------
    // Score
    // --------------------------------------------------------
    integer pass_count = 0;
    integer fail_count = 0;

    task check(input string name, input condition);
        if (condition) begin
            $display("  PASS: %s", name);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: %s", name);
            fail_count = fail_count + 1;
        end
    endtask

    // --------------------------------------------------------
    // Stimulus helpers
    // --------------------------------------------------------
    task reset_dut;
        rst_n <= 0; data_valid <= 0;
        repeat (4) @(posedge clk);
        @(negedge clk); rst_n <= 1;
        @(posedge clk);
    endtask

    task send_sample(input [5:0] ch, input [15:0] val);
        @(posedge clk); data_valid<=1; channel_id<=ch; data<=val;
        @(posedge clk); data_valid<=0;
    endtask

    task send_n(input [5:0] ch, input [15:0] val, input integer n);
        integer k;
        for (k = 0; k < n; k = k+1) send_sample(ch, val);
    endtask

    // Alternating spike/mid: keeps NEO = S^2 every other sample.
    // With S = spike-32768, NEO = S^2 when neighbors are mid (0-centered).
    task send_alternating(input [5:0] ch, input [15:0] spike_val,
                          input [15:0] mid_val, input integer pairs);
        integer k;
        for (k = 0; k < pairs; k = k+1) begin
            send_sample(ch, spike_val);
            send_sample(ch, mid_val);
        end
    endtask

    // Extra cycles for pipeline to flush (Stage0→Stage1→Stage2 = 2 cycles,
    // plus neo_abs 1-cycle lag = 3 total; give 20 for margin)
    task drain;
        repeat (20) @(posedge clk);
    endtask

    // --------------------------------------------------------
    // TEST 1: Flat signal at midpoint → NEO=0, no event
    // --------------------------------------------------------
    task test_neo_flat_signal;
        $display("\n[TEST 1] NEO: flat midpoint signal → no detection");
        reset_dut(); clear_capture();
        threshold_value  = 32'd100;
        window_timeout   = 32'd50;
        transition_count = 32'd3;

        send_n(0, 16'd32768, 15);
        drain();
        check("no output_valid on flat signal", cap_valid === 0);
    endtask

    // --------------------------------------------------------
    // TEST 2: Single spike → nonzero NEO debug
    // neo_abs uses neo_val from prev cycle: need 2+ trailing samples.
    // spike=32868, centered=+100, NEO=100^2=10000
    // --------------------------------------------------------
    task test_neo_known_value;
        $display("\n[TEST 2] NEO: spike produces nonzero neo_debug");
        reset_dut(); clear_capture();
        threshold_value  = 32'd999999;  // too high to fire seizure
        window_timeout   = 32'd50;
        transition_count = 32'd99;

        send_n(0, 16'd32768, 2);       // fill history[0],[1]
        send_sample(0, 16'd32868);     // spike in history[2]: centered=+100
        send_n(0, 16'd32768, 4);       // 4 trailing lets neo_abs flush
        drain();
        check("spike generates nonzero NEO", cap_neo_fired === 1);
    endtask

    // --------------------------------------------------------
    // TEST 3: NORMAL → SEIZURE
    // Alternating spike/mid: NEO fires on every spike sample.
    // With threshold=50, S=232, NEO=53824 >> 50 → detected on every spike.
    // With transition_count=3: seizure fires after 3 detections + pipeline lag.
    // --------------------------------------------------------
    task test_seizure_start;
        $display("\n[TEST 3] FSM: NORMAL → SEIZURE after %0d detections", 3);
        reset_dut(); clear_capture();
        threshold_value  = 32'd50;
        window_timeout   = 32'd50;
        transition_count = 32'd3;

        send_n(0, 16'd32768, 2);                    // fill history
        send_alternating(0, 16'd33000, 16'd32768, 8); // 8 spike/mid pairs
        drain();
        check("seizure start fires",     cap_valid === 1);
        check("start event=1",           cap_event === 1);
        check("start on channel 0",      cap_channel === 6'd0);
    endtask

    // --------------------------------------------------------
    // TEST 4: SEIZURE → NORMAL (window timeout)
    // Phase A triggers seizure. Phase B sends flat → timeout → end event.
    // --------------------------------------------------------
    task test_seizure_end;
        $display("\n[TEST 4] FSM: SEIZURE → NORMAL on window_timeout");
        reset_dut();
        threshold_value  = 32'd50;
        window_timeout   = 32'd5;
        transition_count = 32'd3;

        // Phase A: start seizure
        clear_capture();
        send_n(0, 16'd32768, 2);
        send_alternating(0, 16'd33000, 16'd32768, 8);
        drain();
        check("seizure start fires (phase A)", cap_valid === 1 && cap_event === 1);

        // Phase B: quiet samples → timeout
        clear_capture();
        send_n(0, 16'd32768, 20);   // 20 quiet > window_timeout=5
        drain();
        check("seizure end fires",   cap_valid === 1);
        check("end event=0",         cap_event === 0);
        check("end on channel 0",    cap_channel === 6'd0);
    endtask

    // --------------------------------------------------------
    // TEST 5: Multi-channel isolation
    // ch0 alternating spikes → seizure; ch1 flat → stays quiet
    // --------------------------------------------------------
    task test_channel_isolation;
        integer k;
        $display("\n[TEST 5] Multi-channel isolation: ch0 seizure ≠ affect ch1");
        reset_dut();
        threshold_value  = 32'd50;
        window_timeout   = 32'd50;
        transition_count = 32'd3;

        // Interleave ch0 (spike/mid) and ch1 (flat)
        clear_capture();
        for (k = 0; k < 12; k = k+1) begin
            send_sample(0, (k[0] ? 16'd32768 : 16'd33000)); // spike/mid on ch0
            send_sample(1, 16'd32768);                       // flat on ch1
        end
        drain();
        check("ch0 seizure fired",    cap_valid === 1 && cap_channel === 6'd0);

        // Only ch1 flat — should stay quiet
        clear_capture();
        send_n(1, 16'd32768, 20);
        drain();
        check("ch1 no seizure", cap_valid === 0 ||
              (cap_valid === 1 && cap_channel !== 6'd1));
    endtask

    // --------------------------------------------------------
    // TEST 6: History guard — no event when < 3 samples in history
    // --------------------------------------------------------
    task test_history_guard;
        $display("\n[TEST 6] History guard: no event on first 2 samples");
        reset_dut(); clear_capture();
        threshold_value  = 32'd1;    // ultra-low — fires if NEO ran early
        window_timeout   = 32'd50;
        transition_count = 32'd1;

        send_sample(5, 16'd65535);
        send_sample(5, 16'd0);
        drain();
        check("no event before 3rd sample", cap_valid === 0);
    endtask

    // --------------------------------------------------------
    // TEST 7: Reset clears all state
    // --------------------------------------------------------
    task test_reset_clears_state;
        $display("\n[TEST 7] Reset clears all channel state");
        reset_dut();
        threshold_value  = 32'd50;
        window_timeout   = 32'd50;
        transition_count = 32'd3;

        // Trigger seizure
        send_n(0, 16'd32768, 2);
        send_alternating(0, 16'd33000, 16'd32768, 8);
        drain();

        // Hard reset mid-seizure
        rst_n <= 0; repeat (4) @(posedge clk); rst_n <= 1; @(posedge clk);

        clear_capture();
        send_n(0, 16'd32768, 15);
        drain();
        check("post-reset no stale output_valid", cap_valid === 0);
    endtask

    // --------------------------------------------------------
    // TEST 8: output_valid must be a 1-cycle pulse
    // --------------------------------------------------------
    task test_valid_pulse_width;
        integer valid_cycles;
        $display("\n[TEST 8] output_valid is exactly 1 cycle wide");
        reset_dut();
        threshold_value  = 32'd50;
        window_timeout   = 32'd50;
        transition_count = 32'd3;

        send_n(0, 16'd32768, 2);
        send_alternating(0, 16'd33000, 16'd32768, 8);

        valid_cycles = 0;
        begin : pc
            integer k;
            for (k = 0; k < 60; k = k+1) begin
                @(posedge clk);
                if (output_valid) valid_cycles = valid_cycles + 1;
            end
        end
        check("output_valid ≤1 cycle per event", valid_cycles <= 1);
    endtask

    // --------------------------------------------------------
    // Run
    // --------------------------------------------------------
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_datapath);

        $display("====== datapath unit tests ======");
        test_neo_flat_signal();
        test_neo_known_value();
        test_seizure_start();
        test_seizure_end();
        test_channel_isolation();
        test_history_guard();
        test_reset_clears_state();
        test_valid_pulse_width();

        $display("\n====== RESULTS: %0d passed, %0d failed ======",
                 pass_count, fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                  $display("SOME TESTS FAILED");

        $finish;
    end

endmodule
`default_nettype wire
