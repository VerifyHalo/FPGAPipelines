# NEO Seizure Detection

Run this command to generate 1 minute of synthetic data with seizures:

```bash 
python3 run_tests.py --bitfile new.bit --log test_output.txt
```

## Pipeline
The FPGA (`new.bit`) receives neural data through PipeIn endpoint 0x80. The data is sent in chunks:


| Component | Value |
|-----------|-------|
| Channels per chunk | 32 |
| Samples per channel per chunk | 128 |
| Total samples per chunk | 4,096 (32 × 128) |
| Bytes per sample | 4 (32-bit word) |
| Total bytes per chunk | 16,384 |
| Words per chunk | 4,096 |

Data is interleaved by channel within each chunk:

```
  Word 0:    Channel 0, Sample 0
  Word 1:    Channel 0, Sample 1
  Word 2:    Channel 0, Sample 2
  ...
  Word 127:  Channel 0, Sample 127
  Word 128:  Channel 1, Sample 0
  Word 129:  Channel 1, Sample 1
  ...
  Word 4095: Channel 31, Sample 127
```

Chunks are sent sequentially via `WriteToPipeIn()`.

---

### Data

Look `generate_data_intan16()` from `synthetic.py`. `synthetic.py` is copied over from the Intan RHX GUI. I therefore further assume the incoming data format is valid and justifyable.

1. Electrode 16-bit Intan-style ADC codes
   - Range: 0 to 65,535
   - Mid-point (zero voltage): 32,768
   - `code16 = round(voltage_µV / 0.195) + 32768`
2. Sample Rate: 1k Hz (1 sample per millisecond)

---

### Seizure

We manually inject the seizure events:

   - Random probability-based initiation (currently 1% chance per second per channel)
   - 6 seconds fixed per seizure event
   - Sine wave at 2.5 Hz with 500 µV amplitude

---

### FPGA Processing

The Verilog design implements `First.sv` to handle the peripheral communications with the board and `datapath.sv`, the clock-independant seizure detection processing element.

The FPGA (`First.sv`) processes the data as follows:

1. OK generates internal okClk we reuse across all the pipeline.
1. Data arrives via PipeIn (0x80) goes to FIFO In (32 bits width, 1024 entries depth => 4KB capacity).
3. Extract:
   - `dp_data[15:0]` = ADC sample (16 bits)
   - `dp_channel_id[5:0]` = Channel ID from bits [21:16]
4. Sample is then sent to `datapath.sv` in parallel per channel.

---

### Datapath

The `datapath.sv` module implements a 3-stage pipelined seizure detection algorithm:

Stage 0: Sample History Collection
- Maintains per-channel sliding window of 3 consecutive samples
- Each of 32 channels has independent sample history
- Waits for 3 samples before computing NEO
- Best processing time tested

Stage 1: NEO Computation & Threshold
- NEO Formula: `ψ[n] = x[n]² - x[n-1] × x[n+1]`
  - Centers samples around zero (subtracts 32768)
  - Computes absolute value of NEO result
- Threshold Comparison: `|NEO| > threshold_value`
- Outputs binary detection signal per sample

Stage 2: Gating State Machine
- Two States: `NORMAL` OR `SEIZURE` (per channel)
- NORMAL to SEIZURE: Requires `transition_count` consecutive detections
- SEIZURE to NORMAL: After `window_timeout` samples with no detections
- Each event includes: channel ID, timestamp, and event type (start/end) bouding `SEIZURE` events.

Thus, pipeline latency: 3 clock cycles.

---

### Configuration Parameters

Before sending data, these parameters are configured:

| WireIn Address | Parameter | Default | Description |
|----------------|-----------|---------|-------------|
| 0x00           | Reset     | -       | Bit 31: Reset (pulsed) |
| 0x01           | TS_LO     | -       | Timestamp lower 32 bits |
| 0x02           | TS_HI     | -       | Timestamp upper 32 bits |
| 0x03           | Threshold | 25000   | NEO threshold value |
| 0x04           | Window Timeout | 200 | Samples with no detections before ending seizure |
| 0x05           | Transition Count | 30 | Number of detections needed to start seizure |

---

### Response 

When `datapath.sv` detects a seizure state transition, it outputs:
- `output_valid`: asserted for one clock cycle
- `output_event`: 1 = seizure start, 0 = seizure end  
- `output_channel`: channel ID (0-31)
- `output_timestamp`: sample timestamp

