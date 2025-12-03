# GW1N-LV9 互易频率计数器 + Rust 实时频率 GUI

这个目录包含：

- 一个 **互易频率计数器** FPGA 工程（当前 fast 尺子已支持通过 rPLL 提升）；
- 一个配套的 **Rust 频率实时曲线 GUI**（`freq_plotter/`）。

目标是：

- 用干净的 N 周期互易计数结构，作为所有 TDC / 差频 / 混频方案的“基准”；
- 同时有一个跨平台 GUI，可以直观看到频率随时间的抖动和漂移。

---

## 功能概述（FPGA 端）

- 顶层模块：`freq_recip_uart_ch0_top`
- 计数时钟：`sys_clk_50m` (50 MHz)
- 测量对象：传感器通道 0 (`sensor0`，接在 J2 上排第 2 针 → FPGA Pin3)
- 测量方法：互易计数
  - 先等待 `sensor0` 的第 1 个上升沿；
  - 从第 1 个上升沿开始，用 50 MHz 计数；
  - 数到第 `N = 400` 个上升沿时停止计数，记下粗时间 `C`（单位：20 ns）；
  - UART 输出一行文本，格式为：

    ```text
    R=NNNNNN,CCCCCC\r\n
    ```

    - `NNNNNN`：N 的 16 进制表示（目前恒定为 `0x000190` = 400）
    - `CCCCCC`：粗时间计数 `C` 的 16 进制表示（单位 = 1/50 MHz = 20 ns）

- 上位机用 Python 解析后，计算频率：

  ```text
  T_coarse ≈ C / 50e6
  f        ≈ N / T_coarse
  ```

  你之前看到的典型输出类似：

  ```text
  23:09:51  N=0x000190 (  400)  C=0x00195A (  6490)  f≈3081664.10 Hz
  23:09:51  N=0x000190 (  400)  C=0x00195B (  6491)  f≈3081189.34 Hz
  ```

---

## 目录结构

```text
source-code-5m/
├── Makefile                        # 本子工程的构建脚本 (yosys + nextpnr-himbaechel + gowin_pack)
├── README.md                       # 当前说明文档（本文件）
├── project/
│   └── freq_recip_uart_ch0.cst     # GW1N-LV9 QFN48 的引脚约束 (J2 接口 + LED + UART)
├── rtl/
│   ├── edge_detect.v               # 三段同步 + 上升沿检测
│   ├── simple_tdc_core.v           # 极简版 TDC 核心 (目前只做粗时间计数)
│   ├── recip_core_fast.v           # fast 域 N 周期互易计数控制
│   ├── gowin_rpll_400m.v           # rPLL 包装（用于把 50MHz 放大到 fast 尺子时钟）
│   ├── uart_tx.v                   # 115200 bps UART 发送模块
│   └── freq_recip_uart_ch0_top.v   # 顶层：互易计数 + UART 打包 + LED 指示
├── scripts/                        # 一些历史分析脚本（FFT 等，可选）
│   └── freq_live_plot.py           # （可选）Python 实时曲线脚本（保留作参考）
└── freq_plotter/
    ├── Cargo.toml                  # Rust GUI 工程（egui + serialport）
    ├── README.md                   # Rust GUI 使用说明
    └── src/
        ├── main.rs                 # 串口读取 + 互易计数解析 + 实时曲线
        └── measurements.rs         # 滑动窗口数据结构
```

---

## 依赖环境

1. **FPGA 工具链**

   和你之前使用的一样：

   - `yosys` （带 `synth_gowin`）
   - `nextpnr-himbaechel` （支持 `--device GW1N-LV9QN48C6/I5`）
   - `gowin_pack` （来自 `apycula`，我们已经在 `.venv_uart` 里安装）
   - `openFPGALoader` （用于下载 bitstream 到 GW1N 开发板）

2. **Python 虚拟环境 `.venv_uart`**

   在仓库根目录已经建立好一个虚拟环境，里面安装了：

   - `apycula`（提供 `gowin_pack`）
   - `pyserial`（用于串口通信）

   激活方式（在仓库根目录）：

   ```bash
   cd /Users/jqwang/131-出差回来后的集中整顿-1127/Frequency_counter
   source .venv_uart/bin/activate
   ```

---

## 构建与下载

以下命令默认在 **仓库根目录** 激活完虚拟环境后执行：

```bash
cd /Users/jqwang/131-出差回来后的集中整顿-1127/Frequency_counter
source .venv_uart/bin/activate

cd source-code-5m
make          # 综合 + 布线 + 生成比特流 build_fpga/freq_recip_uart_ch0_top.fs
make prog     # 通过 FT232 JTAG 下载到 GW1N FPGA (SRAM)
```

`make prog` 内部使用：

```bash
openFPGALoader -c ft232 build_fpga/freq_recip_uart_ch0_top.fs
```

与你之前手工操作保持一致。

---

## 串口监控与频率计算

下载成功后，确认：

- 复位键松开后，D14 常亮（`led_lock`，这里直接拉高表示“系统在跑”）；
- D13 会周期性点亮一小段时间，表示每次完成一组测量。

然后可以使用 Rust GUI 或 Python `freq_live_plot.py` 来监控频率。

---

## 后续扩展建议

这个 50 MHz 版本可以作为“安全落点”和对比基线，后面可以在此基础上逐步尝试：

1. 在 `simple_tdc_core.v` 内加入小规模 TDL（carry chain 延迟线），输出 `fine_raw`；
2. 在顶层增加 UART 输出格式，例如 `"R=NNNNNN,CCCCCC,FF\r\n"`，把粗时间和细时间一起打出来；
3. 用 Python 脚本对比：
   - 只用粗时间估计的频率；
   - 粗 + 细时间估计的频率；
   看看分辨率和抖动有什么变化。

这些尝试都可以先在 `source-code-5m` 这个独立快照里做，不会影响你主工程里已经验证过的其它方案。 

# fpga-GW1N
