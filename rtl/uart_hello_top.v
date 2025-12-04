//============================================================================
// uart_hello_top
//----------------------------------------------------------------------------
// 最基础的 UART + LED 测试顶层：
//   - 使用板载 50MHz 时钟 + 115200bps UART；
//   - 每隔约 1 秒，通过 uart_tx 发送一行 "HELLO\r\n"；
//   - led_lock 常亮，表示系统在跑；
//   - led_valid 以约 1Hz 频率闪烁，方便肉眼判断时钟是否正常。
//
// 引脚命名与原工程保持一致，可以直接复用
//   project/freq_recip_uart_ch0.cst
//   中的 sys_clk_50m / rst_n / uart_tx / led_lock / led_valid 约束。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module uart_hello_top (
    input  wire sys_clk_50m,  // 板载 50MHz 时钟
    input  wire rst_n,        // 低有效复位

    output wire uart_tx,      // UART TX -> CP2102 RXD

    output wire led_lock,     // 常亮
    output wire led_valid     // 约 1Hz 闪烁
);

    wire clk = sys_clk_50m;
    wire rst = ~rst_n;

    //====================================================================
    // UART 发送器实例（50MHz / 115200bps）
    //====================================================================
    wire [7:0] tx_data;
    wire       tx_start;
    wire       tx_busy;

    uart_tx #(
        .CLK_FREQ(50_000_000),
        .BAUD    (115200)
    ) u_uart (
        .clk   (clk),
        .rst   (rst),
        .data  (tx_data),
        .start (tx_start),
        .tx    (uart_tx),
        .busy  (tx_busy)
    );

    //====================================================================
    // 周期性发送 "HELLO\r\n"
    //====================================================================
    localparam integer MSG_LEN = 7;

    // 字符 ROM
    function [7:0] msg_byte;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: msg_byte = "H";
                3'd1: msg_byte = "E";
                3'd2: msg_byte = "L";
                3'd3: msg_byte = "L";
                3'd4: msg_byte = "O";
                3'd5: msg_byte = 8'h0D; // '\r'
                3'd6: msg_byte = 8'h0A; // '\n'
                default: msg_byte = 8'h20;
            endcase
        end
    endfunction

    // 发送状态机
    reg [31:0] delay_cnt  = 32'd0;
    reg [2:0]  msg_idx    = 3'd0;
    reg [1:0]  send_state = 2'd0;
    reg [7:0]  data_reg   = 8'h00;
    reg        start_reg  = 1'b0;

    localparam ST_WAIT   = 2'd0;
    localparam ST_LOAD   = 2'd1;
    localparam ST_SEND   = 2'd2;

    // 大约 1 秒间隔：50MHz * 1s = 50_000_000
    localparam integer HELLO_INTERVAL = 50_000_000;

    assign tx_data  = data_reg;
    assign tx_start = start_reg;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            delay_cnt  <= 32'd0;
            msg_idx    <= 3'd0;
            send_state <= ST_WAIT;
            data_reg   <= 8'h00;
            start_reg  <= 1'b0;
        end else begin
            start_reg <= 1'b0; // 默认不触发

            case (send_state)
                ST_WAIT: begin
                    // 间隔计数
                    if (delay_cnt >= HELLO_INTERVAL) begin
                        delay_cnt  <= 32'd0;
                        msg_idx    <= 3'd0;
                        send_state <= ST_LOAD;
                    end else begin
                        delay_cnt <= delay_cnt + 32'd1;
                    end
                end

                ST_LOAD: begin
                    // 装载当前字符，等待 UART 空闲后启动发送
                    if (!tx_busy) begin
                        data_reg  <= msg_byte(msg_idx);
                        start_reg <= 1'b1;
                        send_state <= ST_SEND;
                    end
                end

                ST_SEND: begin
                    // 等待本字符发送结束（busy 拉低）
                    if (!tx_busy) begin
                        if (msg_idx == MSG_LEN - 1) begin
                            // 一行发送完成，回到等待状态
                            send_state <= ST_WAIT;
                        end else begin
                            msg_idx    <= msg_idx + 3'd1;
                            send_state <= ST_LOAD;
                        end
                    end
                end

                default: send_state <= ST_WAIT;
            endcase
        end
    end

    //====================================================================
    // LED 指示
    //====================================================================
    // led_lock：常亮，表示时钟/配置正常
    assign led_lock = 1'b1;

    // led_valid：约 1Hz 闪烁，复用 delay_cnt 的高位
    // 取 delay_cnt[25]：50MHz / 2^26 ≈ 0.75Hz，肉眼看起来大约 1s 闪烁一次
    assign led_valid = delay_cnt[25];

endmodule

`default_nettype wire

