#!/usr/bin/env python3
"""
DE1 firmware upload over serial.

Usage:
    python3 fw_upload.py <serial_port> <firmware_file> [--batch N] [--pause MS]

Options:
    --batch N     Send N chunks before pausing (default: 8)
    --pause MS    Pause duration in ms after each batch (default: 100)

Example:
    python3 fw_upload.py /dev/cu.usbmodem1234 firmware.bin
    python3 fw_upload.py /dev/cu.usbmodem1234 firmware.bin --batch 4 --pause 200
    python3 fw_upload.py /dev/cu.usbmodem1234 firmware.bin --batch 16 --pause 50
"""

import sys
import time
import threading
import serial


def encode_u24(value: int) -> bytes:
    """Encode an integer as a 3-byte big-endian unsigned value."""
    return bytes([
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF,
    ])


def to_hex(data: bytes) -> str:
    """Convert bytes to hex string (no separators)."""
    return data.hex()


def send_command(port: serial.Serial, cmd: str):
    """Send a serial command string followed by newline."""
    line = f"{cmd}\n".encode()
    port.write(line)
    port.flush()


def send_fw_erase(port: serial.Serial):
    """Send firmware erase request via <I> (fwMapRequest) endpoint."""
    payload = bytes([0x00, 0x00, 0x01, 0x01, 0xFF, 0xFF, 0xFF])
    send_command(port, f"<I>{to_hex(payload)}")


def send_fw_verify(port: serial.Serial):
    """Send firmware verify/map request via <I> endpoint."""
    payload = bytes([0x00, 0x00, 0x00, 0x01, 0xFF, 0xFF, 0xFF])
    send_command(port, f"<I>{to_hex(payload)}")


def read_until_prompt(port: serial.Serial, timeout: float = 2.0) -> str:
    """Read from port until no more data arrives."""
    data = b""
    deadline = time.time() + timeout
    while time.time() < deadline:
        waiting = port.in_waiting
        if waiting > 0:
            data += port.read(waiting)
            deadline = time.time() + 0.1  # reset short timeout on activity
        else:
            time.sleep(0.01)
    return data.decode("utf-8", errors="replace")


def upload_firmware(port: serial.Serial, fw_data: bytes, batch_size: int, pause_s: float):
    """Upload firmware in 16-byte chunks via <F> (writeToMMR) endpoint.

    Sends batch_size chunks, then pauses for pause_s to let the machine
    drain its UART buffer and complete SPI flash writes.
    """
    total = len(fw_data)
    chunk_num = 0
    for i in range(0, total, 16):
        chunk = fw_data[i:i + 16]
        chunk_len = len(chunk)
        address = encode_u24(i)

        packet = bytes([chunk_len]) + address + chunk
        send_command(port, f"<F>{to_hex(packet)}")
        chunk_num += 1

        # Pause after every batch to let machine process
        if chunk_num % batch_size == 0:
            time.sleep(pause_s)

        pct = min(i / total * 100, 100)
        print(f"\r  {pct:5.1f}% ({i}/{total} bytes)", end="", flush=True)

    print(f"\r  100.0% ({total}/{total} bytes)")


def reader_thread(port: serial.Serial, stop_event: threading.Event):
    """Background thread to print incoming serial data (for debugging)."""
    while not stop_event.is_set():
        try:
            waiting = port.in_waiting
            if waiting > 0:
                data = port.read(waiting)
                # Don't print during upload to avoid clutter
            else:
                time.sleep(0.05)
        except Exception:
            break


def main():
    args = sys.argv[1:]
    batch_size = 8
    pause_ms = 100

    if "--batch" in args:
        idx = args.index("--batch")
        batch_size = int(args[idx + 1])
        args.pop(idx + 1)
        args.pop(idx)
    if "--pause" in args:
        idx = args.index("--pause")
        pause_ms = int(args[idx + 1])
        args.pop(idx + 1)
        args.pop(idx)

    if len(args) != 2:
        print(__doc__.strip())
        sys.exit(1)

    port_name = args[0]
    fw_path = args[1]
    pause_s = pause_ms / 1000.0

    with open(fw_path, "rb") as f:
        fw_data = f.read()

    total_chunks = (len(fw_data) + 15) // 16
    total_batches = (total_chunks + batch_size - 1) // batch_size
    est_time = total_batches * pause_s + total_chunks * 0.004
    print(f"Firmware: {fw_path} ({len(fw_data)} bytes, {total_chunks} chunks)")
    print(f"Port: {port_name}")
    print(f"Mode: {batch_size} chunks per batch, {pause_ms}ms pause between batches")
    print(f"Estimated time: ~{est_time:.0f}s")

    port = serial.Serial(
        port=port_name,
        baudrate=115200,
        bytesize=serial.EIGHTBITS,
        parity=serial.PARITY_NONE,
        stopbits=serial.STOPBITS_ONE,
        timeout=1,
        write_timeout=5,
    )

    print()

    print("1. Requesting sleep state...")
    send_command(port, "<B>00")
    time.sleep(2)

    if port.in_waiting:
        port.read(port.in_waiting)

    # Step 2: Erase firmware
    print("2. Erasing firmware...")
    send_fw_erase(port)
    print("   Waiting 10 seconds for erase to complete...")
    for i in range(10, 0, -1):
        print(f"   {i}...", end=" ", flush=True)
        time.sleep(1)
    print()

    if port.in_waiting:
        resp = port.read(port.in_waiting)
        print(f"   Erase response: {resp}")

    # Step 3: Upload firmware
    print(f"3. Uploading firmware ({len(fw_data)} bytes)...")
    t0 = time.time()
    upload_firmware(port, fw_data, batch_size, pause_s)
    elapsed = time.time() - t0
    print(f"   Upload completed in {elapsed:.1f}s")

    print("4. Sending verify request...")
    send_fw_verify(port)

    resp = read_until_prompt(port, timeout=3.0)
    if resp:
        print(f"   Response: {resp.strip()}")

    print("\nDone!")
    port.close()


if __name__ == "__main__":
    main()
