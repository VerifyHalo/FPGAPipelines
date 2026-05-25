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

