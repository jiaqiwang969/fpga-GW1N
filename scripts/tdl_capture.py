#!/usr/bin/env python3
"""
简单的 TDL 诊断数据抓取与统计脚本。

使用方法（在 fpga-GW1N 目录下）：

  python scripts/tdl_capture.py /dev/cu.usbserial-0001 115200 5

参数：
  argv[1] : 串口设备名，例如 /dev/cu.usbserial-0001
  argv[2] : 波特率，例如 115200
  argv[3] : 采集时长（秒），例如 5

脚本会：
  - 只解析以 "T=" 开头的行，其它行全部忽略；
  - 将 FF 解析为 16 进制的 0..255；
  - 统计各个值出现次数，并打印最小/最大值和直方图。
"""

import sys
import time
from collections import Counter

import serial


def main() -> None:
    if len(sys.argv) < 4:
        print("Usage: tdl_capture.py PORT BAUD DURATION_SEC")
        print("Example: tdl_capture.py /dev/cu.usbserial-0001 115200 5")
        sys.exit(1)

    port = sys.argv[1]
    baud = int(sys.argv[2])
    duration = float(sys.argv[3])

    print(f"[TDL] Open {port} @ {baud} baud, duration={duration}s")
    ser = serial.Serial(port, baud, timeout=0.5)

    counts: Counter[int] = Counter()
    total_lines = 0
    start = time.time()

    try:
        while time.time() - start < duration:
            line = ser.readline()
            if not line:
                continue

            try:
                text = line.decode(errors="replace").strip()
            except Exception:
                continue

            total_lines += 1

            if not text.startswith("T="):
                # 忽略非诊断行或半截数据
                continue

            # 解析 "T=FF"
            body = text[2:].strip()
            if len(body) < 1 or len(body) > 2:
                continue

            try:
                value = int(body, 16)
            except ValueError:
                continue

            counts[value] += 1
    finally:
        ser.close()

    print(f"[TDL] total lines read: {total_lines}")
    if not counts:
        print("[TDL] no valid T=FF lines captured.")
        return

    vals = sorted(counts.keys())
    vmin, vmax = vals[0], vals[-1]
    print(f"[TDL] fine_code range: {vmin} (0x{vmin:02X}) .. {vmax} (0x{vmax:02X})")
    print("[TDL] histogram (value: count):")
    for v in vals:
        print(f"  {v:3d} (0x{v:02X}): {counts[v]}")


if __name__ == "__main__":
    main()

