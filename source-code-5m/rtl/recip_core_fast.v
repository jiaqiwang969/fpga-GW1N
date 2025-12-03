//============================================================================
// recip_core_fast
//----------------------------------------------------------------------------
// N 周期互易频率计数核心（“fast 域”骨架版）。
//
// 职责：
//   - 在 clk_fast 域下，对 sensor0 做同步 + 上升沿检测；
//   - 看到第 1 个上升沿时拉起 start；
//   - 看到第 N 个上升沿时拉起 stop；
//   - simple_tdc_core 在 start/stop 之间计数 clk_fast 周期数；
//   - 在 fast 域内输出 coarse_count 和 valid_fast / ack_fast 握手。
//
// 当前版本：
//   - 顶层可以先将 clk_fast = clk_sys = 50MHz；
//   - 后续只需把 clk_fast 改接 rPLL 输出，并调整 REF_CLK_FAST_HZ，
//     就可以在不改整体结构的前提下提升尺子频率。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module recip_core_fast #(
    parameter integer N_CYCLES     = 400,
    parameter integer COARSE_WIDTH = 24
)(
    input  wire                   clk_fast,       // fast 域时钟（当前可等于 50MHz）
    input  wire                   rst,            // 同步复位，高有效

    // 传感器输入（异步）
    input  wire                   sensor0,

    // TDC 结果 fast 域接口
    output wire                   tdc_busy,
    output wire                   tdc_valid_fast,
    input  wire                   tdc_ack_fast,
    output wire [COARSE_WIDTH-1:0] tdc_coarse_fast,
    output wire [7:0]             tdc_fine_raw_fast
);

    //====================================================================
    // sensor0 在 fast 域同步 + 上升沿检测
    //====================================================================
    wire sensor_edge_fast;

    edge_detect u_edge_sensor_fast (
        .clk       (clk_fast),
        .rst       (rst),
        .signal_in (sensor0),
        .edge_out  (sensor_edge_fast)
    );

    //====================================================================
    // fast 域互易计数控制：
    //   - 在 sensor0 的第 1 个上升沿产生 start_fast；
    //   - 在第 N 个上升沿产生 stop_fast；
    //====================================================================
    reg        measuring_fast  = 1'b0;
    reg [15:0] edge_count_fast = 16'd0;
    reg        tdc_start_fast  = 1'b0;
    reg        tdc_stop_fast   = 1'b0;

    always @(posedge clk_fast or posedge rst) begin
        if (rst) begin
            measuring_fast  <= 1'b0;
            edge_count_fast <= 16'd0;
            tdc_start_fast  <= 1'b0;
            tdc_stop_fast   <= 1'b0;
        end else begin
            tdc_start_fast <= 1'b0;
            tdc_stop_fast  <= 1'b0;

            if (!measuring_fast) begin
                // 仅在 TDC 空闲且没有未确认结果时才允许开始新的测量
                if (sensor_edge_fast && !tdc_busy && !tdc_valid_fast) begin
                    measuring_fast  <= 1'b1;
                    edge_count_fast <= 16'd1;
                    tdc_start_fast  <= 1'b1; // 第 1 个上升沿触发 start
                end
            end else begin
                if (sensor_edge_fast) begin
                    if (edge_count_fast == N_CYCLES - 1) begin
                        measuring_fast  <= 1'b0;
                        edge_count_fast <= 16'd0;
                        tdc_stop_fast   <= 1'b1; // 第 N 个上升沿触发 stop
                    end else begin
                        edge_count_fast <= edge_count_fast + 16'd1;
                    end
                end
            end
        end
    end

    //====================================================================
    // fast 域 simple_tdc_core
    //====================================================================
    simple_tdc_core #(
        .COARSE_WIDTH(COARSE_WIDTH),
        .FINE_WIDTH  (8)
    ) u_tdc_core_fast (
        .clk_fast    (clk_fast),
        .rst         (rst),
        .start       (tdc_start_fast),
        .stop        (tdc_stop_fast),
        .ack         (tdc_ack_fast),
        .busy        (tdc_busy),
        .valid       (tdc_valid_fast),
        .coarse_count(tdc_coarse_fast),
        .fine_raw    (tdc_fine_raw_fast)
    );

endmodule

`default_nettype wire

