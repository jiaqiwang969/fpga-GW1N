# 阶段计划：从粗互易计数到粗+细 TDC

本阶段目标：在现有 GW1N 互易频率计数工程上，引入“亚时钟细分”的 TDC 结构，在不破坏现有 N 周期互易框架和 GUI 的前提下，提高时间测量分辨率，并验证对频率抖动的改善效果。

## 当前基线

- 硬件：GW1N-LV9 入门开发板，板载 50MHz 晶振，`sys_clk_50m` 接专用 GCLK 输入。
- 时钟：
  - 50MHz → rPLL → `clk_fast ≈ 200MHz`。
  - 粗时间 LSB ≈ 5ns。
- 互易计数：
  - `recip_core_fast` 在 `clk_fast` 域计数 N=1600 个 `sensor0` 周期。
  - `simple_tdc_core` 只做粗计数，`fine_raw` 恒为 0。
  - 顶层通过 UART 输出 `"R=NNNNNN,CCCCCC\r\n"`，Rust GUI 解析并绘制频率。
- 自检：
  - `uart_hello_top` + `Makefile_hello` + `prog_flash`，提供上电 HELLO 自检和 LED 指示。

## 本阶段要做的事

1. **TDC 架构设计**
   - 在 `simple_tdc_core` 内增加基于 carry-chain 的 TDL（时间延迟线）。
   - 首版只在 stop 边沿做细分，得到 `fine_stop` 编码到 `fine_raw`。
   - 保持现有 `coarse_count`/`valid`/`busy` 接口不变。

2. **Verilog 实现与综合验证**
   - 在 GW1N 上用 ALU/进位链构造一条固定长度的 TDL。
   - 用 `clk_fast` 触发的一排触发器采样 TDL 热码，并编码成 `fine_raw`。
   - 确认 yosys + nextpnr 能将其映射到连续的 carry chain，并通过基本时序检查。

3. **UART 协议扩展**
   - 在 `freq_recip_uart_ch0_top` 中扩展 UART 输出格式为：
     - `"R=NNNNNN,CCCCCC,FF\r\n"` 或类似形式。
   - 确保老版解析脚本不会崩溃（必要时保留兼容模式）。

4. **上位机解析与可视化**
   - 更新 Rust `freq_plotter`：
     - 解析附带的 `fine_raw`。
     - 基于粗+细时间重构测量间隔 T，并计算频率。
   - 增加对比模式：
     - 只用粗时间估计的频率曲线；
     - 粗+细时间估计的频率曲线。

5. **实验与评估**
   - 在固定传感器信号条件下，记录一定时长的数据（例如数分钟）。
   - 计算：
     - 两种频率估计的短期标准差 / 方差；
     - 必要时计算 Allan deviation 曲线。
   - 评估：
     - 细分 TDC 带来的量化噪声下降幅度；
     - 是否已经接近 rPLL / 晶振相位抖动的极限。

6. **后续规划占位**
   - 若效果明显：
     - 进一步在 start 与 stop 两端都加入 fine time，并在 fast 域或上位机做差分。
   - 若效果一般或受限于时钟抖动：
     - 评估引入更高品质时钟源或调整 rPLL 配置的收益。

