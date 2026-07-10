`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.12.2025 09:36:32
// Design Name: 
// Module Name: datapath
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

// ================================================================
// Continuous seizure detection datapath (as provided, THRESHOLD=25000)
// ================================================================

// Continuous seizure detection datapath
// Processes samples one at a time with step of 1
// NEO -> Threshold -> Gating -> Output events
// Tunable detection parameters
// NOTE: These are set aggressively low so we can verify the pipeline
// is producing events. Once you see events in the plots, you can
// tighten them (increase THRESHOLD_VALUE and/or TRANSITION_COUNT).

`define CHANNELS_PER_PACKET 32

module datapath (
    input  wire        clk,
    input  wire        rst_n,

    // Configurable parameters from WireIn
    input  wire [31:0] threshold_value,   // NEO threshold (configurable from WireIn)
    input  wire [31:0] window_timeout,   // Samples with no detections before ending seizure
    input  wire [31:0] transition_count, // Number of detections needed to start seizure

    // FIFO interface
    input  wire        data_valid,             // 1 when new sample is available

    // 16-bit Intan-style ADC code (0-65535), mid-point at 32768
    input  wire [15:0] data,
    input  wire [5:0]  channel_id,       // Channel ID (0-31)

    // Output interface (seizure events)
    output reg output_valid,              // 1 when output event is available
    output reg [31:0] output_timestamp,   // Timestamp of event
    output reg output_event,              // 1 = seizure start, 0 = seizure end
    output reg [5:0]  output_channel,     // Channel ID for this event

    // Debug outputs: NEO value and detection per sample (for testbench logging only)
    output reg [16:0] neo_debug,          // Lower 17 bits of current NEO value
    output reg        neo_debug_valid,    // 1 when neo_debug is valid
    output reg        detected_debug      // 1 when this NEO sample crosses threshold
);

    logic [1:0] history_count;          // How many samples we have (0-3)

    logic signed [33:0] neo_val;
    logic        [33:0] neo_abs;
    
    // Threshold comparison
    logic detected;
    
    // Gating state machine
    typedef enum logic {
        STATE_NORMAL = 1'b0,
        STATE_SEIZURE = 1'b1
    } gating_state_t;

    logic [15:0] continuous_counter;    // Timeout counter
    logic [7:0] detection_counter;      // Detection counter for transition
    
    // Per-channel state (each channel has its own gating state and timestamp)
    gating_state_t  channel_state [0:`CHANNELS_PER_PACKET-1];
    logic [15:0]    channel_continuous_counter [0:`CHANNELS_PER_PACKET-1];
    logic [7:0]     channel_detection_counter [0:`CHANNELS_PER_PACKET-1];
    logic [31:0]    channel_timestamp [0:`CHANNELS_PER_PACKET-1];
    logic [31:0]    channel_seizure_left [0:`CHANNELS_PER_PACKET-1];
    logic [31:0]    channel_seizure_right [0:`CHANNELS_PER_PACKET-1];
    logic [1:0]     channel_history_count [0:`CHANNELS_PER_PACKET-1];
    // Raw 16-bit samples per channel for history
    logic [15:0]    channel_sample_history [0:`CHANNELS_PER_PACKET-1][0:2];
    
    // Pipeline registers to break long combinational path:
    // stage 0: per-channel history + raw NEO multiplies
    // stage 1: NEO subtract/abs/threshold
    // stage 2: gating state machine using registered detection + channel_id
    logic signed [33:0] curr_sq_pipe, neigh_mul_pipe;
    logic [5:0]         channel_id_sq_pipe;
    logic               data_valid_sq_pipe;

    logic [33:0] neo_abs_pipe;
    logic        detected_pipe;
    logic [5:0]  channel_id_pipe;
    logic        data_valid_pipe;

    // Combinational Stage 1 wires: compute NEO directly from Stage 0 registers
    // (avoids 1-cycle lag and cross-channel contamination via registered neo_val/neo_abs)
    wire signed [33:0] neo_next     = curr_sq_pipe - neigh_mul_pipe;
    wire        [33:0] neo_abs_next = neo_next[33] ? (~neo_next + 34'd1) : neo_next;
    
    // ========================================================================
    // DATAPATH RESTORATION - STEP BY STEP
    // ========================================================================
    // Step 1: Restore Stage 0 (sample history collection) - ACTIVE
    // Step 2: Restore Stage 1 (NEO computation) - ACTIVE
    // Step 3: Restore Stage 2 (gating state machine) - ACTIVE
    
    // Main processing logic - RESTORING REAL LOGIC STEP BY STEP
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset outputs
            output_valid      <= 1'b0;
            output_timestamp  <= 32'd0;
            output_event      <= 1'b0;
            output_channel    <= 6'd0;
            neo_debug         <= 17'd0;
            neo_debug_valid   <= 1'b0;
            detected_debug    <= 1'b0;
            
            // Reset all channels
            for (int ch = 0; ch < `CHANNELS_PER_PACKET; ch++) begin
                channel_state[ch] <= STATE_NORMAL;
                channel_continuous_counter[ch] <= 16'd0;
                channel_detection_counter[ch] <= 8'd0;
                channel_timestamp[ch] <= 32'd0;
                channel_seizure_left[ch] <= 32'd0;
                channel_seizure_right[ch] <= 32'd0;
                channel_history_count[ch] <= 2'd0;
                for (int i = 0; i < 3; i++) begin
                    channel_sample_history[ch][i] <= 16'd0;
                end
            end
            
            // Reset pipeline registers
            curr_sq_pipe      <= 34'd0;
            neigh_mul_pipe    <= 34'd0;
            channel_id_sq_pipe<= 6'd0;
            data_valid_sq_pipe<= 1'b0;
            neo_val           <= 34'd0;
            neo_abs           <= 34'd0;
            neo_abs_pipe      <= 34'd0;
            detected_pipe     <= 1'b0;
            channel_id_pipe   <= 6'd0;
            data_valid_pipe   <= 1'b0;
            detected          <= 1'b0;
        end else begin
            // Default: no event output (will be overridden if event occurs)
            output_valid      <= 1'b0;
            neo_debug_valid   <= 1'b0;
            detected_debug    <= 1'b0;
            data_valid_pipe   <= 1'b0;
            data_valid_sq_pipe<= 1'b0;
            
            // ====================================================================
            // STAGE 0: Sample history collection per channel
            // ====================================================================
            if (data_valid) begin
                // Update timestamp for this channel
                channel_timestamp[channel_id] <= channel_timestamp[channel_id] + 32'd1;
                
                // Get current channel's counters and history count for this channel
                continuous_counter = channel_continuous_counter[channel_id];
                detection_counter = channel_detection_counter[channel_id];
                history_count = channel_history_count[channel_id];
                
                // Update sample history (sliding window)
                if (history_count < 2'd3) begin
                    // Still filling history
                    channel_sample_history[channel_id][history_count] <= data;
                    channel_history_count[channel_id] <= history_count + 2'd1;
                end else begin
                    // Shift window: prev=curr, curr=next, next=new
                    channel_sample_history[channel_id][0] <= channel_sample_history[channel_id][1];
                    channel_sample_history[channel_id][1] <= channel_sample_history[channel_id][2];
                    channel_sample_history[channel_id][2] <= data;
                end
                
                // Compute NEO multiplies and register them if we have 3 samples.
                // xp/xc/xn are read from this channel's own array and consumed
                // in this same statement -- no shared combinational net is
                // written-then-read across channels, so there is no
                // same-timestep race between interleaved channels.
                if (history_count >= 2'd3) begin
                    logic signed [16:0] xp, xc, xn;
                    xp = $signed({1'b0, channel_sample_history[channel_id][0]}) - 17'd32768;
                    xc = $signed({1'b0, channel_sample_history[channel_id][1]}) - 17'd32768;
                    xn = $signed({1'b0, channel_sample_history[channel_id][2]}) - 17'd32768;

                    // Register products for later NEO / threshold stage
                    curr_sq_pipe       <= xc * xc;
                    neigh_mul_pipe     <= xp * xn;
                    channel_id_sq_pipe <= channel_id;
                    data_valid_sq_pipe <= 1'b1;
                end
            end

            // ====================================================================
            // STAGE 1: NEO subtract/abs/threshold (ENABLED)
            // ====================================================================
            if (data_valid_sq_pipe) begin
                // Register for debug/waveform only — not used for detection
                neo_val <= neo_next;
                neo_abs <= neo_abs_next;

                // Use combinational neo_abs_next to avoid 1-cycle lag and
                // cross-channel contamination via stale neo_val/neo_abs registers
                detected          <= (neo_abs_next > threshold_value);
                neo_debug         <= neo_abs_next[16:0];
                neo_debug_valid   <= 1'b1;
                detected_debug    <= (neo_abs_next > threshold_value);

                neo_abs_pipe      <= neo_abs_next;
                detected_pipe     <= (neo_abs_next > threshold_value);
                channel_id_pipe   <= channel_id_sq_pipe;
                data_valid_pipe   <= 1'b1;
            end

            // ====================================================================
            // STAGE 2: Gating state machine
            // ====================================================================
            // Real seizure detection: generates events based on NEO threshold crossings
            // Note: Real events take priority over test events (Stage 2 runs after test event check)
            if (data_valid_pipe) begin
                // Get current channel's counters for this pipelined channel
                continuous_counter = channel_continuous_counter[channel_id_pipe];
                detection_counter  = channel_detection_counter[channel_id_pipe];

                // Increment continuous counter
                continuous_counter = continuous_counter + 16'd1;
                
                if (channel_state[channel_id_pipe] == STATE_NORMAL) begin
                    if (detected_pipe) begin
                        detection_counter  = detection_counter + 8'd1;
                        continuous_counter = 16'd0;
                        if (detection_counter >= (transition_count - 1)) begin
                            // Transition to seizure state
                            channel_seizure_left[channel_id_pipe]      <= channel_timestamp[channel_id_pipe];
                            channel_state[channel_id_pipe]             <= STATE_SEIZURE;
                            channel_detection_counter[channel_id_pipe] <= 8'd0;
                            channel_continuous_counter[channel_id_pipe]<= 16'd0;
                            
                            // Output seizure start event (real event takes priority)
                            output_valid     <= 1'b1;
                            output_timestamp <= channel_timestamp[channel_id_pipe];
                            output_event     <= 1'b1;
                            output_channel   <= channel_id_pipe;
                        end else begin
                            channel_detection_counter[channel_id_pipe] <= detection_counter;
                            channel_continuous_counter[channel_id_pipe]<= continuous_counter;
                        end
                    end else begin
                        if (continuous_counter >= window_timeout) begin
                            // Timeout: reset counters
                            channel_detection_counter[channel_id_pipe] <= 8'd0;
                            channel_continuous_counter[channel_id_pipe]<= 16'd0;
                        end else begin
                            channel_continuous_counter[channel_id_pipe]<= continuous_counter;
                        end
                    end
                end else begin  // STATE_SEIZURE
                    // Explicitly check we're still in SEIZURE state before processing
                    // This prevents outputting 10 events when already in NORMAL
                    if (channel_state[channel_id_pipe] == STATE_SEIZURE) begin
                        if (detected_pipe) begin
                            // Update right boundary
                            channel_seizure_right[channel_id_pipe]       <= channel_timestamp[channel_id_pipe];
                            channel_continuous_counter[channel_id_pipe]  <= 16'd0;
                        end else begin
                            if (continuous_counter >= window_timeout) begin
                                // Transition to normal state (only output 10 when actually transitioning)
                                channel_state[channel_id_pipe]             <= STATE_NORMAL;
                                channel_continuous_counter[channel_id_pipe]<= 16'd0;
                                channel_detection_counter[channel_id_pipe] <= 8'd0;
                                
                                // Output seizure end event (only when transitioning from SEIZURE to NORMAL)
                                output_valid     <= 1'b1;
                                output_timestamp <= channel_timestamp[channel_id_pipe];
                                output_event     <= 1'b0;
                                output_channel   <= channel_id_pipe;
                            end else begin
                                channel_continuous_counter[channel_id_pipe]<= continuous_counter;
                            end
                        end
                    end
                    // If state is not SEIZURE (shouldn't happen, but handle gracefully)
                    // Don't output any events - state machine is in NORMAL or corrupted
                end
            end
            
            // If data_valid is 0, we don't process (wait for next sample)
            // This handles FIFO underflow - we just wait
        end
    end


endmodule
