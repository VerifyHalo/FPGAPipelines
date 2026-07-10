`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.12.2025 09:08:09
// Design Name: 
// Module Name: First
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

/*Naming 

"_ro" -> wire out of a register
"_ri" -> wire into a register
"_i" -> input
"_o" -> output
"_w" -> wire between combinational elements

*/

module First(
    // handled by the ok macro
    input  wire [4:0]   okUH,      // 5 bit for the USB3.0 i/p OpalKelly FSM (do NOT change)
    output wire [2:0]   okHU,      // 3 bit for the USB3.0 o/p OpalKelly FSM (do NOT change)
    inout  wire [31:0]  okUHU,     // USB3.0 in/out 32bit data bus (handled by the okHost, do NOT change)
    inout  wire         okAA,      // valid in/out signal for the USB3.0 protocol handshake (do NOT change)
    // fpga default clk (need to synthesize)
    input  wire sys_clkn,          // FPGA p_edge clk (not used, attach to the okClk for easy sync)
    input  wire sys_clkp,          // FPGA n_edge clk (not used, attach to the okClk for easy sync)
    // debug outputs
    output wire [7:0]   led        // OpalKelly LED IOs
);

// Instantiate FrontPanel (FP) Host interface
// https://docs.opalkelly.com/fphdl/frontpanel-hdl-usb-3-0/
wire         okClk;         // 100.8MHz (ok fixed)
wire [112:0] okHE_ri;       // Header (ok fixed)
wire [64:0]  okEH_ro;       // Interface (ok fixed)

// Define and Register with okHost 4 Endpoints (2 pipes + 2 wireouts)
localparam NUM_ENDPOINTS = 4;
localparam integer CHUNK_WORDS = 1024;          // 4 KB = 1024 words (32-bit)
localparam integer CHUNK_BITS  = 32 * CHUNK_WORDS;
wire [NUM_ENDPOINTS*65-1:0] okEHx_ro; //[numEndPoints(=WireOut,PipeIn)*65-1:0]

okHost hostIF (
    .okUH(okUH),      // 5 bit for the USB3.0 i/p OpalKelly FSM
    .okHU(okHU),      // 3 bit for the USB3.0 o/p OpalKelly FSM
    .okUHU(okUHU),    // USB3.0 in/out 32bit data bus
    .okAA(okAA),      // USB3.0 protocol handshake
    .okClk(okClk),    // Generated okHost CLK 
    .okHE(okHE_ri),   // okHost write out header based (we design)
    .okEH(okEH_ro)    // in from endpoint to host
);

// -------------------------------------------- //
// Opal Kelly PC-FPGA Endpoints                 //
// -------------------------------------------- //

// Since okHost sets valid only a single endpoint at okEHx_ro valid at a time
// we can wireOR to a okEH_ro 65 bit bus.
okWireOR # (.N(NUM_ENDPOINTS)) wireOR (okEH_ro, okEHx_ro); //.N is numEndPoints
   
// PC -> FPGA interface (keep existing addresses where still used)
// WireIns:
// 0x00 -> reset (bit 31)
// 0x01 -> timestamp lower 32 bits
// 0x02 -> timestamp upper 32 bits
// 0x03 -> THRESHOLD_VALUE (32-bit NEO threshold)
// 0x04 -> WINDOW_TIMEOUT (32-bit samples with no detections before ending seizure)
// 0x05 -> TRANSITION_COUNT (32-bit number of detections needed to start seizure)
wire [31:0] ep00wire;
wire [31:0] ts_in_lo_w;
wire [31:0] ts_in_hi_w;
wire [31:0] threshold_value_w;
wire [31:0] window_timeout_w;
wire [31:0] transition_count_w;

okWireIn ep00 (.okHE(okHE_ri), .ep_addr(8'h00), .ep_dataout(ep00wire));
okWireIn wi01 (.okHE(okHE_ri), .ep_addr(8'h01), .ep_dataout(ts_in_lo_w));
okWireIn wi02 (.okHE(okHE_ri), .ep_addr(8'h02), .ep_dataout(ts_in_hi_w));
okWireIn wi03 (.okHE(okHE_ri), .ep_addr(8'h03), .ep_dataout(threshold_value_w));
okWireIn wi04 (.okHE(okHE_ri), .ep_addr(8'h04), .ep_dataout(window_timeout_w));
okWireIn wi05 (.okHE(okHE_ri), .ep_addr(8'h05), .ep_dataout(transition_count_w));

/// Pipes

// Instantiate FP PipeIn (ok macro)
wire fifoInWrite_ri;
reg  fifoInRead_ri = 1'b0;
wire fifoInFull_ro, fifoInEmpty_ro; 
wire [31:0] fifoInDataIn_w, fifoInDataOut_ro;

okPipeIn pipe80(
    .okHE(okHE_ri),                 // read header in (driven by okHost from PC syscall) 
    .okEH(okEHx_ro[0*65 +: 65]),    // pipe/output to workable endpoint array
    .ep_addr(8'h80),                // configure endpoint
    .ep_write(fifoInWrite_ri),      // pipe sends valid signal to FIFO_in 
    .ep_dataout(fifoInDataIn_w)     // pipe sends over data
);

// Instantiate PF PipeOut (ok macro)
wire fifoOutRead_ro, fifoOutFull_ro, fifoOutEmpty_ro;
wire [31:0] fifoOutDataOut_ro;
wire [31:0] fifoOutDataIn_w;
reg         fifoOutWr_ro    = 1'b0;

okPipeOut pipeA0(
    .okHE(okHE_ri),                 // read header in (driven by okHost from PC syscall) 
    .okEH(okEHx_ro[1*65 +: 65]),    // pipe/output to workable endpoint array
    .ep_addr(8'hA0),                // configure endpoint
    .ep_read(fifoOutRead_ro),       // pipe sends valid signal to FIFO_out
    .ep_datain(fifoOutDataOut_ro)   // pipe sends over data
);

// CTRL Configuration (WireIn endpoints)
reg reset_ro = 1'b0;
reg [63:0] timestamp_cfg_ro = 64'd0; // 8 bytes (CTRL)
reg [31:0] threshold_value_ro = 32'd25000;  // Default NEO threshold
reg [31:0] window_timeout_ro = 32'd200;      // Default window timeout
reg [31:0] transition_count_ro = 32'd30;     // Default transition count

always @ (posedge okClk) begin
    reset_ro          <= ep00wire[31];
    timestamp_cfg_ro  <= {ts_in_hi_w, ts_in_lo_w};
    // Register threshold parameters from WireIn (with defaults if not set)
    threshold_value_ro  <= threshold_value_w != 32'd0 ? threshold_value_w : 32'd25000;
    window_timeout_ro   <= window_timeout_w != 32'd0 ? window_timeout_w : 32'd200;
    transition_count_ro <= transition_count_w != 32'd0 ? transition_count_w : 32'd30;
end

// -------------------------------------------- //
// FIFO Logic                                   //
// -------------------------------------------- //

// Hard backstop: never let a write reach the FIFO while full, regardless of
// how fast the host bursts. With the drain fix below this should never
// actually engage in steady state, but it turns a would-be pointer
// corruption into a bounded, detectable drop instead.
wire fifoInWriteGated_w = fifoInWrite_ri && !fifoInFull_ro;

// Instantiate FIFO In
fifo_generator_0 fifoIn (
    .clk (okClk),               // in (global okHost CLK)
    .srst (reset_ro),           // in (okReset configurable 0x00 wire signal)
    // write in from pipe (PC syscall)
    .din (fifoInDataIn_w),      // in (data from pipe80 handled by okHost)
    .wr_en (fifoInWriteGated_w),// in (signal from pipe80 for FIFO wr, full-gated)
    // edge signals
    .full (fifoInFull_ro),      // out (gates wr_en above)
    .empty (fifoInEmpty_ro),    // out (used by CTL to wait for FIFO data)
    // read out
    .dout (fifoInDataOut_ro),   // out (FIFO data out on fifoInRead_ri request)
    .rd_en (fifoInRead_ri)      // in (CTL inquery for FIFO next cycle data out)
);

// Instantiate FIFO Out
fifo_generator_0 fifoOut (
    .clk (okClk),               // in (global okHost CLK)
    .srst (reset_ro),           // in (okReset configurable 0x00 wire signal)
    // write in from datapath
    .din (fifoOutDataIn_w),     // in (data from datapath)
    .wr_en (fifoOutWr_ro),      // in (signal from CTL)
    // edge signals 
    .full (fifoOutFull_ro),     // out (FIFO signal, not used -> safe)
    .empty (fifoOutEmpty_ro),   // out (FIFO signal, not used -> safe)
    // read out to pipe (from PC syscall)
    .dout (fifoOutDataOut_ro),  // out (FIFO data out on fifoOutRead_ro request)
    .rd_en (fifoOutRead_ro)     // in (okHost inquery for FIFO next cycle data out)
);

// -------------------------------------------- //
// Datapath pipeline                            //
// -------------------------------------------- //



reg         dp_data_valid_ro = 1'b0;
reg [15:0]  dp_data_ro       = 16'd0;
reg [5:0]   dp_channel_id_ro = 6'd0;

wire        dp_output_valid_w;
wire [31:0] dp_output_timestamp_w;
wire        dp_output_event_w;
wire [5:0]  dp_output_channel_w;

// debug (unused)
wire [16:0] dp_neo_debug_w;
wire        dp_neo_debug_valid_w;
wire        dp_detected_debug_w;

// Instantiate continuous datapath with configurable parameters
datapath seizure_detection (
    .clk             (okClk),
    .rst_n           (~reset_ro),
    .threshold_value (threshold_value_ro),
    .window_timeout  (window_timeout_ro),
    .transition_count(transition_count_ro),
    .data_valid      (dp_data_valid_ro),
    .data            (dp_data_ro),
    .channel_id      (dp_channel_id_ro),
    .output_valid    (dp_output_valid_w),
    .output_timestamp(dp_output_timestamp_w),
    .output_event    (dp_output_event_w),
    .output_channel  (dp_output_channel_w),
    .neo_debug       (dp_neo_debug_w),
    .neo_debug_valid (dp_neo_debug_valid_w),
    .detected_debug  (dp_detected_debug_w)
);

// Input handling: pull 32-bit words from FIFO in and present as
// one 16-bit sample + 6-bit channel id to the datapath.
// Layout (per word from host):
//   [15:0]  : sample (ADC code)
//   [21:16] : channel_id (0-31)
//   other bits are currently unused.

// Streaming drain: the FIFO has a fixed 1-cycle read latency, but that is
// latency, not a per-word stall -- a new rd_en can be issued every cycle
// while data is available, pipelining requests to sustain 1 word/cycle.
// fifo_in_rd_pending_ro remembers whether *last* cycle's request is the one
// landing on fifoInDataOut_ro *this* cycle, since dout is not readable until
// one cycle after the request that produced it.
reg fifo_in_rd_pending_ro = 1'b0;

always @ (posedge okClk) begin
    if (reset_ro) begin
        fifoInRead_ri          <= 1'b0;
        fifo_in_rd_pending_ro  <= 1'b0;
        dp_data_valid_ro       <= 1'b0;
        dp_data_ro             <= 16'd0;
        dp_channel_id_ro       <= 6'd0;
    end else begin
        fifoInRead_ri         <= !fifoInEmpty_ro;
        fifo_in_rd_pending_ro <= fifoInRead_ri;

        dp_data_valid_ro <= fifo_in_rd_pending_ro;
        if (fifo_in_rd_pending_ro) begin
            dp_data_ro       <= fifoInDataOut_ro[15:0];
            dp_channel_id_ro <= fifoInDataOut_ro[21:16];
        end
    end
end

// Output handling: encode seizure events into fifoOut.
// Only outputs seizure start/end events when datapath detects them.
// Each 32-bit word format (2-bit event_code to detect stale/idle):
//   [31:30] : event_code (2'b00 = none/idle, 2'b01 = seizure start, 2'b10 = seizure end)
//   [29:25] : channel_id (0-31, 5 bits)
//   [24:0]  : lower 25 bits of datapath output_timestamp

// DEBUG: Test counter for bypass mode
reg [5:0]  debug_test_channel = 6'd0;
reg [25:0] debug_test_timestamp = 26'd0;
reg [15:0] debug_write_delay = 16'd0;

// Edge detection: Only output events when state changes (transitions)
// Track previous state to detect rising edges of output_valid
reg prev_output_valid_ro = 1'b0;
reg [4:0] prev_output_channel_ro = 5'd0;
reg [1:0] prev_output_event_code_ro = 2'b00;

// Track last event per channel to prevent repeated events of the same type
reg [1:0] last_event_per_channel [0:31];  // Last event code per channel (00=idle, 01=start, 10=end)

// Detect edge: valid goes from 0->1 (rising edge) AND this is a different event than last for this channel
wire valid_rising = dp_output_valid_w && !prev_output_valid_ro;
wire [1:0] event_code_current = dp_output_event_w ? 2'b01 : 2'b10;
wire [4:0] current_channel = dp_output_channel_w[4:0];
wire event_different = (last_event_per_channel[current_channel] != event_code_current);
wire has_edge = valid_rising && event_different;  // Only true on actual state transitions

// Compute 2-bit event code: 00=idle, 01=start, 10=end
// Only set to 01/10 when there's an edge, otherwise keep as 00 (idle)
wire [1:0] event_code_w = has_edge ? event_code_current : 2'b00;

// Latch event data when there's an edge to ensure stable data during FIFO write
reg [1:0]  latched_event_code_ro = 2'b00;
reg [4:0]  latched_channel_ro = 5'd0;
reg [24:0] latched_timestamp_ro = 25'd0;

always @ (posedge okClk) begin
    if (reset_ro) begin
        prev_output_valid_ro <= 1'b0;
        prev_output_channel_ro <= 5'd0;
        prev_output_event_code_ro <= 2'b00;
        latched_event_code_ro <= 2'b00;
        latched_channel_ro <= 5'd0;
        latched_timestamp_ro <= 25'd0;
        // Reset last event per channel to idle
        for (int ch = 0; ch < 32; ch++) begin
            last_event_per_channel[ch] <= 2'b00;
        end
    end else begin
        // Update previous state for next cycle edge detection
        prev_output_valid_ro <= dp_output_valid_w;
        if (dp_output_valid_w) begin
            prev_output_channel_ro <= current_channel;
            prev_output_event_code_ro <= event_code_current;
        end
        
        // Latch event data only when there's an edge (state change)
        if (has_edge) begin
            latched_event_code_ro <= event_code_current;
            latched_channel_ro <= current_channel;
            latched_timestamp_ro <= dp_output_timestamp_w[24:0];
            // Update last event for this channel to prevent repeated events
            last_event_per_channel[current_channel] <= event_code_current;
        end else begin
            // No edge: keep output as idle (00) - don't update latched values
            // This ensures we only see edges/changes, not continuous states
            latched_event_code_ro <= 2'b00;
        end
    end
end

// Output data assignment - use latched values to ensure stable data
// Format: [31:30] = event_code (2 bits), [29:25] = channel_id (5 bits), [24:0] = timestamp (25 bits)
// IMPORTANT: Concatenation {a, b, c} puts 'a' in MSB positions
// So {2'b01, 5'b00000, 25'd1} = 32'b01_00000_0000000000000000000000001 = 0x40000001
assign fifoOutDataIn_w = {latched_event_code_ro,  // [31:30] = latched event_code (01=start, 10=end, 00=idle)
                          latched_channel_ro,     // [29:25] = latched channel (5 bits)
                          latched_timestamp_ro};   // [24:0] = latched timestamp (25 bits)

always @ (posedge okClk) begin
    fifoOutWr_ro <= 1'b0;
    
    if (reset_ro) begin
        debug_test_channel <= 6'd0;
        debug_test_timestamp <= 26'd0;
        debug_write_delay <= 16'd0;
    end else begin
        if (has_edge && !fifoOutFull_ro) begin
            // Only write to output FIFO when there's a state change (edge detected)
            // latched_event_code_ro will be 01 or 10 (never 00) when has_edge is true
            fifoOutWr_ro <= 1'b1;
        end
    end
end

// -------------------------------------------- //
// LEDs Test                                    //
// -------------------------------------------- //

function [7:0] xem7310_led;
input [7:0] a;
integer i;
begin
    for(i=0; i<8; i=i+1) begin: u
        xem7310_led[i] = (a[i]==1'b1) ? (1'b0) : (1'bz);
    end
end
endfunction

assign led = xem7310_led(ep00wire);

endmodule