Then `First.sv` does:
2. Formats into 32-bit word:
   - `[31:30]`: event_code (2'b01=start, 2'b10=end, 2'b00=idle)
   - `[29:25]`: channel_id (5 bits)
   - `[24:0]`: timestamp (25 bits, lower bits of datapath timestamp)
3. Writes encoded event to FIFO Out (32-bit width, 1024 depth)
4. PipeOut 0xA0: Reads from FIFO Out and sends to PC via USB

The PC (`run_tests.py`) reads events from PipeOut 0xA0 and logs them with channel, timestamp, and event type.

---

### Output

See `run_halo_log.txt` for outputs.

---

## Design Verification

Unit tests live in `sim/`. Run without an FPGA or Xilinx tools:

```bash
cd sim
make sim          # compile + run all tests
make waves        # open waveform in GTKWave
```

A behavioral `fifo_generator_0.sv` stub replaces the Xilinx FIFO IP for simulation. SVA concurrent assertions (`sim/datapath_assertions.sv`) are provided separately for Questa or Vivado sim.

---

### Tested Edge Cases

#### TEST 1. Flat signal at midpoint produces no detection
A constant signal at 32768 (the ADC zero point) is sent to a channel. Because all three history samples are identical, NEO = x[n]² − x[n−1]·x[n+1] = 0. GOAL: Verify that baseline neural activity never triggers a false seizure event.

#### TEST 2. Single spike produces a known nonzero NEO value
Two midpoint samples fill the history, then one spike (32868, i.e. +100 µV centered) is injected followed by four trailing midpoints to flush the pipeline. Verifies the NEO formula is computed correctly: with neighbors at 0 and center at +100, NEO = 100² = 10,000 != 0.

#### TEST 3. State machine transitions NORMAL - SEIZURE
An alternating spike/midpoint pattern is used. Each spike sample produces NEO ≈ 53,824, well above the test threshold of 50. After `transition_count = 3` consecutive detections the FSM must fire `output_valid = 1` with `output_event = 1` on channel 0.

#### TEST 4. State machine transitions SEIZURE - NORMAL on timeout
Builds on TEST 3. First confirms seizure start fires (phase A), then sends 20 flat midpoint samples. Because NEO = 0 for a flat signal, `window_timeout = 5` samples without a detection causes the FSM to transition back to NORMAL.

#### TEST 5. Multi-channel isolation
Channels 0 and 1 are driven simultaneously (interleaved sample-by-sample). Channel 0 receives an alternating spike/mid pattern; channel 1 receives only midpoints. Verifies two things:
1. Ch0 correctly accumulates detections and fires a seizure start.
2. Ch1 never fires, confirming that per-channel state (history, counters, FSM) is fully independent.

#### TEST 6. No detection before three samples arrive (NEO window size)
A channel receives only two samples (extreme values: 0xFFFF and 0x0000) before the test ends. The NEO operator requires three consecutive samples to define x[n−1], x[n], x[n+1]. With `threshold = 1` and `transition_count = 1` (would fire immediately if NEO ran early), verifies that no event is generated while the history buffer is still filling.

#### TEST 7. Hard reset clears all per-channel state
A seizure is triggered on channel 0, then `rst_n` is asserted mid-seizure for four clock cycles and released. Fifteen flat midpoint samples are then sent. Verifies that no stale event fires after reset. Confirms that channel history, counters, FSM state, and pipeline registers are all cleared.

> **Bug found and fixed**: `neo_val` and `neo_abs` were absent from the reset block.

#### TEST 8. `output_valid` is a single-cycle pulse
Triggers a seizure start and monitors `output_valid` for 60 clock cycles. Counts the number of cycles `output_valid` is high. Verifies the count is lower-equal to 1.

#### TEST 9. NEO arithmetic at ADC rail values (overflow check)
The ADC range is 0–65535. Centered rail values are −32768 and +32767. The worst-case NEO product is 32767² ≈ 1.07 × 10⁹, which must fit in the 34-bit signed pipeline registers without wrapping. An alternating 65535/0 pattern is driven and seizure detection is verified — confirming the NEO multiply-and-subtract path does not silently overflow at extreme inputs.

#### TEST 10. `detection_counter` width mismatch
`detection_counter` is declared `[7:0]` (max 255) but `transition_count` is 32-bit. With `transition_count = 257` the required threshold is 256, which the 8-bit counter can never reach — it wraps to 0 at 256 and the seizure never fires regardless of how many detections occur. 150 spike/mid pairs are driven and `output_valid` is confirmed to never assert. **Known DUT bug**: `detection_counter` must be widened to match `transition_count`.

#### TEST 11. `continuous_counter` width mismatch
`continuous_counter` is declared `[15:0]` (max 65535) but `window_timeout` is 32-bit. With `window_timeout = 70000` the 16-bit counter wraps to 0 before reaching the timeout value, so `continuous_counter >= window_timeout` is never true and a seizure in progress can never end. The test triggers a seizure then drives 70,010 flat samples and confirms no seizure-end event fires. **Known DUT bug**: `continuous_counter` must be widened to at least 32 bits.

---

### Inline Assertion Monitors

contains 3 procedural monitors:

| Monitor | What it checks |
|---------|----------------|
| Pulse width | `output_valid` must not be held high for more than one consecutive clock cycle |
| Output channel range | `output_channel` must be < 32 whenever `output_valid` is asserted |
| Input channel range | `channel_id` must be < 32 whenever `data_valid` is asserted |

Print an `[ASSERT]` error line without stopping the simulation.
