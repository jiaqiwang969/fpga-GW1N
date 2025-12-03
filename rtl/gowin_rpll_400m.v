// Gowin_rPLL wrapper for GW1N-LV9 (GW1NR-9C family)
// -------------------------------------------------
// 目标：
//   - 输入:  50 MHz 板载时钟 (sys_clk_50m)
//   - 输出: 约 200 MHz 时钟，用作 fast 域计数尺子 clk_fast
//
// 说明：
//   - rPLL 频率关系（UG286）:
//       f_CLKOUT = f_CLKIN * FBDIV / IDIV
//       f_VCO    = f_CLKOUT * ODIV
//   - 当前参数:
//       IDIV_SEL  = 0 -> IDIV  = 1
//       FBDIV_SEL = 3 -> FBDIV = 4
//       ODIV_SEL  = 4 -> ODIV  = 4
//     因此:
//       f_CLKOUT = 50MHz * 4 / 1 = 200 MHz
//       f_VCO    = 200MHz * 4    = 800 MHz (在允许范围内)

`default_nettype none

module Gowin_rPLL (clkout, lock, clkin);

    output clkout;
    output lock;
    input  clkin;

    wire clkoutp_o;
    wire clkoutd_o;
    wire clkoutd3_o;
    wire gw_gnd = 1'b0;
    wire clkout_int;

    rPLL rpll_inst (
        .CLKOUT   (clkout_int),
        .LOCK     (lock),
        .CLKOUTP  (clkoutp_o),
        .CLKOUTD  (clkoutd_o),
        .CLKOUTD3 (clkoutd3_o),
        .RESET    (gw_gnd),
        .RESET_P  (gw_gnd),
        .CLKIN    (clkin),
        .CLKFB    (gw_gnd),
        .FBDSEL   ({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
        .IDSEL    ({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
        .ODSEL    ({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
        .PSDA     ({gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
        .DUTYDA   ({gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
        .FDLY     ({gw_gnd,gw_gnd,gw_gnd,gw_gnd})
    );

    // 50 MHz input, CLKOUT ≈ 200 MHz
    defparam rpll_inst.FCLKIN        = "50";
    defparam rpll_inst.DYN_IDIV_SEL  = "false";
    defparam rpll_inst.IDIV_SEL      = 0;
    defparam rpll_inst.DYN_FBDIV_SEL = "false";
    // FBDIV_SEL = 3  -> (FBDIV_SEL+1) = 4; 50MHz * 4 = 200MHz
    defparam rpll_inst.FBDIV_SEL     = 3;
    defparam rpll_inst.DYN_ODIV_SEL  = "false";
    defparam rpll_inst.ODIV_SEL      = 4;
    defparam rpll_inst.PSDA_SEL      = "0000";
    defparam rpll_inst.DYN_DA_EN     = "true";
    defparam rpll_inst.DUTYDA_SEL    = "1000";
    defparam rpll_inst.CLKOUT_FT_DIR = 1'b1;
    defparam rpll_inst.CLKOUTP_FT_DIR= 1'b1;
    defparam rpll_inst.CLKOUT_DLY_STEP  = 0;
    defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
    defparam rpll_inst.CLKFB_SEL     = "internal";
    defparam rpll_inst.CLKOUT_BYPASS = "false";
    defparam rpll_inst.CLKOUTP_BYPASS= "false";
    defparam rpll_inst.CLKOUTD_BYPASS= "false";
    defparam rpll_inst.DYN_SDIV_SEL  = 2;
    defparam rpll_inst.CLKOUTD_SRC   = "CLKOUT";
    defparam rpll_inst.CLKOUTD3_SRC  = "CLKOUT";
    defparam rpll_inst.DEVICE        = "GW1N-9C";

    assign clkout = clkout_int;

endmodule

`default_nettype wire
