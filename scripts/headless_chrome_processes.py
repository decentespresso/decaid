#!/usr/bin/env python3
import ctypes
import errno
import os
from pathlib import Path
import re
import struct
import subprocess
import sys


def darwin_environment(data):
    if len(data) < 4:
        raise ValueError("truncated process argument header")
    argc = struct.unpack_from("i", data)[0]
    if argc < 0:
        raise ValueError("invalid process argument count")
    offset = data.index(b"\0", 4) + 1
    while offset < len(data) and data[offset] == 0:
        offset += 1
    for _ in range(argc):
        offset = data.index(b"\0", offset) + 1
    return data[offset:].split(b"\0")


def environment_for(pid):
    if sys.platform.startswith("linux"):
        return Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
    if sys.platform != "darwin":
        raise RuntimeError(f"unsupported process environment platform: {sys.platform}")
    libc = ctypes.CDLL(None, use_errno=True)
    mib = (ctypes.c_int * 3)(1, 49, pid)
    size = ctypes.c_size_t()
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))
    data = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, data, ctypes.byref(size), None, 0) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))
    return darwin_environment(data.raw[:size.value])


def process_exists(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    status = subprocess.run(
        ["ps", "-p", str(pid), "-o", "stat="],
        capture_output=True, text=True, timeout=5,
    ).stdout.strip()
    return bool(status) and not status.startswith("Z")


def owned_processes(token, own_group):
    if not re.fullmatch(r"run-[1-9][0-9]*-[A-Za-z0-9]{8}", token):
        raise ValueError("invalid managed run token")
    marker = f"DECAID_CHROME_RUN_TOKEN={token}".encode()
    result = subprocess.run(
        ["ps", "-u", str(os.geteuid()), "-o", "pid=,pgid=,uid=,stat="],
        check=True, capture_output=True, text=True, timeout=10,
    )
    found = []
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) != 4:
            raise ValueError("invalid process listing")
        pid, group, user = map(int, fields[:3])
        if (
            user != os.geteuid()
            or pid == os.getpid()
            or group == own_group
            or fields[3].startswith("Z")
        ):
            continue
        try:
            environment = environment_for(pid)
        except OSError as error:
            if error.errno in (errno.ESRCH, errno.ENOENT) or not process_exists(pid):
                continue
            raise RuntimeError(f"cannot inspect process {pid}: {error.strerror}") from error
        except ValueError as error:
            if not process_exists(pid):
                continue
            raise RuntimeError(f"cannot parse process {pid} environment") from error
        if marker in environment:
            found.append((pid, group))
    return found


def main(args):
    try:
        if args == ["--check"]:
            environment_for(os.getpid())
            return 0
        if len(args) != 2:
            raise ValueError("expected managed run token and wrapper process group")
        for pid, group in owned_processes(args[0], int(args[1])):
            print(pid, group)
        return 0
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(f"headless Chrome process scan failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
