# freq_plotter （Rust + egui）

这是一个针对本项目 FPGA 互易频率计数器的**实时频率曲线显示工具**，用 Rust + egui 实现。

功能概要：

- 从串口读取 FPGA 输出的互易计数结果行：
  - 形如：`R=NNNNNN,CCCCCC\r\n`
  - `N` 为周期数，`C` 为计数器值（fast 尺子周期数）
- 按给定的参考时钟频率 `clk` 计算频率：
  - `f ≈ N * clk / C`
- 将 `(t, f)` 放入滑动窗口（时间轴），用 egui 的 Plot 组件实时画出频率随时间变化的曲线。

> `measurements.rs` 复用了原工程的“滑动窗口 + 曲线数据结构”，但数据源和 UI 已经完全针对本项目重写。

---

## 依赖环境

- Rust 工具链（建议 1.70+）
- 当前已在 macOS 上验证可用；Windows / Linux 理论上也兼容 eframe/egui 和 serialport。

如果从零开始：

```bash
cd freq_plotter
cargo build
```

---

## 使用方法

### 1. 启动 Rust 图形界面

```bash
cd freq_plotter
cargo run -- \
    --port /dev/cu.usbserial-0001 \
    --baud 115200 \
    --clk 200000000 \
    --window-sec 10
```

参数说明：

- `--port` 串口设备名称（默认 `/dev/cu.usbserial-0001`）
- `--baud` 波特率（默认 `115200`）
- `--clk` 参考时钟频率（Hz），用来把 `(N, C)` 换算成 `f`。例如：
  - fast 尺子 100 MHz 时：`--clk 100000000`
  - fast 尺子 150 MHz 时：`--clk 150000000`
  - fast 尺子 200 MHz 时：`--clk 200000000`
- `--window-sec` 显示最近多少秒的数据（时间轴窗口长度，默认 `10`）

运行后会弹出一个窗口：

- X 轴：时间（秒）
- Y 轴：频率（Hz）
- 曲线：`freq_hz`，即实时测得的频率

Plot 区域支持拖拽缩放（滚轮缩放 / 拖动平移）。

---

## 代码结构

```text
freq_plotter/
├── Cargo.toml          # Rust 包配置（依赖 clap / eframe / egui / serialport / anyhow / tracing）
├── README.md           # 本说明文件
└── src/
    ├── main.rs         # 串口线程 + egui 图形界面
    └── measurements.rs # 滑动窗口数据结构，维护 (t, y) 序列
```

核心数据流：

```text
FPGA UART -> 串口 (R=NNNNNN,CCCCCC) -> uart_loop()
  -> 解析出 N, C -> f = N * clk / C
  -> MeasurementWindow.add_row(t, &[f]) -> egui Plot 实时绘制
```

---

## 后续扩展建议

- 增加第二条曲线：例如滑动平均频率 `f_avg` 或差分 `Δf = f - f_avg`。
- 增加数值面板：显示当前频率、最近若干秒内的最小值/最大值、标准差等。
- 支持保存数据到 CSV，以便离线做频谱分析或进一步统计。

当前版本已经足够用于观察传感器频率的短期抖动和长时间漂移，可以和 Python 分析脚本（FFT、统计）配合使用。**
