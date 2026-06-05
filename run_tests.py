#!/usr/bin/env python3

import os
import sys
import argparse
import random
import time
from pathlib import Path

from synthetic import generate_data_intan16, NUM_CHANNELS

# -------------------------------------------------------------------------------------------------
# Import OK module (Copied over from Intan RHX Repository to support MacOS)
# -------------------------------------------------------------------------------------------------
ok_module_path = Path(__file__).resolve().parent / "ok.py"
if ok_module_path.exists():
    import importlib.util
    spec = importlib.util.spec_from_file_location("ok", ok_module_path)
    ok = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ok)
else:
    raise ImportError("ok.py not found")

# -------------------------------------------------------------------------------------------------
# Constants
# -------------------------------------------------------------------------------------------------
PIPE_IN_ADDR = 0x80
PIPE_OUT_ADDR = 0xA0
WIREIN_CTRL = 0x00
WIREIN_TS_LO, WIREIN_TS_HI = 0x01, 0x02
WIREIN_THRESHOLD, WIREIN_WINDOW_TIMEOUT, WIREIN_TRANSITION_COUNT = 0x03, 0x04, 0x05
SAMPLES_PER_CHUNK = 128 # const by Intan SDK
SAMPLE_SIZE_BYTES = 4 # const by Intan SDK
CHUNK_BYTES = NUM_CHANNELS * SAMPLES_PER_CHUNK * SAMPLE_SIZE_BYTES
MAX_EVENTS = 10000
EVENT_BUFFER_SIZE = MAX_EVENTS * SAMPLE_SIZE_BYTES
FIFO_OUT_DEPTH = 1024 # entries in FIFO Out (from First.sv)
DRAIN_BUFFER_SIZE = FIFO_OUT_DEPTH * SAMPLE_SIZE_BYTES  # bytes per drain read
DRAIN_INTERVAL = 50 # drain every N chunks to prevent FIFO Out overflow

def generate_synthetic_data_chunks(num_chunks=450, samples_per_channel=60000, seed=None, log_path=None):
    """Generate synthetic neural data chunks formatted for FPGA."""
    all_data_16 = generate_data_intan16(NUM_CHANNELS, samples_per_channel, 
                                        sample_rate=1000.0, enable_seizures=True)
    
    # Save raw data for visualization
    if log_path:
        inputs_dir = Path("inputs")
        inputs_dir.mkdir(exist_ok=True)
        log_base = Path(log_path).stem
        import numpy as np
        raw_data_file = inputs_dir / f"{log_base}_raw_data.npy"
        np.save(raw_data_file, all_data_16)
        print(f"[SAVE] Raw data saved to {raw_data_file} ({len(all_data_16)} samples, shape: {all_data_16.shape})")
    
    chunks = []
    for chunk_id in range(num_chunks):
        chunk_bytes = bytearray()
        for ch in range(NUM_CHANNELS):
            for sample_in_chunk in range(SAMPLES_PER_CHUNK):
                sample_idx = chunk_id * SAMPLES_PER_CHUNK + sample_in_chunk
                idx = ch * samples_per_channel + sample_idx
                code16 = int(all_data_16[idx]) if idx < len(all_data_16) else 32768
                word32 = (ch << 16) | code16
                chunk_bytes.extend(word32.to_bytes(4, byteorder='little'))
        chunks.append(bytes(chunk_bytes))
    return chunks, all_data_16

def ensure_multiple_of_16(data: bytes) -> bytes:
    """Ensure padded by multiple of 16 bytes (required for PipeIn)."""
    rem = len(data) % 16
    return data if rem == 0 else data + bytes(16 - rem)

def parse_seizure_events(output_file):
    """Parse START/END events from outputs file."""
    seizures = []
    if not output_file.exists():
        return seizures
    
    with open(output_file, 'r') as f:
        lines = f.readlines()
    
    start_time = None
    for line in lines:
        if '01 (START)' in line:
            # Extract timestamp: "01 (START) | 0000000000000000108 | ..."
            parts = line.split('|')
            if len(parts) >= 2:
                try:
                    start_time = int(parts[1].strip())
                except ValueError:
                    continue
        elif '02 (END  )' in line and start_time is not None:
            # Extract timestamp: "02 (END  ) | 0000000000000001444 | ..."
            parts = line.split('|')
            if len(parts) >= 2:
                try:
                    end_time = int(parts[1].strip())
                    seizures.append((start_time, end_time))
                    start_time = None
                except ValueError:
                    continue
    
    # Handle ongoing seizure (START without END)
    if start_time is not None:
        seizures.append((start_time, None))
    
    return seizures

