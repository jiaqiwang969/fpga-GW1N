//============================================================================
// simple_tdc_core
//----------------------------------------------------------------------------
// 一个极简版的 TDC“骨架”，当前只实现粗时间计数：
//   - 在 start 和 stop 之间，用 clk_fast 计数；
//   - stop 时输出 coarse_count，并给出 valid 脉冲；
//   - fine_raw 预留给后续延迟线细分时间使用，目前恒为 0。
//
// 说明：
//   - start/stop 视为 clk_fast 域内的单周期脉冲；
//   - 调用者需要保证测量区间内不会产生新的 start；
//   - 后续可在此基础上引入 TDL + LUT，对 fine_raw 赋值。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module simple_tdc_core #(
    parameter integer COARSE_WIDTH = 24,
    parameter integer FINE_WIDTH   = 8
) (
    input  wire                   clk_fast,      // 高速时钟（当前可先用 50MHz）
    input  wire                   rst,           // 同步复位，高有效
    input  wire                   start,         // 测量开始脉冲（1 个 clk_fast 周期）
    input  wire                   stop,          // 测量结束脉冲（1 个 clk_fast 周期）
    input  wire                   ack,           // 结果确认脉冲（1 个 clk_fast 周期）

    output reg                    busy,          // 正在测量标志
    output reg                    valid,         // 结果有效标志（保持为 1，直到收到 ack）
    output reg [COARSE_WIDTH-1:0] coarse_count,  // 粗时间计数（clk_fast 周期数）
    output reg [FINE_WIDTH-1:0]   fine_raw       // 细时间编码（预留，当前恒为 0）
);

    reg [COARSE_WIDTH-1:0] counter = {COARSE_WIDTH{1'b0}};

    always @(posedge clk_fast or posedge rst) begin
        if (rst) begin
            busy         <= 1'b0;
            valid        <= 1'b0;
            counter      <= {COARSE_WIDTH{1'b0}};
            coarse_count <= {COARSE_WIDTH{1'b0}};
            fine_raw     <= {FINE_WIDTH{1'b0}};
        end else begin
            // valid 由 stop 置位，由 ack 清零
            if (ack)
                valid <= 1'b0;

            if (!busy) begin
                // 空闲状态：等待 start
                counter <= {COARSE_WIDTH{1'b0}};
                if (start && !valid) begin
                    busy    <= 1'b1;
                    counter <= {COARSE_WIDTH{1'b0}};
                end
            end else begin
                // 正在测量：递增计数
                counter <= counter + {{(COARSE_WIDTH-1){1'b0}}, 1'b1};

                if (stop) begin
                    busy         <= 1'b0;
                    coarse_count <= counter;
                    fine_raw     <= {FINE_WIDTH{1'b0}}; // 目前不做细分
                    valid        <= 1'b1;               // 结果就绪，等待 ack 清除
                end
            end
        end
    end

endmodule

`default_nettype wire
