#!/usr/bin/env python3
"""
互易计数 + TDL 实验顶层 (freq_recip_uart_ch0_tdl_top) 数据抓取与统计脚本。

用途：
  - 从串口读取 "R=NNNNNN,CCCCCC,FF" 行；
  - 计算粗频率 freq_coarse = N * clk / C；
  - 利用双端 TDL 差分 FF 做简单细时间修正，得到 freq_tdl；
  - 比较两者的均值和标准差，评估 TDL 对抖动的改善效果。

使用方法（在 fpga-GW1N 目录下）：

  python scripts/recip_analyze.py /dev/cu.usbserial-0001 115200 200000000 1600 5

参数说明：
  argv[1] : 串口设备名，例如 /dev/cu.usbserial-0001
  argv[2] : 波特率，例如 115200
  argv[3] : fast 域时钟频率 Hz，例如 200000000
  argv[4] : N（每次测量的周期数），例如 1600
  argv[5] : 采集时长（秒），例如 5
"""

import sys
import time
from statistics import mean, pstdev
from typing import List, Tuple

import serial


def parse_recip_line(text: str) -> Tuple[int, int, int] | None:
    """
    解析 "R=NNNNNN,CCCCCC" 或 "R=NNNNNN,CCCCCC,FF" 行。
    返回 (N, C, F)；若没有 F，则 F=0。
    """
    text = text.strip()
    if not text.startswith("R="):
        return None
    body = text[2:]
    parts = [p.strip() for p in body.split(",")]
    if len(parts) < 2:
        return None

    try:
        n = int(parts[0], 16)
        c = int(parts[1], 16)
        f = int(parts[2], 16) if len(parts) >= 3 else 0
    except ValueError:
        return None

    return n, c, f


def main() -> None:
    if len(sys.argv) < 6:
        print(
            "Usage: recip_analyze.py PORT BAUD CLK_HZ N_CYCLES DURATION_SEC\n"
            "Example: recip_analyze.py /dev/cu.usbserial-0001 115200 200000000 1600 5"
        )
        sys.exit(1)

    port = sys.argv[1]
    baud = int(sys.argv[2])
    clk_hz = float(sys.argv[3])
    n_cycles_cfg = int(sys.argv[4])
    duration = float(sys.argv[5])

    print(
        f"[RECIP] Open {port} @ {baud} baud, clk={clk_hz:.0f} Hz, N={n_cycles_cfg}, duration={duration}s"
    )

    ser = serial.Serial(port, baud, timeout=0.5)

    f_coarse_vals: List[float] = []
    f_tdl_vals: List[float] = []
    f_fine_vals: List[float] = []

    start = time.time()

    while time.time() - start < duration:
        line = ser.readline()
        if not line:
            continue
        try:
            text = line.decode(errors="replace").strip()
        except Exception:
            continue

        parsed = parse_recip_line(text)
        if parsed is None:
            continue

        n_cycles, c_coarse, f_fine = parsed
        if n_cycles <= 0 or c_coarse <= 0:
            continue

        if n_cycles != n_cycles_cfg:
            # 当前只分析 N 固定的实验配置
            continue

        # 粗频率
        f_coarse = n_cycles * clk_hz / c_coarse
        f_coarse_vals.append(f_coarse)
        f_fine_vals.append(float(f_fine))

    ser.close()

    if not f_coarse_vals:
        print("[RECIP] No valid samples captured.")
        return

    print(f"[RECIP] samples: {len(f_coarse_vals)}")

    # 计算 F 的均值，用于零均值扰动
    mean_f = mean(f_fine_vals)
    print(f"[RECIP] mean F = {mean_f:.3f}")

    # 细时间修正：使用 F - mean(F)，并用一个 span 缩放到 < 1 tick 的范围
    SPAN = 16.0
    for c_coarse, f_fine in zip(f_coarse_vals, f_fine_vals):
        delta_f = f_fine - mean_f
        frac_f = delta_f / SPAN
        c_plus = c_coarse + frac_f
        t_est = c_plus / clk_hz
        f_tdl = n_cycles_cfg / t_est
        f_tdl_vals.append(f_tdl)

    # 统计粗 / 粗+细频率的均值和标准差（总人群标准差，非样本标准差）
    mean_coarse = mean(f_coarse_vals)
    std_coarse = pstdev(f_coarse_vals)

    mean_tdl = mean(f_tdl_vals)
    std_tdl = pstdev(f_tdl_vals)

    print(f"[RECIP] freq_coarse mean = {mean_coarse:.6f} Hz, std = {std_coarse:.6f} Hz")
    print(f"[RECIP] freq_tdl     mean = {mean_tdl:.6f} Hz, std = {std_tdl:.6f} Hz")
    if std_coarse > 0:
        print(f"[RECIP] std_tdl / std_coarse = {std_tdl / std_coarse:.3f}")


if __name__ == "__main__":
    main()