def plot_raw_data(log_base, num_chunks):
    """Generate plots with seizure regions marked."""
    try:
        import numpy as np
        import matplotlib.pyplot as plt
    except ImportError:
        print("[PLOT] Skipping plots - matplotlib not available")
        return
    
    inputs_dir = Path("inputs")
    outputs_dir = Path("outputs")
    raw_data_file = inputs_dir / f"{log_base}_raw_data.npy"
    
    if not raw_data_file.exists():
        print(f"[PLOT] Raw data file not found: {raw_data_file}")
        return
    
    raw_data = np.load(raw_data_file)
    
    seizures_dir = Path("seizures")
    seizures_dir.mkdir(exist_ok=True)
    
    samples_sent = num_chunks * SAMPLES_PER_CHUNK
    duration_ms = samples_sent  # At 1 kHz: samples = milliseconds
    
    # Plot all 32 channels in blocks of 4, arranged in 3x3 grid
    num_blocks = (NUM_CHANNELS + 3) // 4  # 8 blocks for 32 channels
    fig = plt.figure(figsize=(20, 15))
    gs = fig.add_gridspec(3, 3, hspace=0.3, wspace=0.3)
    
    for block_idx in range(num_blocks):
        row = block_idx // 3
        col = block_idx % 3
        
        # Get channels for this block (4 channels per block)
        start_ch = block_idx * 4
        end_ch = min(start_ch + 4, NUM_CHANNELS)
        channels_in_block = list(range(start_ch, end_ch))
        
        # Create subplot grid for this block (4 channels stacked vertically)
        block_gs = gs[row, col].subgridspec(4, 1, hspace=0.1)
        
        for ch_idx, ch in enumerate(channels_in_block):
            # Create subplot for this channel
            ax_ch = fig.add_subplot(block_gs[ch_idx, 0])
            
            # Calculate start index for this channel
            channel_start_idx = ch * len(raw_data) // NUM_CHANNELS
            # Only plot the samples that were actually sent
            channel_data = raw_data[channel_start_idx:channel_start_idx + samples_sent]
            
            # Time in milliseconds (1 sample = 1ms at 1kHz)
            time_ms = np.arange(len(channel_data))
            
            # Plot the raw data
            ax_ch.plot(time_ms, channel_data, linewidth=0.3, alpha=0.7, color='blue')
            
            # Load and mark seizure regions
            output_file = outputs_dir / f"{log_base}_ch{ch}.txt"
            seizures = parse_seizure_events(output_file)
            
            # Draw semi-transparent rectangles for each seizure
            for start_ms, end_ms in seizures:
                if end_ms is None:
                    # Ongoing seizure - extend to end of plot
                    end_ms = duration_ms
                # Only shade if within plot range
                if start_ms < duration_ms:
                    end_ms_plot = min(end_ms, duration_ms)
                    ax_ch.axvspan(start_ms, end_ms_plot, 
                                 alpha=0.3, color='red', label='Seizure' if start_ms == seizures[0][0] else '')
            
            ax_ch.set_xlim(0, duration_ms)
            ax_ch.set_title(f'Channel {ch}', fontsize=9)
            if ch_idx == len(channels_in_block) - 1:  # Bottom channel in block
                ax_ch.set_xlabel('Time (ms)', fontsize=8)
            else:
                ax_ch.set_xticklabels([])
            ax_ch.set_ylabel('ADC', fontsize=7)
            ax_ch.grid(True, alpha=0.3)
            if seizures:
                ax_ch.legend(loc='upper right', fontsize=6)
    
    plt.tight_layout()
    plot_file = seizures_dir / f"{log_base}_raw_inputs.png"
    plt.savefig(plot_file, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"[PLOT] Saved plot to {plot_file}")

