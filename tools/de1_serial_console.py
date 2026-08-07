#!/usr/bin/env python3
"""
Interactive USB-serial console for DE1 / Bengle.

Mirrors the protocol used by `UnifiedDe1Transport` over the serial path:

  - Notification subscribe:    `<+X>` where X is the endpoint letter
  - Notification unsubscribe:  `<-X>`
  - Request state change:      `<B>NN` (NN = hex state byte)
  - Notification frames:       `[X]<hex_payload>` terminated by `[` or `\n`

Both DE1 and Bengle speak the same protocol over USB. Use the same script
for either; just point `--port` at the right serial device.

Usage:
    python3 de1_serial_console.py /dev/cu.usbmodem1234

Then at the `> ` prompt:
    sub state water shot         # subscribe to the most useful streams
    sub all                      # subscribe to state, water, shot, settings
    state idle                   # request idle state
    state 04                     # request espresso (raw hex)
    raw <+J>                     # send arbitrary command
    unsub all
    quit

Type `help` for a full command list.
"""

import argparse
import re
import sys
import threading
import time
from datetime import datetime

import serial

# Endpoint letter → human label. Mirrors `Endpoint` enum in
# lib/src/models/device/impl/de1/de1.models.dart.
ENDPOINTS = {
    "M": "shotSample",
    "N": "stateInfo",
    "Q": "waterLevels",
    "K": "shotSettings",
    "E": "readFromMMR",
    "I": "fwMapRequest",
    "B": "requestedState",
}

SUB_ALIASES = {
    "state": "N",
    "shot": "M",
    "shotsample": "M",
    "water": "Q",
    "waterlevels": "Q",
    "settings": "K",
    "shotsettings": "K",
    "mmr": "E",
    "fwmap": "I",
}
SUB_ALL = ["N", "Q", "M", "K"]

STATE_BY_NAME = {
    "sleep": 0x00,
    "goingtosleep": 0x01,
    "idle": 0x02,
    "busy": 0x03,
    "espresso": 0x04,
    "steam": 0x05,
    "hotwater": 0x06,
    "shortcal": 0x07,
    "selftest": 0x08,
    "longcal": 0x09,
    "descale": 0x0A,
    "fatalerror": 0x0B,
    "init": 0x0C,
    "norequest": 0x0D,
    "skipnext": 0x0E,
    "skiptonext": 0x0E,
    "hotwaterrinse": 0x0F,
    "flush": 0x0F,
    "steamrinse": 0x10,
    "refill": 0x11,
    "clean": 0x12,
    "bootloader": 0x13,
    "airpurge": 0x14,
    "schedidle": 0x15,
    "fwupgrade": 0x22,
}

STATE_NAMES = {v: k for k, v in STATE_BY_NAME.items() if k != "skiptonext" and k != "flush"}

SUBSTATE_NAMES = {
    0x00: "noState",
    0x01: "heatWaterTank",
    0x02: "heatWaterHeater",
    0x03: "stabilizeMixTemp",
    0x04: "preInfuse",
    0x05: "pour",
    0x06: "end",
    0x07: "steaming",
    0x08: "descaleInt",
    0x09: "descaleFillGroup",
    0x0A: "descaleReturn",
    0x0B: "descaleGroup",
    0x0C: "descaleSteam",
    0x0D: "cleanInit",
    0x0E: "cleanFillGroup",
    0x0F: "cleanSoak",
    0x10: "cleanGroup",
    0x11: "refill",
    0x12: "pausedSteam",
    0x13: "userNotPresent",
    0x14: "puffing",
}


# Matches a complete `[X]hex` frame followed by `[` (next frame) or newline.
# Mirrors the regex in `UnifiedDe1Transport._messagePattern`.
MESSAGE_RE = re.compile(rb"(\[[A-Z]\][0-9A-Fa-f\s]*?)(?=\[|\n)")


def ts():
    return datetime.now().strftime("%H:%M:%S.%f")[:-3]


def hex_to_bytes(s: str) -> bytes:
    s = re.sub(r"\s+", "", s)
    if len(s) % 2:
        raise ValueError(f"odd-length hex: {s!r}")
    return bytes.fromhex(s)


def parse_state(payload: bytes) -> str:
    if len(payload) < 2:
        return f"short state frame ({len(payload)} bytes)"
    state = payload[0]
    sub = payload[1]
    return (
        f"state=0x{state:02X} ({STATE_NAMES.get(state, '?')})"
        f"  sub=0x{sub:02X} ({SUBSTATE_NAMES.get(sub, '?')})"
    )


