//============================================================================
// 边沿检测模块 - 三级同步器 + 上升沿检测
// 功能：对异步信号进行同步，并检测上升沿
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module edge_detect (
    input  wire clk,
    input  wire rst,
    input  wire signal_in,
    output wire edge_out
);

    // 三级同步寄存器（防亚稳态）
    // sync_reg[0] - 第一级采样
    // sync_reg[1] - 第二级稳定
    // sync_reg[2] - 第三级用于边沿检测
    reg [2:0] sync_reg;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sync_reg <= 3'b000;
        end else begin
            sync_reg <= {sync_reg[1:0], signal_in};
        end
    end

    // 上升沿检测：当前为高(q1)且前一拍为低(q2)
    // edge_out = sync_reg[1] & ~sync_reg[2]
    assign edge_out = sync_reg[1] & ~sync_reg[2];

endmodule

`default_nettype wire