def main():
    p = argparse.ArgumentParser(description="Test seizure detection on Opal Kelly FPGA")
    # FPGA Configuration
    p.add_argument("--bitfile", "-f", type=str, default=None, help="Path to .bit file")
    # Synthetic Data Configuration
    p.add_argument("--seed", type=int, default=None, help="Random seed")
    p.add_argument("--chunks", type=int, default=469, help="Number of chunks (default: 469)")
    p.add_argument("--samples", type=int, default=60000, help="Samples per channel (default: 60000)")
    # Datapath Configuration Parameters
    p.add_argument("--threshold", type=int, default=170000, help="NEO threshold (default: 150000)")
    p.add_argument("--window-timeout", type=int, default=300, help="Window timeout in samples (default: 300)")
    p.add_argument("--transition-count", type=int, default=50, help="Detections needed to start seizure (default: 50)")
    # Logging
    p.add_argument("--log", type=str, default="run_halo_log.txt", help="Log file path")
    args = p.parse_args()
    
    if args.seed is not None:
        random.seed(args.seed)
        try:
            import numpy as np
            np.random.seed(args.seed)
        except ImportError:
            pass
    
    # Clean outputs
    import shutil
    for dir_name in ["outputs", "inputs", "seizures"]:
        dir_path = Path(dir_name)
        if dir_path.exists():
            shutil.rmtree(dir_path)
        dir_path.mkdir(exist_ok=True)
    
    with open(args.log, "w", encoding="utf-8") as log:
        def log_msg(msg): print(msg); log.write(msg + "\n"); log.flush()
        
        log_msg("=" * 70)
        log_msg("Opal Kelly Seizure Detection Test")
        log_msg("=" * 70)

        
        # Generate data
        log_msg(f"\n[DATA] Generating {args.chunks} chunks...")
        chunks, raw_data = generate_synthetic_data_chunks(args.chunks, args.samples, args.seed, log_path=args.log)
        log_msg(f"[DATA] Generated {len(chunks)} chunks ({len(chunks) * CHUNK_BYTES} bytes)")
        
        # Initialize device
        dev = ok.okCFrontPanel()
        count = dev.GetDeviceCount()
        if count <= 0:
            log_msg("ERROR: No Opal Kelly devices found.")
            sys.exit(1)
        
        serial = dev.GetDeviceListSerial(0)
        rc = dev.OpenBySerial(serial)
        log_msg(f"[CONNECT] OpenBySerial({serial}) rc={rc}")
        if rc != ok.okCFrontPanel.NoError:
            log_msg(f"ERROR: OpenBySerial failed")
            sys.exit(1)
        
        # Configure FPGA
        if args.bitfile:
            rc = dev.ConfigureFPGA(os.path.abspath(args.bitfile))
            log_msg(f"[CONFIGURE] ConfigureFPGA rc={rc}")
            if rc != ok.okCFrontPanel.NoError:
                log_msg("ERROR: ConfigureFPGA failed")
                sys.exit(1)
        
        # Set parameters
        dev.SetWireInValue(WIREIN_THRESHOLD, args.threshold & 0xFFFFFFFF, 0xFFFFFFFF)
        dev.SetWireInValue(WIREIN_WINDOW_TIMEOUT, args.window_timeout & 0xFFFFFFFF, 0xFFFFFFFF)
        dev.SetWireInValue(WIREIN_TRANSITION_COUNT, args.transition_count & 0xFFFFFFFF, 0xFFFFFFFF)
        
        # Reset and timestamp
        ts = random.getrandbits(64) if args.seed is None else args.seed
        dev.SetWireInValue(WIREIN_TS_LO, ts & 0xFFFFFFFF, 0xFFFFFFFF)
        dev.SetWireInValue(WIREIN_TS_HI, (ts >> 32) & 0xFFFFFFFF, 0xFFFFFFFF)
        dev.SetWireInValue(WIREIN_CTRL, 0x8000_0000, 0xFFFFFFFF)
        dev.UpdateWireIns()
        dev.SetWireInValue(WIREIN_CTRL, 0x0000_0000, 0xFFFFFFFF)
        dev.UpdateWireIns()
        
        def check_fifo_overflow(chunk_idx):
            """Peek at FIFO Out. If it's full, abort."""
            buf = dev.ReadFromPipeOut(PIPE_OUT_ADDR, DRAIN_BUFFER_SIZE)
            words_peeked = len(buf) // SAMPLE_SIZE_BYTES
            if words_peeked >= FIFO_OUT_DEPTH:
                log_msg(f"ASSERTION FAILED: FIFO Out overflow detected at chunk {chunk_idx} "
                        f"({words_peeked} words >= FIFO depth {FIFO_OUT_DEPTH}).")
                sys.exit(1)

        # Send data and check FIFO Out every DRAIN_INTERVAL chunks
        log_msg(f"\n[SEND] Sending {len(chunks)} chunks to PipeIn 0x{PIPE_IN_ADDR:02X}...")
        for chunk_idx, chunk_data in enumerate(chunks):
            padded = ensure_multiple_of_16(chunk_data)
            status = dev.WriteToPipeIn(PIPE_IN_ADDR, bytearray(padded))
            if status < 0:
                log_msg(f"ERROR: WriteToPipeIn failed for chunk {chunk_idx}")
                sys.exit(1)
            if (chunk_idx + 1) % DRAIN_INTERVAL == 0:
                check_fifo_overflow(chunk_idx + 1)
                log_msg(f"  Sent {chunk_idx + 1}/{len(chunks)} chunks")
        log_msg(f"[DONE] Sent all {len(chunks)} chunks")

        time.sleep(0.5)

        # Read events (ToDo: In Parallel)
        log_msg(f"\n[READ] Reading events from PipeOut 0x{PIPE_OUT_ADDR:02X}...")
        out = dev.ReadFromPipeOut(PIPE_OUT_ADDR, EVENT_BUFFER_SIZE)
        bytes_read = len(out)
        log_msg(f"[DONE] Read {bytes_read} bytes ({bytes_read // 4} words)")

        # Parse events: [31:30]=event_code, [29:25]=channel_id, [24:0]=timestamp
        words = [int.from_bytes(out[i:i+4], byteorder="little")
                 for i in range(0, bytes_read, 4) if i + 4 <= bytes_read]
        
        # Group events by channel
        events_by_channel = {ch: [] for ch in range(32)}
        starts, ends, idle = 0, 0, 0
        
        for w in words:
            event_code = (w >> 30) & 0x3
            channel_id = (w >> 25) & 0x1F
            timestamp25 = w & 0x01FF_FFFF
            
            if event_code == 0x1:
                event_str, starts = "START", starts + 1
            elif event_code == 0x2:
                event_str, ends = "END  ", ends + 1
            else:
                event_str, idle = "IDLE ", idle + 1
            
            events_by_channel[channel_id].append((event_code, event_str, timestamp25, w))
        
        # Write per-channel
        log_base = Path(args.log).stem
        outputs_dir = Path("outputs")
        outputs_dir.mkdir(exist_ok=True)
        
        log_msg(f"\n" + "=" * 70)
        log_msg("OUTPUT")
        log_msg("=" * 70)
        
        for ch in range(32):
            if events_by_channel[ch]:
                # Count seizures
                seizure_count = sum(1 for event_code, _, _, _ in events_by_channel[ch] if event_code == 0x1)
                
                # Create logs
                ch_file = outputs_dir / f"{log_base}_ch{ch}.txt"
                with open(ch_file, "w", encoding="utf-8") as f:
                    f.write(f"Channel {ch} - Seizure Detection Events\n")
                    f.write("=" * 70 + "\n")
                    f.write("EventCode | Timestamp | RawWordHex\n")
                    f.write("-" * 70 + "\n")
                    for event_code, event_str, timestamp25, w in events_by_channel[ch]:
                        f.write(f"{event_code:02d} ({event_str}) | {timestamp25:019d} | 0x{w:08X}\n")
                    f.write("=" * 70 + "\n")
                    f.write(f"Total seizures: {seizure_count}\n")
                    f.write(f"Total events: {len(events_by_channel[ch])}\n")
                log_msg(f"  Channel {ch:2d}: {seizure_count:3d} seizures ({len(events_by_channel[ch]):5d} events) -> {ch_file}")
        
        # Summary in main log
        log_msg("=" * 70)
        log_msg(f"SUMMARY: {len(words)} words, {starts} starts, {ends} ends, {idle} idle")
        log_msg("=" * 70)
        
        if len(words) == 0:
            log_msg("\nWARNING: No events received")
        elif starts == 0 and ends == 0:
            log_msg("\nWARNING: All events are idle")
        else:
            log_msg(f"\nSUCCESS: {starts} starts, {ends} ends")
        
        # Generate plots
        log_msg(f"\n[PLOT] Generating plots from raw input data...")
        plot_raw_data(log_base, args.chunks)
    
    print(f"\nDONE! Log written to {args.log}")

if __name__ == "__main__":
    main()