def parse_water(payload: bytes) -> str:
    if len(payload) < 4:
        return f"short water frame ({len(payload)} bytes)"
    level = int.from_bytes(payload[0:2], "big") / 256.0
    threshold = int.from_bytes(payload[2:4], "big") / 256.0
    return f"level={level:.2f}mm  threshold={threshold:.2f}mm"


def _u16(p: bytes, off: int) -> int:
    return int.from_bytes(p[off : off + 2], "big")


def parse_shot_sample(payload: bytes) -> str:
    if len(payload) < 19:
        return f"short shot frame ({len(payload)} bytes)"
    group_pressure = _u16(payload, 2) / (1 << 12)
    group_flow = _u16(payload, 4) / (1 << 12)
    mix_temp = _u16(payload, 6) / (1 << 8)
    head_temp = ((payload[8] << 16) + (payload[9] << 8) + payload[10]) / (1 << 16)
    set_mix = _u16(payload, 11) / (1 << 8)
    set_head = _u16(payload, 13) / (1 << 8)
    set_pressure = payload[15] / (1 << 4)
    set_flow = payload[16] / (1 << 4)
    frame = payload[17]
    steam_temp = payload[18]
    return (
        f"P={group_pressure:5.2f}bar(t={set_pressure:4.2f}) "
        f"F={group_flow:5.2f}ml/s(t={set_flow:4.2f}) "
        f"mix={mix_temp:6.2f}C(t={set_mix:6.2f}) "
        f"head={head_temp:6.2f}C(t={set_head:6.2f}) "
        f"frame={frame} steam={steam_temp}C"
    )


def parse_shot_settings(payload: bytes) -> str:
    if len(payload) < 9:
        return f"short shotsettings frame ({len(payload)} bytes)"
    target_group = _u16(payload, 7) / (1 << 8)
    return (
        f"steamBits=0x{payload[0]:02X} "
        f"steamT={payload[1]}C steamLen={payload[2]}s "
        f"waterT={payload[3]}C waterVol={payload[4]}ml waterLen={payload[5]}s "
        f"esprVol={payload[6]}ml groupT={target_group:.2f}C"
    )


PARSERS = {
    "N": ("state    ", parse_state),
    "Q": ("water    ", parse_water),
    "M": ("shot     ", parse_shot_sample),
    "K": ("settings ", parse_shot_settings),
}


class Reader(threading.Thread):
    """Background reader: drains the serial port, parses `[X]hex` frames."""

    def __init__(self, port: serial.Serial):
        super().__init__(daemon=True)
        self._port = port
        self._buf = b""
        self._stop = threading.Event()
        self._raw = False
        self._lock = threading.Lock()

    def stop(self):
        self._stop.set()

    def set_raw(self, raw: bool):
        with self._lock:
            self._raw = raw

    def run(self):
        while not self._stop.is_set():
            try:
                chunk = self._port.read(self._port.in_waiting or 1)
            except serial.SerialException as e:
                print(f"\n[{ts()}] serial error: {e}", file=sys.stderr)
                return
            if not chunk:
                continue
            self._buf += chunk
            self._drain()

    def _drain(self):
        # Discard junk before the first `[`, mirroring the Dart side.
        idx = self._buf.find(b"[")
        if idx < 0:
            self._buf = b""
            return
        if idx > 0:
            self._buf = self._buf[idx:]

        last_end = 0
        for m in MESSAGE_RE.finditer(self._buf):
            last_end = m.end()
            frame = m.group(1).decode("ascii", errors="replace").strip()
            self._handle_frame(frame)

        if last_end:
            self._buf = self._buf[last_end:].lstrip(b"\n")
        elif len(self._buf) > 4096:
            print(f"[{ts()}] buffer overflow, dropping {len(self._buf)} bytes")
            self._buf = b""

    def _handle_frame(self, frame: str):
        if len(frame) < 3 or frame[0] != "[" or frame[2] != "]":
            return
        letter = frame[1]
        hex_payload = frame[3:]
        try:
            payload = hex_to_bytes(hex_payload)
        except ValueError as e:
            print(f"[{ts()}] bad hex on [{letter}]: {e}")
            return

        with self._lock:
            raw = self._raw

        parser = PARSERS.get(letter)
        if parser:
            label, fn = parser
            print(f"[{ts()}] {label} {fn(payload)}")
            if raw:
                print(f"           raw=[{letter}]{hex_payload}")
        else:
            ep = ENDPOINTS.get(letter, "?")
            print(f"[{ts()}] {letter}({ep}) {hex_payload}")


