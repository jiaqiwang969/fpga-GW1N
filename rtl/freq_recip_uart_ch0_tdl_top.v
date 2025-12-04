//============================================================================
// freq_recip_uart_ch0_tdl_top
//----------------------------------------------------------------------------
// 在原互易计数顶层基础上，仅修改 fast 核心实例，将 USE_TDL=1'b1，
// 以便在 fast 域启用 TDL 细时间测量。其它逻辑与 freq_recip_uart_ch0_top
// 保持一致。
//
// 注意：
//   - 主工程仍使用 freq_recip_uart_ch0_top（USE_TDL 默认为 0）；
//   - 本顶层仅用于实验 / 验证，构建和烧录通过独立 Makefile 进行。
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module freq_recip_uart_ch0_tdl_top (
    input  wire sys_clk_50m,
    input  wire rst_n,
    input  wire sensor0,
    output wire uart_tx,
    output wire led_lock,
    output wire led_valid
);

    // 直接复用原顶层 freq_recip_uart_ch0_top 中的逻辑，
    // 唯一不同是对 recip_core_fast 的参数化。

    localparam integer REF_CLK_SYS_HZ  = 50_000_000;
    localparam integer REF_CLK_FAST_HZ = 200_000_000;

    wire clk_sys = sys_clk_50m;
    wire clk     = clk_sys;
    wire rst     = ~rst_n;

    localparam integer N_CYCLES       = 1600;
    localparam [23:0] N_CYCLES_CONST  = 24'd1600;
    localparam integer COARSE_WIDTH   = 24;

    // fast 域时钟：rPLL 产生约 200MHz
    wire clk_fast;
    wire pll_lock;

    Gowin_rPLL u_pll_fast (
        .clkout(clk_fast),
        .lock  (pll_lock),
        .clkin (clk_sys)
    );

    // fast 核心：N 周期互易计数 + 粗/细时间
    wire                    tdc_busy_fast;
    wire                    tdc_valid_fast;
    wire                    tdc_ack_fast;
    wire [COARSE_WIDTH-1:0] tdc_coarse_fast;
    wire [7:0]              tdc_fine_raw_fast;

    recip_core_fast #(
        .N_CYCLES    (N_CYCLES),
        .COARSE_WIDTH(COARSE_WIDTH),
        .USE_TDL     (1'b1)  // 启用 fast 域 TDL
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

    // 以下逻辑与 freq_recip_uart_ch0_top 中保持一致：
    // fast -> sys 壳层、UART 打包、LED 指示。

    // fast -> sys 壳层
    reg [COARSE_WIDTH-1:0] coarse_latched = {COARSE_WIDTH{1'b0}};
    reg [7:0]              fine_latched   = 8'd0;
    reg                    result_valid   = 1'b0;

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
                ack_toggle_clk <= ~ack_toggle_clk;
            end
        end
    end

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

    // UART 发送器
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

    // 4bit nibble -> ASCII
    function [7:0] hex_char;
        input [3:0] nib;
        begin
            if (nib < 4'd10)
                hex_char = "0" + nib[3:0];
            else
                hex_char = "A" + (nib[3:0] - 4'd10);
        end
    endfunction

    localparam integer MSG_LAST = 19; // 0..19, "R=NNNNNN,CCCCCC,FF\r\n"

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
                5'd8:  msg_char = ",";
                5'd9:  msg_char = hex_char(coarse_reg[23:20]);
                5'd10: msg_char = hex_char(coarse_reg[19:16]);
                5'd11: msg_char = hex_char(coarse_reg[15:12]);
                5'd12: msg_char = hex_char(coarse_reg[11:8]);
                5'd13: msg_char = hex_char(coarse_reg[7:4]);
                5'd14: msg_char = hex_char(coarse_reg[3:0]);
                5'd15: msg_char = ",";
                5'd16: msg_char = hex_char(fine_reg[7:4]);
                5'd17: msg_char = hex_char(fine_reg[3:0]);
                5'd18: msg_char = 8'h0D;
                5'd19: msg_char = 8'h0A;
                default: msg_char = 8'h20;
            endcase
        end
    endfunction

    reg  [4:0] msg_idx   = 5'd0;
    reg        start_reg = 1'b0;
    reg  [7:0] data_reg  = 8'h00;
    reg  [1:0] state     = 2'd0;

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
            start_reg <= 1'b0;

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

    // LED 指示
    assign led_lock = pll_lock;

    reg [23:0] led_valid_cnt = 24'd0;
    reg        led_valid_reg = 1'b0;
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

