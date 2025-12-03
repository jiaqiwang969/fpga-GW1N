# GW1N-LV9 50 MHz 互易频率计数器 (N=400 周期版)

这个目录是对你目前 **已经跑通、非常稳定** 的 50 MHz 互易频率计数器方案的一个「完整、可独立编译」快照。

目标是：  
在不引入 PLL / 400 MHz 等复杂因素的前提下，用板载 50 MHz 时钟做一个干净的“基准版本”，便于后续对比和迭代。

---

## 功能概述

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
├── Makefile                    # 本子工程的构建脚本 (yosys + nextpnr-himbaechel + gowin_pack)
├── README.md                   # 当前说明文档
├── project/
│   └── freq_recip_uart_ch0.cst # GW1N-LV9 QFN48 的引脚约束 (J2 接口 + LED + UART)
├── rtl/
│   ├── edge_detect.v           # 三段同步 + 上升沿检测
│   ├── simple_tdc_core.v       # 极简版 TDC 核心 (目前只做粗时间计数)
│   ├── uart_tx.v               # 115200 bps UART 发送模块
│   └── freq_recip_uart_ch0_top.v  # 顶层：互易计数 + UART 打包 + LED 指示
└── scripts/
    └── freq_recip_monitor.py   # Python 串口监控脚本，计算频率并打印
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

然后在同一个虚拟环境里运行监控脚本：

```bash
cd /Users/jqwang/131-出差回来后的集中整顿-1127/Frequency_counter
source .venv_uart/bin/activate

cd source-code-5m
make monitor
```

默认串口是 `/dev/cu.usbserial-0001`，时钟频率参数为 `--clk 50000000`。  
如果串口名有变化，可以直接手动运行：

```bash
python scripts/freq_recip_monitor.py \
    --port /dev/cu.usbserial-xxxx \
    --clk 50000000
```

你应该可以再次看到之前那种稳定的输出，用来作为后续一切 TDC / 差频 / 混频方案的 **基准尺子**。

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

