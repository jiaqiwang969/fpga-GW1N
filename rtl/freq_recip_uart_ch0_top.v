//============================================================================
// 单通道互易频率计数器 + UART 输出顶层（粗版本，不含 TDC 微细分）
//
// 思路：
//   - 直接对 sensor0 的上升沿计数；
//   - 每次测量固定 N 个周期（比如 N=400）；
//   - 用 50MHz 时钟在第 1 个上升沿与第 N 个上升沿之间计数粗略时间 C_coarse；
//   - UART 每次测量结束输出一行：
//         "R=NNNNNN,CCCCCC\r\n"
//     其中：
//       * NNNNNN 为 N 的 16 进制（目前恒定 0x000190 = 400）；
//       * CCCCC C 为粗计数 C_coarse 的 16 进制（单位: 50MHz 周期，20ns）；
//   - 端侧频率估计：
//         T_coarse ≈ C_coarse / 50e6
//         f ≈ N / T_coarse
//
// 这里只实现“互易计数”的控制框架，后续可在此基础上加入 TDC 细分时间。
//
// 引脚与 freq_uart_ch0_top / freq_gate_uart_ch0_top 保持一致，
// 可直接复用 project/freq_uart_ch0.cst。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module freq_recip_uart_ch0_top (
    // 系统时钟与复位
    input  wire sys_clk_50m,   // 50MHz 系统时钟
    input  wire rst_n,         // 低有效复位

    // 单通道传感器输入
    input  wire sensor0,

    // UART 输出
    output wire uart_tx,

    // LED 指示
    output wire led_lock,
    output wire led_valid
);

    //====================================================================
    // 时钟与复位
    //====================================================================
    // 统一在本顶层维护“sys 域”和“fast 域”的参考时钟频率参数。
    // 当前配置:
    //   - sys 域:  50 MHz (板载晶振)
    //   - fast 域: 200 MHz (由 rPLL 从 50MHz 倍频得到)
    localparam integer REF_CLK_SYS_HZ  = 50_000_000;
    localparam integer REF_CLK_FAST_HZ = 200_000_000;

    // sys 域（UART/LED 等慢逻辑）
    wire clk_sys = sys_clk_50m;      // 板载 50MHz
    wire clk     = clk_sys;          // 兼容旧命名
    wire rst = ~rst_n;

    //====================================================================
    // 参数：周期数 N 与计数宽度
    //====================================================================
    // 目标：测 N 个周期（回退到 N=1600，对比之前 200MHz 阶段的行为）
    localparam integer N_CYCLES       = 1600;
    localparam [23:0] N_CYCLES_CONST  = 24'd1600;

    // C_coarse 量级估算（200MHz 下）:
    //   T_meas ≈ N / f_sensor ≈ 1600 / 3.1MHz ≈ 0.52ms
    //   C_coarse ≈ T_meas * 200MHz ≈ 1.0e5 < 2^24
    localparam integer COARSE_WIDTH   = 24;

    //====================================================================
    //====================================================================
    // fast 域时钟：由 rPLL 产生，频率约为 200MHz（REF_CLK_FAST_HZ）
    //====================================================================
    wire clk_fast;
    wire pll_lock;

    Gowin_rPLL u_pll_fast (
        .clkout(clk_fast),
        .lock  (pll_lock),
        .clkin (clk_sys)
    );

    //====================================================================
    // fast 核心：在 clk_fast 域进行 N 周期互易计数 + 粗 TDC
    //====================================================================
    wire                    tdc_busy_fast;
    wire                    tdc_valid_fast;
    wire                    tdc_ack_fast;
    wire [COARSE_WIDTH-1:0] tdc_coarse_fast;
    wire [7:0]              tdc_fine_raw_fast;

    recip_core_fast #(
        .N_CYCLES    (N_CYCLES),
        .COARSE_WIDTH(COARSE_WIDTH)
    ) u_recip_core_fast (
        .clk_fast        (clk_fast),
        .rst             (rst),
        .sensor0         (sensor0),
        .tdc_busy        (tdc_busy_fast),
        .tdc_valid_fast  (tdc_valid_fast),
        .tdc_ack_fast    (tdc_ack_fast),
        .tdc_coarse_fast (tdc_coarse_fast),
        .tdc_fine_raw_fast(tdc_fine_raw_fast)
    );

    //====================================================================
    // fast -> sys 壳层（当前 clk_fast=clk，仍是单时钟域，
    // 但保留结构，方便后续真正跨时钟）
    //====================================================================
    reg [COARSE_WIDTH-1:0]   coarse_latched = {COARSE_WIDTH{1'b0}};
    reg [7:0]                fine_latched   = 8'd0;
    reg                      result_valid   = 1'b0;

    // 将 fast 域 valid 同步到 sys 域
    reg tdc_valid_sync1 = 1'b0;
    reg tdc_valid_sync2 = 1'b0;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            tdc_valid_sync1 <= 1'b0;
            tdc_valid_sync2 <= 1'b0;
        end else begin
            tdc_valid_sync1 <= tdc_valid_fast;
            tdc_valid_sync2 <= tdc_valid_sync1;
        end
    end

    wire tdc_valid_clk = tdc_valid_sync1 & ~tdc_valid_sync2;

    // toggle 握手：sys 域每消费一次结果翻转一次 ack_toggle_clk
    reg ack_toggle_clk = 1'b0;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            coarse_latched <= {COARSE_WIDTH{1'b0}};
            fine_latched   <= 8'd0;
            result_valid   <= 1'b0;
            ack_toggle_clk <= 1'b0;
        end else begin
            result_valid <= 1'b0;

            if (tdc_valid_clk) begin
                coarse_latched <= tdc_coarse_fast;
                fine_latched   <= tdc_fine_raw_fast;
                result_valid   <= 1'b1;
                ack_toggle_clk <= ~ack_toggle_clk; // 触发一次 ack 事件
            end
        end
    end

    // 在 fast 域同步 ack_toggle_clk，并将其边沿转换成单周期 tdc_ack_fast 脉冲
    reg ack_sync1 = 1'b0;
    reg ack_sync2 = 1'b0;

    always @(posedge clk_fast or posedge rst) begin
        if (rst) begin
            ack_sync1 <= 1'b0;
            ack_sync2 <= 1'b0;
        end else begin
            ack_sync1 <= ack_toggle_clk;
            ack_sync2 <= ack_sync1;
        end
    end

    assign tdc_ack_fast = ack_sync1 ^ ack_sync2;

    //====================================================================
    // UART 发送器实例
    //====================================================================
    wire [7:0] tx_data;
    wire       tx_start;
    wire       tx_busy;

    uart_tx u_uart (
        .clk   (clk),
        .rst   (rst),
        .data  (tx_data),
        .start (tx_start),
        .tx    (uart_tx),
        .busy  (tx_busy)
    );

    //====================================================================
    // 结果 -> ASCII 文本打包
    // 帧格式："R=NNNNNN,CCCCCC,FF\r\n"  (共 20 字节，索引 0..19)
    //====================================================================

    // 4bit nibble 转 ASCII '0'..'9','A'..'F'
    function [7:0] hex_char;
        input [3:0] nib;
        begin
            if (nib < 4'd10)
                hex_char = "0" + nib[3:0];
            else
                hex_char = "A" + (nib[3:0] - 4'd10);
        end
    endfunction

    localparam integer MSG_LAST = 19; // 0..19

    // 在 result_valid 时刻锁存一次结果，用于 UART 发送期间保持稳定
    reg [23:0] n_reg      = 24'd0;
    reg [23:0] coarse_reg = 24'd0;
    reg [7:0]  fine_reg   = 8'd0;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            n_reg      <= 24'd0;
            coarse_reg <= 24'd0;
            fine_reg   <= 8'd0;
        end else if (result_valid) begin
            n_reg      <= N_CYCLES_CONST;
            coarse_reg <= coarse_latched;
            fine_reg   <= fine_latched;
        end
    end

    // 根据 msg_idx 选择要发送的字符
    function [7:0] msg_char;
        input [4:0] idx;
        begin
            case (idx)
                5'd0:  msg_char = "R";
                5'd1:  msg_char = "=";
                5'd2:  msg_char = hex_char(n_reg[23:20]);
                5'd3:  msg_char = hex_char(n_reg[19:16]);
                5'd4:  msg_char = hex_char(n_reg[15:12]);
                5'd5:  msg_char = hex_char(n_reg[11:8]);
                5'd6:  msg_char = hex_char(n_reg[7:4]);
                5'd7:  msg_char = hex_char(n_reg[3:0]);
                5'd8:  msg_char = ","; // 分隔符
                5'd9:  msg_char = hex_char(coarse_reg[23:20]);
                5'd10: msg_char = hex_char(coarse_reg[19:16]);
                5'd11: msg_char = hex_char(coarse_reg[15:12]);
                5'd12: msg_char = hex_char(coarse_reg[11:8]);
                5'd13: msg_char = hex_char(coarse_reg[7:4]);
                5'd14: msg_char = hex_char(coarse_reg[3:0]);
                5'd15: msg_char = ","; // 分隔符，粗/细之间
                5'd16: msg_char = hex_char(fine_reg[7:4]);
                5'd17: msg_char = hex_char(fine_reg[3:0]);
                5'd18: msg_char = 8'h0D; // '\r'
                5'd19: msg_char = 8'h0A; // '\n'
                default: msg_char = 8'h20;
            endcase
        end
    endfunction

    // UART 发送状态机
    reg  [4:0] msg_idx   = 5'd0;
    reg        start_reg = 1'b0;
    reg  [7:0] data_reg  = 8'h00;
    reg  [1:0] state     = 2'd0;

    // 跟踪 tx_busy 的下降沿
    reg tx_busy_d = 1'b0;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            tx_busy_d <= 1'b0;
        end else begin
            tx_busy_d <= tx_busy;
        end
    end
    wire tx_done = tx_busy_d && !tx_busy;

    localparam ST_IDLE  = 2'd0;
    localparam ST_START = 2'd1;
    localparam ST_WAIT  = 2'd2;

    assign tx_data  = data_reg;
    assign tx_start = start_reg;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state     <= ST_IDLE;
            msg_idx   <= 5'd0;
            start_reg <= 1'b0;
            data_reg  <= 8'h00;
        end else begin
            start_reg <= 1'b0; // 默认不触发

            case (state)
                ST_IDLE: begin
                    if (result_valid) begin
                        msg_idx <= 5'd0;
                        state   <= ST_START;
                    end
                end

                ST_START: begin
                    data_reg <= msg_char(msg_idx);
                    if (!tx_busy) begin
                        start_reg <= 1'b1;
                        state     <= ST_WAIT;
                    end
                end

                ST_WAIT: begin
                    if (tx_done) begin
                        if (msg_idx == MSG_LAST) begin
                            state <= ST_IDLE;
                        end else begin
                            msg_idx <= msg_idx + 5'd1;
                            state   <= ST_START;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    //====================================================================
    // LED 指示
    //====================================================================
    // 使用 PLL 后：led_lock 反映 fast 域 PLL 锁定状态
    assign led_lock = pll_lock;

    // led_valid：每次 result_valid 发生时点亮，保持约 0.2s 后熄灭
    reg [23:0] led_valid_cnt = 24'd0;
    reg        led_valid_reg = 1'b0;

    // 0.2s = REF_CLK_SYS_HZ / 5 个 sys 时钟周期；当前 REF_CLK_SYS_HZ=50MHz -> 10_000_000
    localparam integer LED_VALID_HOLD = REF_CLK_SYS_HZ / 5;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            led_valid_cnt <= 24'd0;
            led_valid_reg <= 1'b0;
        end else begin
            if (result_valid) begin
                led_valid_cnt <= 24'd0;
                led_valid_reg <= 1'b1;
            end else if (led_valid_reg) begin
                if (led_valid_cnt >= LED_VALID_HOLD) begin
                    led_valid_reg <= 1'b0;
                end else begin
                    led_valid_cnt <= led_valid_cnt + 24'd1;
                end
            end
        end
    end

    assign led_valid = led_valid_reg;

endmodule

`default_nettype wire
