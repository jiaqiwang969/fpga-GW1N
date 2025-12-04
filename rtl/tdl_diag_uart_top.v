//============================================================================
// tdl_diag_uart_top
//----------------------------------------------------------------------------
// 目的：在不影响主互易计数工程的前提下，独立验证基于 LUT1 的
// TDL 细时间测量链路是否工作正常。
//
// 功能：
//   - 使用板载 50MHz 时钟作为 clk_fast（不经过 PLL，保证时序宽松）；
//   - 对异步 sensor0 信号构造一条 TDL 延迟线并采样成 fine_code；
//   - 在每一次 sensor0 上升沿时锁存当前 fine_code，得到 fine_latched；
//   - 通过 UART 输出一行文本：
//         "T=FF\r\n"
//     其中 FF 为 fine_latched 的 16 进制表示。
//
// 引脚复用 freq_recip_uart_ch0_top 约束中的 sys_clk_50m / rst_n / sensor0 / uart_tx / LED。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tdl_diag_uart_top (
    input  wire sys_clk_50m,
    input  wire rst_n,
    input  wire sensor0,
    output wire uart_tx,
    output wire led_lock,
    output wire led_valid
);

    // 使用板载 50MHz 作为 clk_fast / UART / 逻辑时钟
    wire clk = sys_clk_50m;
    wire rst = ~rst_n;

    //====================================================================
    // 边沿检测：在 clk 域检测 sensor0 上升沿，作为“采样标志”
    //====================================================================
    wire sensor_edge;

    edge_detect u_edge_sensor (
        .clk       (clk),
        .rst       (rst),
        .signal_in (sensor0),
        .edge_out  (sensor_edge)
    );

    //====================================================================
    // TDL 细时间测量：clk 域采样异步 sensor0 的相位
    //====================================================================
    wire [7:0] fine_code_current;

    tdl_fine_stop #(
        .TDL_TAPS   (32),
        .CODE_WIDTH (8)
    ) u_tdl (
        .clk_fast    (clk),
        .rst         (rst),
        .signal_async(sensor0),
        .fine_code   (fine_code_current)
    );

    // 在每个 sensor0 上升沿时锁存一次细时间编码
    reg [7:0] fine_latched = 8'd0;
    reg       fine_valid   = 1'b0;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            fine_latched <= 8'd0;
            fine_valid   <= 1'b0;
        end else begin
            fine_valid <= 1'b0;
            if (sensor_edge) begin
                fine_latched <= fine_code_current;
                fine_valid   <= 1'b1;
            end
        end
    end

    //====================================================================
    // UART 发送器：115200 bps，在每次 fine_valid 时发送 "T=FF\r\n"
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

    // nibble -> ASCII
    function [7:0] hex_char;
        input [3:0] nib;
        begin
            if (nib < 4'd10)
                hex_char = "0" + nib[3:0];
            else
                hex_char = "A" + (nib[3:0] - 4'd10);
        end
    endfunction

    localparam integer MSG_LAST = 4; // 索引 0..4，共 5 字节："T=FF\r\n"

    reg  [2:0] msg_idx   = 3'd0;
    reg        start_reg = 1'b0;
    reg  [7:0] data_reg  = 8'h00;
    reg  [1:0] state     = 2'd0;

    // 跟踪 tx_busy 下降沿
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

    // 选择要发送的字符
    function [7:0] msg_char;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: msg_char = "T";
                3'd1: msg_char = "=";
                3'd2: msg_char = hex_char(fine_latched[7:4]);
                3'd3: msg_char = hex_char(fine_latched[3:0]);
                3'd4: msg_char = 8'h0D; // '\r'
                // '\n' 作为下一拍单独发送，避免状态机复杂化
                default: msg_char = 8'h20;
            endcase
        end
    endfunction

    // 简化起见：发送 "T=FF\r\n"，其中 '\n' 直接在 '\r' 发送完成后补一个 0x0A
    reg send_lf = 1'b0;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state     <= ST_IDLE;
            msg_idx   <= 3'd0;
            start_reg <= 1'b0;
            data_reg  <= 8'h00;
            send_lf   <= 1'b0;
        end else begin
            start_reg <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (fine_valid && !tx_busy) begin
                        msg_idx <= 3'd0;
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
                            // 发送 '\n'
                            data_reg <= 8'h0A;
                            start_reg <= 1'b1;
                            state     <= ST_IDLE;
                        end else begin
                            msg_idx <= msg_idx + 3'd1;
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
    // led_lock：常亮表示系统在跑
    assign led_lock = 1'b1;

    // led_valid：每次 fine_valid 时点亮，保持约 0.2s
    reg [23:0] led_cnt   = 24'd0;
    reg        led_reg   = 1'b0;
    localparam integer LED_HOLD = 50_000_000 / 5; // ~0.2s

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            led_cnt <= 24'd0;
            led_reg <= 1'b0;
        end else begin
            if (fine_valid) begin
                led_cnt <= 24'd0;
                led_reg <= 1'b1;
            end else if (led_reg) begin
                if (led_cnt >= LED_HOLD) begin
                    led_reg <= 1'b0;
                end else begin
                    led_cnt <= led_cnt + 24'd1;
                end
            end
        end
    end

    assign led_valid = led_reg;

endmodule

`default_nettype wire

