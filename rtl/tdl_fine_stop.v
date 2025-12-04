//============================================================================
// tdl_fine_stop
//----------------------------------------------------------------------------
// 基于 LUT1 链的简易 TDL（时间延迟线）+ 采样编码模块，用于测量
// 异步信号相对于 clk_fast 的细时间位置。
//
// 设计思路：
//   - 将异步边沿信号接入一条由 LUT1 级联形成的组合延迟线；
//   - 在 clk_fast 上升沿采样整条延迟线的状态，形成温度计码模式；
//   - 统计 '1' 的数量作为粗略相位编码 fine_code。
//
// 注意：
//   - LUT1 延迟和布线相关，本模块仅作为实验/诊断用；
//   - 为避免综合优化掉中间节点，使用 (* keep *) 属性保留信号。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tdl_fine_stop #(
    parameter integer TDL_TAPS    = 32, // 延迟级数
    parameter integer CODE_WIDTH  = 8   // 输出编码位宽
) (
    input  wire                   clk_fast,
    input  wire                   rst,
    input  wire                   signal_async, // 异步被测信号
    output reg  [CODE_WIDTH-1:0]  fine_code     // 细时间编码
);

    // 延迟线节点
    (* keep = "true" *) wire [TDL_TAPS-1:0] tdl_node;
    assign tdl_node[0] = signal_async;

    genvar i;
    generate
        for (i = 0; i < TDL_TAPS-1; i = i + 1) begin : GEN_TDL
            // LUT1 配置为 F = I0，形成缓冲级
            (* keep = "true" *) LUT1 #(
                .INIT(2'b10) // I0=0 -> F=0, I0=1 -> F=1
            ) u_lut1 (
                .I0(tdl_node[i]),
                .F (tdl_node[i+1])
            );
        end
    endgenerate

    // 在 clk_fast 上升沿采样延迟线状态，并统计 '1' 个数
    reg [TDL_TAPS-1:0] tdl_sampled = {TDL_TAPS{1'b0}};
    integer k;
    reg [CODE_WIDTH:0] ones_count; // 多一位防止溢出

    always @(posedge clk_fast or posedge rst) begin
        if (rst) begin
            tdl_sampled <= {TDL_TAPS{1'b0}};
            fine_code   <= {CODE_WIDTH{1'b0}};
        end else begin
            tdl_sampled <= tdl_node;

            ones_count = { (CODE_WIDTH+1){1'b0} };
            for (k = 0; k < TDL_TAPS; k = k + 1) begin
                ones_count = ones_count + (tdl_sampled[k] ? 1'b1 : 1'b0);
            end

            fine_code <= ones_count[CODE_WIDTH-1:0];
        end
    end

endmodule

`default_nettype wire

