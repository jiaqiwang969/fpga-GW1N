#!/usr/bin/env python3
"""
互易频率计数器监视脚本（粗版本，仅使用 50MHz 尺子）

配套顶层: freq_recip_uart_ch0_top
UART 输出格式: "R=NNNNNN,CCCCCC\\r\\n"
  - NNNNNN: 周期数 N 的 16 进制（目前恒定 0x000190 = 400）
  - CCCCC C: 粗时间计数 C_coarse 的 16 进制（单位: 50MHz 周期，20ns）

频率估计:
  T_coarse ≈ C_coarse / 50e6
  f ≈ N / T_coarse

使用示例:
    python3 /Users/jqwang/131-出差回来后的集中整顿-1127/Frequency_counter/scripts/freq_recip_monitor.py
    python3 /Users/jqwang/131-出差回来后的集中整顿-1127/Frequency_counter/scripts/freq_recip_monitor.py \\
        --port /dev/cu.usbserial-0001
"""

from __future__ import annotations

import argparse
import sys
import time


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Monitor reciprocal counter (N-cycle) frequency over UART")
    p.add_argument(
        "-p",
        "--port",
        default="/dev/cu.usbserial-0001",
        help="Serial port device (default: %(default)s)",
    )
    p.add_argument(
        "-b",
        "--baud",
        type=int,
        default=115200,
        help="Baud rate (default: %(default)s)",
    )
    p.add_argument(
        "--clk",
        type=float,
        default=50_000_000.0,
        help="Reference clock frequency in Hz (default: %(default)s)",
    )
    return p.parse_args()


def main() -> int:
    try:
        import serial  # type: ignore
    except Exception as exc:
        sys.stderr.write(
            f"ERROR: pyserial not installed: {exc}\n"
            "Install it inside your venv with:\n"
            "    pip install pyserial\n"
        )
        return 1

    args = parse_args()

    try:
        ser = serial.Serial(args.port, args.baud, timeout=1.0)
    except Exception as exc:
        sys.stderr.write(f"ERROR: failed to open serial port {args.port}: {exc}\n")
        return 1

    clk_hz = float(args.clk)
    print(
        f"Opened {args.port} @ {args.baud} baud "
        f"(ref clk = {clk_hz:.0f} Hz). Press Ctrl+C to stop."
    )

    try:
        while True:
            line = ser.readline()
            if not line:
                continue
            try:
                text = line.decode("ascii", errors="replace").strip()
            except Exception:
                text = ""

            if not text.startswith("R=") or "," not in text:
                print(f"[raw] {line!r}")
                continue

            body = text[2:]
            try:
                n_hex, c_hex = body.split(",", 1)
            except ValueError:
                print(f"[warn] cannot split N,C from: {text!r}")
                continue

            try:
                n_cycles = int(n_hex, 16)
                c_coarse = int(c_hex, 16)
            except ValueError:
                print(f"[warn] cannot parse hex fields from: {text!r}")
                continue

            if c_coarse == 0 or n_cycles == 0:
                now = time.strftime("%H:%M:%S")
                print(f"{now}  N={n_cycles}  C={c_coarse} (invalid)")
                continue

            t_coarse = c_coarse / clk_hz
            f_hz = n_cycles / t_coarse

            now = time.strftime("%H:%M:%S")
            print(
                f"{now}  N=0x{n_cycles:06X} ({n_cycles:5d})  "
                f"C=0x{c_coarse:06X} ({c_coarse:6d})  "
                f"f≈{f_hz:10.2f} Hz"
            )
    except KeyboardInterrupt:
        print("\nInterrupted, closing port.")
    finally:
        ser.close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

