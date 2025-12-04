//============================================================================
// tdl_fine_stop
//----------------------------------------------------------------------------
// 基于 LUT1 进位链的简易 TDL（时间延迟线）+ 采样编码模块。
//
// 设计目的：
//   - 使用异步的 sensor0 上升沿作为“事件”，在一条组合延迟线上传播；
//   - 在 clk_fast 上升沿统一采样整条延迟线的状态，统计为 fine_code；
//   - fine_code 反映“事件相对于当前 clk_fast 上升沿”的细时间位置。
//
// 说明：
//   - 这里用的是 LUT1 级联形成的延迟线，延迟单元大小依赖工艺和布线；
//   - 通过 (* keep = "true" *) 属性尽量避免综合优化掉中间级；
//   - 本模块自身不区分 start/stop，只是持续输出“最近一次事件”的相位信息，
//     上层在识别到 N 周期 stop 时刻再去锁存即可。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module tdl_fine_stop #(
    parameter integer TDL_TAPS    = 32, // 延迟线级数，可按需调整
    parameter integer CODE_WIDTH  = 8   // 输出编码位宽
) (
    input  wire                   clk_fast,
    input  wire                   rst,
    input  wire                   signal_async, // 异步传感器输入（例如 sensor0）
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

    // 在 clk_fast 上升沿采样延迟线状态，并统计 '1' 的数量作为粗略相位编码。
    reg [TDL_TAPS-1:0] tdl_sampled = {TDL_TAPS{1'b0}};
    integer k;
    reg [CODE_WIDTH:0] ones_count; // 多一位防止溢出

    always @(posedge clk_fast or posedge rst) begin
        if (rst) begin
            tdl_sampled <= {TDL_TAPS{1'b0}};
            fine_code   <= {CODE_WIDTH{1'b0}};
        end else begin
            // 采样当前延迟线状态
            tdl_sampled <= tdl_node;

            // 对采样结果做简单的温度计编码：统计 '1' 的个数
            ones_count = { (CODE_WIDTH+1){1'b0} };
            for (k = 0; k < TDL_TAPS; k = k + 1) begin
                ones_count = ones_count + (tdl_sampled[k] ? 1'b1 : 1'b0);
            end

            fine_code <= ones_count[CODE_WIDTH-1:0];
        end
    end

endmodule

`default_nettype wire