def write_command(port: serial.Serial, text: str):
    line = (text + "\n").encode("ascii")
    port.write(line)
    port.flush()
    print(f"[{ts()}] >> {text}")


def resolve_endpoint_letters(args: list[str]) -> list[str]:
    if not args:
        raise ValueError("missing endpoint")
    if len(args) == 1 and args[0].lower() == "all":
        return SUB_ALL
    out = []
    for a in args:
        key = a.lower()
        if key in SUB_ALIASES:
            out.append(SUB_ALIASES[key])
        elif len(a) == 1 and a.upper() in ENDPOINTS:
            out.append(a.upper())
        else:
            raise ValueError(f"unknown endpoint: {a}")
    return out


def resolve_state(arg: str) -> int:
    key = arg.lower()
    if key in STATE_BY_NAME:
        return STATE_BY_NAME[key]
    try:
        v = int(arg, 16)
    except ValueError:
        raise ValueError(f"unknown state: {arg}")
    if not 0 <= v <= 0xFF:
        raise ValueError(f"state out of range: {arg}")
    return v


HELP = """\
Commands:
  sub <ep>...           Subscribe to endpoints. ep = state|water|shot|settings|mmr|fwmap|all
  unsub <ep>...         Unsubscribe.
  state <name|hex>      Request state change via <B>NN.
                        Names: sleep idle espresso steam hotwater hotwaterrinse
                               skipnext clean descale airpurge schedidle fwupgrade ...
  raw <text>            Send <text> verbatim (newline appended).
  rawnotify on|off      Also print raw hex of decoded frames.
  help                  This help.
  quit | exit | Ctrl-D  Quit (sends <-X> for the four common subscriptions first).
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("port", help="Serial port (e.g. /dev/cu.usbmodem1234, COM5)")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument(
        "--auto-sub",
        action="store_true",
        help="Subscribe to state/water/shot/settings on connect",
    )
    args = ap.parse_args()

    port = serial.Serial(
        port=args.port,
        baudrate=args.baud,
        bytesize=serial.EIGHTBITS,
        parity=serial.PARITY_NONE,
        stopbits=serial.STOPBITS_ONE,
        timeout=0.1,
        write_timeout=5,
    )

    print(f"Opened {args.port} @ {args.baud}. Type 'help' for commands.")

    reader = Reader(port)
    reader.start()

    if args.auto_sub:
        for letter in SUB_ALL:
            write_command(port, f"<+{letter}>")
            time.sleep(0.05)
        # Probe state so the first [N] arrives without a manual nudge —
        # same bootstrap as `_serialConnect` in unified_de1_transport.dart.
        write_command(port, "<B>02")

    try:
        while True:
            try:
                line = input("> ").strip()
            except EOFError:
                print()
                break
            if not line:
                continue
            parts = line.split()
            cmd = parts[0].lower()
            rest = parts[1:]

            try:
                if cmd in ("quit", "exit", "q"):
                    break
                elif cmd == "help":
                    print(HELP)
                elif cmd == "sub":
                    for letter in resolve_endpoint_letters(rest):
                        write_command(port, f"<+{letter}>")
                elif cmd == "unsub":
                    for letter in resolve_endpoint_letters(rest):
                        write_command(port, f"<-{letter}>")
                elif cmd == "state":
                    if len(rest) != 1:
                        print("usage: state <name|hex>")
                        continue
                    v = resolve_state(rest[0])
                    write_command(port, f"<B>{v:02X}")
                elif cmd == "raw":
                    if not rest:
                        print("usage: raw <text>")
                        continue
                    write_command(port, " ".join(rest))
                elif cmd == "rawnotify":
                    if len(rest) != 1 or rest[0].lower() not in ("on", "off"):
                        print("usage: rawnotify on|off")
                        continue
                    reader.set_raw(rest[0].lower() == "on")
                else:
                    print(f"unknown command: {cmd}. type 'help'.")
            except ValueError as e:
                print(f"error: {e}")
    finally:
        # Best-effort unsubscribe so the firmware stops streaming when we go.
        try:
            for letter in SUB_ALL:
                port.write(f"<-{letter}>\n".encode())
            port.flush()
        except Exception:
            pass
        reader.stop()
        reader.join(timeout=1.0)
        port.close()
        print("Closed.")


if __name__ == "__main__":
    main()
