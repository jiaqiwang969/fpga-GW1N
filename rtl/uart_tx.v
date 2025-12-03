//============================================================================
// UART发送模块
// 功能：参数化 UART 发送器（默认 115200bps，适配任意 CLK_FREQ）
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module uart_tx #(
    parameter CLK_FREQ = 50_000_000, // 时钟频率（Hz），默认 50MHz
    parameter BAUD     = 115200      // 波特率
)(
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] data,
    input  wire       start,
    output reg        tx,
    output reg        busy
);

    // 波特率分频器参数
    // 例如：
    //   50MHz / 115200 ≈ 434
    //   100MHz / 115200 ≈ 868
    localparam BAUD_DIV = CLK_FREQ / BAUD;

    // 状态定义
    localparam IDLE  = 2'd0;
    localparam START = 2'd1;
    localparam DATA  = 2'd2;
    localparam STOP  = 2'd3;

    reg [1:0]  state;
    // 分频计数器使用略宽一些的位数，便于未来在更高时钟下也能支持低波特率
    reg [15:0] baud_cnt;     // 波特率计数器
    reg [2:0]  bit_cnt;      // 数据位计数
    reg [7:0]  shift_reg;    // 移位寄存器
    wire       baud_tick;

    // 波特率时钟生成
    assign baud_tick = (baud_cnt == BAUD_DIV - 1);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            baud_cnt <= 9'd0;
        end else if (state == IDLE) begin
            baud_cnt <= 9'd0;
        end else if (baud_tick) begin
            baud_cnt <= 9'd0;
        end else begin
            baud_cnt <= baud_cnt + 1'b1;
        end
    end

    // UART状态机
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state     <= IDLE;
            tx        <= 1'b1;      // 空闲高电平
            busy      <= 1'b0;
            bit_cnt   <= 3'd0;
            shift_reg <= 8'd0;
        end else begin
            case (state)
                IDLE: begin
                    tx <= 1'b1;
                    if (start) begin
                        state     <= START;
                        shift_reg <= data;
                        busy      <= 1'b1;
                    end
                end

                START: begin
                    tx <= 1'b0;     // 起始位
                    if (baud_tick) begin
                        state   <= DATA;
                        bit_cnt <= 3'd0;
                    end
                end

                DATA: begin
                    tx <= shift_reg[0];     // LSB first
                    if (baud_tick) begin
                        shift_reg <= {1'b0, shift_reg[7:1]};
                        if (bit_cnt == 3'd7) begin
                            state <= STOP;
                        end else begin
                            bit_cnt <= bit_cnt + 1'b1;
                        end
                    end
                end

                STOP: begin
                    tx <= 1'b1;     // 停止位
                    if (baud_tick) begin
                        state <= IDLE;
                        busy  <= 1'b0;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
