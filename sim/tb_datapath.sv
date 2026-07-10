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
    // Catches output_valid at ANY cycle
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
    // FIFO Out overflow monitor
    // Counts output_valid pulses since the last reset. If the count
    // exceeds FIFO_OUT_DEPTH the PC-side FIFO would overflow and
    // events would be silently dropped.
    // --------------------------------------------------------
    localparam FIFO_OUT_DEPTH = 1024;
    integer fifo_event_count = 0;

    always @(posedge clk) begin
        if (!rst_n)
            fifo_event_count <= 0;
        else if (output_valid)
            fifo_event_count <= fifo_event_count + 1;
    end

    always @(posedge clk) begin
        if (fifo_event_count > FIFO_OUT_DEPTH)
            $error("[ASSERT] FIFO Out overflow risk: %0d events since reset exceeds depth=%0d at t=%0t",
                   fifo_event_count, FIFO_OUT_DEPTH, $time);
    end

    // --------------------------------------------------------
    // Per-channel event capture (multi-channel / simultaneous tests)
    // --------------------------------------------------------
    reg        ev0_seen = 0, ev1_seen = 0;
    reg [31:0] ch_event_seen = 32'd0;
    reg        start_seen = 0, end_seen = 0;

    always @(posedge clk) begin
        if (output_valid && output_channel === 6'd0) ev0_seen <= 1;
        if (output_valid && output_channel === 6'd1) ev1_seen <= 1;
        if (output_valid && output_channel < 32)     ch_event_seen[output_channel] <= 1'b1;
        if (output_valid && output_event)            start_seen <= 1;
        if (output_valid && !output_event)           end_seen <= 1;
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
        // Every test starts with this to ensure clean state
        rst_n <= 0; data_valid <= 0;
        repeat (4) @(posedge clk);
        @(negedge clk); rst_n <= 1;
        @(posedge clk);
    endtask

    task send_sample(input [5:0] ch, input [15:0] val);
        // Sends one 16-bit ADC sample on a given channel
        @(posedge clk); data_valid<=1; channel_id<=ch; data<=val;
        @(posedge clk); data_valid<=0;
    endtask

    task send_n(input [5:0] ch, input [15:0] val, input integer n);
        integer k;
        // send_sample n times, baseline, NEO = 0
        for (k = 0; k < n; k = k+1) send_sample(ch, val);
    endtask

    // Alternating spike/mid offsetted: keeps NEO = S^2 every other sample.
    // With S = spike-32768, NEO = S^2 when neighbors are mid (0-centered).
    task send_alternating(input [5:0] ch, input [15:0] spike_val,
                          input [15:0] mid_val, input integer pairs);
        integer k;
        for (k = 0; k < pairs; k = k+1) begin
            send_sample(ch, spike_val); // Spike - 32768
            send_sample(ch, mid_val); // 32768
        end
    endtask

    // Extra cycles for pipeline to flush (Stage0 -> Stage1 -> Stage2 = 2 cycles,
    // plus neo_abs 1-cycle lag = 3 total; give 20 for margin)
    task drain;
        repeat (20) @(posedge clk);
    endtask

    // A sample only becomes NEO's "center" once 2 more samples arrive after
    // it (Stage0 evaluates the window that was complete one sample ago).
    // Each [spike, mid, mid] group is therefore one fully self-flushed,
    // unambiguous detection: n groups = exactly n detections, no more.
    task send_isolated(input [5:0] ch, input [15:0] spike_val,
                       input [15:0] mid_val, input integer n);
        integer k;
        for (k = 0; k < n; k = k+1) begin
            send_sample(ch, spike_val);
            send_sample(ch, mid_val);
            send_sample(ch, mid_val);
        end
    endtask

    // --------------------------------------------------------
    // TEST 1: Flat signal at midpoint -> NEO=0, no event
    // --------------------------------------------------------
    task test_neo_flat_signal;
        $display("\n[TEST 1] NEO: flat midpoint signal -> no detection");
        reset_dut(); clear_capture();
        threshold_value  = 32'd100;
        window_timeout   = 32'd50;
        transition_count = 32'd3;

        send_n(0, 16'd32768, 15);
        drain();
        check("no output_valid on flat signal", cap_valid === 0);
    endtask

    // --------------------------------------------------------
    // TEST 2: Single spike -> nonzero NEO debug
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
    // TEST 3: NORMAL -> SEIZURE
    // Alternating spike/mid: NEO fires on every spike sample.
    // With threshold=50, S=232, NEO=53824 >> 50 -> detected on every spike.
    // With transition_count=3: seizure fires after 3 detections + pipeline lag.
    // --------------------------------------------------------
    task test_seizure_start;
        $display("\n[TEST 3] FSM: NORMAL - SEIZURE after %0d detections", 3);
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
    // TEST 4: SEIZURE -> NORMAL (window timeout)
    // Phase A triggers seizure. Phase B sends flat -> timeout -> end event.
    // --------------------------------------------------------
    task test_seizure_end;
        $display("\n[TEST 4] FSM: SEIZURE - NORMAL on window_timeout");
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

        // Phase B: quiet samples -> timeout
        clear_capture();
        send_n(0, 16'd32768, 20);   // 20 quiet > window_timeout=5
        drain();
        check("seizure end fires",   cap_valid === 1);
        check("end event=0",         cap_event === 0);
        check("end on channel 0",    cap_channel === 6'd0);
    endtask

    // --------------------------------------------------------
    // TEST 5: Multi-channel isolation
    // ch0 alternating spikes -> seizure; ch1 flat -> stays quiet
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

        // Only ch1 flat.. should stay quiet
        clear_capture();
        send_n(1, 16'd32768, 20);
        drain();
        check("ch1 no seizure", cap_valid === 0 ||
              (cap_valid === 1 && cap_channel !== 6'd1));
    endtask

    // --------------------------------------------------------
    // TEST 6: History guard. no event when < 3 samples in history
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
            // for the next 50 cyles
            for (k = 0; k < 50; k = k+1) begin
                @(posedge clk);
                if (output_valid) valid_cycles = valid_cycles + 1;
            end
        end
        check("output_valid ≤1 cycle per event", valid_cycles <= 1);
    endtask

    // --------------------------------------------------------
    // Overflow Checks
    // --------------------------------------------------------

    // --------------------------------------------------------
    // TEST 9: NEO at ADC rail values (0 and 65535)
    // Centered values: 0->-32768, 65535->+32767
    // Worst-case NEO: x[n]=32767, neighbors=-32768
    //   curr_sq  = 32767^2  = 1,073,676,289  (fits in 34-bit signed)
    //   neigh_mul= (-32768)^2 = 1,073,741,824 (fits in 34-bit signed)
    //   NEO      = -65535, abs = 65535
    // Verifies 34-bit arithmetic does not overflow at extremes.
    // --------------------------------------------------------
    task test_neo_rail_values;
        $display("\n[TEST 9] Overflow: NEO at ADC rail values (0 / 65535)");
        reset_dut(); clear_capture();
        threshold_value  = 32'd50;
        window_timeout   = 32'd50;
        transition_count = 32'd3;

        // Alternating 65535/0 gives maximum possible NEO excursion
        send_n(0, 16'd32768, 2);
        send_alternating(0, 16'd65535, 16'd0, 8);
        drain();
        // Must still produce valid seizure detection (no silent overflow/wrap)
        check("rail values trigger detection", cap_valid === 1);
        check("rail event is seizure start",   cap_event === 1);
    endtask

    // --------------------------------------------------------
    // TEST 10: detection_counter width: 8-bit counter vs 32-bit transition_count
    // detection_counter is declared as [7:0] (max 255).
    // If transition_count > 255 the counter wraps before reaching threshold.
    // This test exposes the mismatch: with transition_count=256 the counter
    // wraps to 0 at 256, so seizure never fires.
    // EXPECTED BEHAVIOUR (correct design): no seizure when count > 8-bit max.
    // --------------------------------------------------------
    task test_detection_counter_overflow;
        $display("\n[TEST 10] Overflow: detection_counter 8-bit vs 32-bit transition_count");
        reset_dut(); clear_capture();
        threshold_value  = 32'd50;
        window_timeout   = 32'd50;
        transition_count = 32'd257;   // transition_count-1=256, above 8-bit max (255)

        send_n(0, 16'd32768, 2);
        send_alternating(0, 16'd33000, 16'd32768, 150); // 150 pairs >> 256 detections
        drain();
        // With an 8-bit counter and transition_count=256, the counter wraps
        // back to 0 and the seizure never fires: expose the bug.
        check("KNOWN BUG: counter wraps, seizure never fires", cap_valid === 0);
    endtask

    // --------------------------------------------------------
    // TEST 11: continuous_counter width. 16-bit counter vs 32-bit window_timeout
    // continuous_counter is [15:0] (max 65535).
    // If window_timeout > 65535 the counter wraps before timeout, so
    // a seizure that started can never end.
    // --------------------------------------------------------
    task test_continuous_counter_overflow;
        integer wait_cycles;
        $display("\n[TEST 11] Overflow: continuous_counter 16-bit vs 32-bit window_timeout");
        reset_dut();
        threshold_value  = 32'd50;
        window_timeout   = 32'd70000;  // > 65535 (16-bit max)
        transition_count = 32'd3;

        // Phase A: trigger seizure start
        clear_capture();
        send_n(0, 16'd32768, 2);
        send_alternating(0, 16'd33000, 16'd32768, 8);
        drain();
        check("SETUP: seizure started", cap_valid === 1 && cap_event === 1);

        // Phase B: send many quiet samples. counter wraps at 65535, timeout
        // comparison (16-bit >= 32-bit 70000) is always false, seizure never ends.
        clear_capture();
        begin : cco_loop
            integer k;
            for (k = 0; k < 70010; k = k+1) send_sample(0, 16'd32768);
        end
        drain();
        check("KNOWN BUG: seizure end never fires (counter wraps)", cap_valid === 0);
    endtask

    // ==========================================================
    // GROUP: FSM exact-boundary / off-by-one
    // detection_counter/continuous_counter compare AFTER increment,
    // so the true trigger count is (transition_count-1) detections
    // and exactly window_timeout idle samples, not transition_count.
    // ==========================================================
    task test_transition_count_exact_boundary;
        $display("\n[TEST 12] FSM: fires after exactly transition_count-1 detections");
        reset_dut(); clear_capture();
        threshold_value  = 32'd50;
        window_timeout   = 32'd50;
        transition_count = 32'd5;

        send_n(0, 16'd32768, 2);
        send_isolated(0, 16'd33000, 16'd32768, 3);
        drain();
        check("not yet fired after 3 of 4 needed detections", cap_valid === 0);

        clear_capture();
        send_isolated(0, 16'd33000, 16'd32768, 1);
        drain();
        check("fires exactly on the 4th detection", cap_valid === 1 && cap_event === 1);
    endtask

    task test_window_timeout_exact_boundary;
        $display("\n[TEST 13] FSM: ends after exactly window_timeout idle samples");
        reset_dut(); clear_capture();
        threshold_value  = 32'd50;
        window_timeout   = 32'd10;
        transition_count = 32'd3;

        send_n(0, 16'd32768, 2);
        send_isolated(0, 16'd33000, 16'd32768, 2);
        drain();
        check("seizure started", cap_valid === 1 && cap_event === 1);

        clear_capture();
        send_n(0, 16'd32768, 9);
        drain();
        check("no end at window_timeout-1", cap_valid === 0);

        send_n(0, 16'd32768, 1);
        drain();
        check("end fires exactly at window_timeout", cap_valid === 1 && cap_event === 0);
    endtask

    task test_threshold_exact_equality;
        $display("\n[TEST 14] Threshold: NEO == threshold_value must NOT detect (strict >)");
        reset_dut(); clear_capture();
        threshold_value  = 32'd10000;
        window_timeout   = 32'd50;
        transition_count = 32'd1;

        send_n(0, 16'd32768, 2);
        send_sample(0, 16'd32868);
        send_n(0, 16'd32768, 4);
        drain();
        check("NEO computes exact value 10000", cap_neo_val === 17'd10000);
        check("NEO==threshold does not fire (strict >)", cap_valid === 0);
    endtask

    // ==========================================================
    // GROUP: Leaky-bucket detection accumulation
    // detection_counter is NOT reset between detections unless a
    // gap >= window_timeout occurs; "consecutive" is misleading.
    // ==========================================================
    task test_leaky_bucket_gap_preserves_count;
        $display("\n[TEST 15] Gap < window_timeout: non-consecutive detections still accumulate");
        reset_dut(); clear_capture();
        threshold_value  = 32'd50;
        window_timeout   = 32'd20;
        transition_count = 32'd3;

        send_n(0, 16'd32768, 2);
        send_sample(0, 16'd33000);
        send_n(0, 16'd32768, 10);
        send_sample(0, 16'd33000);
        send_n(0, 16'd32768, 3);
        drain();
        check("fires from 2 non-consecutive detections", cap_valid === 1 && cap_event === 1);
    endtask

    task test_leaky_bucket_gap_resets_count;
        $display("\n[TEST 16] Gap >= window_timeout: detection_counter resets, no false trigger");
        reset_dut(); clear_capture();
        threshold_value  = 32'd50;
        window_timeout   = 32'd20;
        transition_count = 32'd3;

        send_n(0, 16'd32768, 2);
        send_sample(0, 16'd33000);
        send_n(0, 16'd32768, 25);
        send_sample(0, 16'd33000);
        send_n(0, 16'd32768, 3);
        drain();
        check("no fire: counter reset by timeout gap", cap_valid === 0);
    endtask

    // ==========================================================
    // GROUP: Counter-width valid boundaries (complements TEST 10/11,
    // which only prove the failure just past these limits)
    // ==========================================================
    task test_transition_count_max_valid_256;
        $display("\n[TEST 17] transition_count=256 (8-bit boundary): must still fire correctly");
        reset_dut(); clear_capture();
        threshold_value  = 32'd50;
        window_timeout   = 32'd500;
        transition_count = 32'd256;

        send_n(0, 16'd32768, 2);
        send_isolated(0, 16'd33000, 16'd32768, 254);
        drain();
        check("not yet fired after 254 detections", cap_valid === 0);

        clear_capture();
        send_isolated(0, 16'd33000, 16'd32768, 1);
        drain();
        check("fires exactly at 255 detections (8-bit max)", cap_valid === 1 && cap_event === 1);
    endtask

    task test_window_timeout_max_valid_65535;
        integer k;
        $display("\n[TEST 18] window_timeout=65535 (16-bit boundary): must still end correctly");
        reset_dut(); clear_capture();
        threshold_value  = 32'd50;
        window_timeout   = 32'd65535;
        transition_count = 32'd3;

        send_n(0, 16'd32768, 2);
        send_isolated(0, 16'd33000, 16'd32768, 2);
        drain();
        check("seizure started", cap_valid === 1 && cap_event === 1);

        clear_capture();
        for (k = 0; k < 65535; k = k+1) send_sample(0, 16'd32768);
        drain();
        check("end fires exactly at 16-bit max window_timeout", cap_valid === 1 && cap_event === 0);
    endtask

    // ==========================================================
    // GROUP: Reset & pipeline integrity
    // ==========================================================
    task test_reset_midflight_pipeline;
        $display("\n[TEST 19] Reset asserted while a sample is still mid-pipeline (not drained)");
        reset_dut();
        threshold_value  = 32'd50;
        window_timeout   = 32'd50;
        transition_count = 32'd3;

        send_n(0, 16'd32768, 2);
        send_sample(0, 16'd33000);
        rst_n <= 0; repeat (4) @(posedge clk); rst_n <= 1; @(posedge clk);

        clear_capture();
        send_n(0, 16'd32768, 15);
        drain();
        check("no stale output after reset with in-flight sample", cap_valid === 0);
    endtask

    // ==========================================================
    // GROUP: Output correctness
    // ==========================================================
    task test_output_timestamp_value;
        $display("\n[TEST 20] output_timestamp reflects the exact triggering sample count");
        reset_dut(); clear_capture();
        threshold_value  = 32'd50;
        window_timeout   = 32'd50;
        transition_count = 32'd3;

        send_n(0, 16'd32768, 2);
        send_isolated(0, 16'd33000, 16'd32768, 2);
        drain();
        check("seizure start fires", cap_valid === 1 && cap_event === 1);
        check("timestamp equals exact sample count at trigger", cap_timestamp === 32'd8);
    endtask

    // ==========================================================
    // GROUP: NEO edge-case arithmetic
    // ==========================================================
    task test_neo_aliasing_false_negative;
        $display("\n[TEST 21] NEO aliasing: non-constant geometric triple also yields NEO=0");
        reset_dut(); clear_capture();
        threshold_value  = 32'd1;
        window_timeout   = 32'd50;
        transition_count = 32'd1;

        send_sample(0, 16'd32769);  // centered 1
        send_sample(0, 16'd32770);  // centered 2
        send_sample(0, 16'd32772);  // centered 4: 2^2 == 1*4 -> NEO=0
        send_sample(0, 16'd32776);  // centered 8: only needed to flush the (1,2,4) window
        drain();
        check("no detection on non-constant NEO-aliased triple", cap_valid === 0);
    endtask

    // ==========================================================
    // GROUP: Channel handling & multi-channel scale
    // ==========================================================
    task test_channel_id_out_of_range_isolation;
        $display("\n[TEST 22] Out-of-range channel_id (32-63) does not corrupt valid channels");
        reset_dut(); clear_capture();
        threshold_value  = 32'd50;
        window_timeout   = 32'd50;
        transition_count = 32'd3;

        send_n(6'd40, 16'd33000, 10);
        drain();
        check("no spurious output from OOB channel_id", cap_valid === 0);

        clear_capture();
        send_n(0, 16'd32768, 2);
        send_alternating(0, 16'd33000, 16'd32768, 8);
        drain();
        check("channel 0 still works correctly after OOB traffic", cap_valid === 1 && cap_channel === 6'd0);
    endtask

    task test_simultaneous_channel_events;
        integer k;
        $display("\n[TEST 23] Adjacent-cycle events on two channels are both reported");
        reset_dut();
        threshold_value  = 32'd50;
        window_timeout   = 32'd50;
        transition_count = 32'd3;
        ev0_seen = 0; ev1_seen = 0;

        send_n(0, 16'd32768, 2);
        send_n(1, 16'd32768, 2);
        for (k = 0; k < 2; k = k+1) begin
            send_sample(0, 16'd33000);
            send_sample(1, 16'd33000);
            send_sample(0, 16'd32768);
            send_sample(1, 16'd32768);
            send_sample(0, 16'd32768);
            send_sample(1, 16'd32768);
        end
        drain();
        check("channel 0 event reported", ev0_seen === 1);
        check("channel 1 event reported", ev1_seen === 1);
    endtask

    task test_all_channels_concurrent;
        integer ch, k;
        $display("\n[TEST 26] All 32 channels driven concurrently each reach seizure independently");
        reset_dut();
        threshold_value  = 32'd50;
        window_timeout   = 32'd500;
        transition_count = 32'd3;
        ch_event_seen = 32'd0;

        for (ch = 0; ch < 32; ch = ch+1) begin
            send_sample(ch, 16'd32768);
            send_sample(ch, 16'd32768);
        end
        for (k = 0; k < 4; k = k+1)
            for (ch = 0; ch < 32; ch = ch+1)
                send_sample(ch, (k[0] ? 16'd32768 : 16'd33000));
        drain();
        check("all 32 channels independently fire seizure start", &ch_event_seen === 1'b1);
    endtask

    // ==========================================================
    // GROUP: Degenerate configuration
    // ==========================================================
    task test_transition_count_zero;
        $display("\n[TEST 24] Degenerate config: transition_count=0 never fires (underflow)");
        reset_dut(); clear_capture();
        threshold_value  = 32'd50;
        window_timeout   = 32'd50;
        transition_count = 32'd0;

        send_n(0, 16'd32768, 2);
        send_alternating(0, 16'd33000, 16'd32768, 20);
        drain();
        check("transition_count=0 never fires", cap_valid === 0);
    endtask

    task test_window_timeout_zero;
        $display("\n[TEST 25] Degenerate config: window_timeout=0 ends seizure on first idle sample");
        reset_dut(); clear_capture();
        threshold_value  = 32'd50;
        window_timeout   = 32'd0;
        transition_count = 32'd3;
        start_seen = 0; end_seen = 0;

        // window_timeout=0 resets detection_counter on any gap, so the
        // trigger needs zero-gap (alternating) detections. The very next
        // evaluated idle sample -- even the trigger's own flush sample --
        // ends the seizure immediately, so start and end both land here.
        send_n(0, 16'd32768, 2);
        send_sample(0, 16'd33000);
        send_sample(0, 16'd32768);
        send_sample(0, 16'd33000);
        send_n(0, 16'd32768, 3);
        drain();
        check("seizure started", start_seen === 1);
        check("ends immediately with window_timeout=0", end_seen === 1);
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
        test_neo_rail_values();
        test_detection_counter_overflow();
        test_continuous_counter_overflow();
        test_transition_count_exact_boundary();
        test_window_timeout_exact_boundary();
        test_threshold_exact_equality();
        test_leaky_bucket_gap_preserves_count();
        test_leaky_bucket_gap_resets_count();
        test_transition_count_max_valid_256();
        test_window_timeout_max_valid_65535();
        test_reset_midflight_pipeline();
        test_output_timestamp_value();
        test_neo_aliasing_false_negative();
        test_channel_id_out_of_range_isolation();
        test_simultaneous_channel_events();
        test_transition_count_zero();
        test_window_timeout_zero();
        test_all_channels_concurrent();

        $display("\n====== RESULTS: %0d passed, %0d failed ======",
                 pass_count, fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                  $display("SOME TESTS FAILED");

        $finish;
    end

endmodule
`default_nettype wire
