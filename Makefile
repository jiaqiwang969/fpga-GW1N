#==============================================================================
# GW1N-LV9 互易频率计数器 (N=400 周期) - 开源工具链 Makefile
#------------------------------------------------------------------------------
# 顶层模块 : freq_recip_uart_ch0_top
# 计数时钟 :
#   - sys 域: 50 MHz (板载晶振，sys_clk_50m)
#   - fast 域: 当前仍为 50 MHz（后续通过 rPLL 升到更高频）
# 测量方式 : 对传感器信号的 N=400 个上升沿之间的时间做互易计数
# 串口输出 : "R=NNNNNN,CCCCCC\r\n"
#             NNNNNN = N 的 16 进制 (0x000190)
#             CCCCC C = 粗时间计数，单位为 1/50MHz = 20ns
#
# 依赖工具 :
#   - yosys                (synth_gowin)
#   - nextpnr-himbaechel   (--device GW1N-LV9QN48C6/I5 --vopt family=GW1N-9)
#   - gowin_pack           (来自 apycula，建议在 .venv_uart 里安装)
#   - openFPGALoader       (下载到 FPGA)
#
# 典型工作流 (在仓库根目录)：
#   source .venv_uart/bin/activate      # 激活 Python 虚拟环境，提供 gowin_pack / pyserial
#   cd source-code-5m
#   make                                # 综合 + 布线 + 生成比特流
#   make prog                           # 通过 FT232 下载到 GW1N 开发板
#   make monitor                        # 用 Python 脚本计算频率
#==============================================================================

# 目标器件 & 参考时钟
DEVICE      := GW1N-LV9QN48C6/I5
FAMILY      := GW1N-9
# 顶层 sys 域参考时钟频率（Hz），当前为板载 50MHz
REF_CLK_HZ  := 50000000
# fast 尺子参考时钟频率（Hz），当前通过 rPLL 配置为 200MHz
FAST_CLK_HZ := 200000000

# 目录
RTL_DIR     := rtl
PROJ_DIR    := project
BUILD_DIR   := build_fpga
SCRIPT_DIR  := scripts

# 顶层模块
TOP         := freq_recip_uart_ch0_top

# 源文件 (只包含 50MHz 互易计数版本需要的 RTL)
VERILOG_SRCS := \
	$(RTL_DIR)/edge_detect.v \
	$(RTL_DIR)/uart_tx.v \
	$(RTL_DIR)/simple_tdc_core.v \
	$(RTL_DIR)/tdl_fine_stop.v \
	$(RTL_DIR)/gowin_rpll_400m.v \
	$(RTL_DIR)/recip_core_fast.v \
	$(RTL_DIR)/freq_recip_uart_ch0_top.v

# 约束文件
CST_FILE    := $(PROJ_DIR)/freq_recip_uart_ch0.cst

# 输出文件
JSON_FILE   := $(BUILD_DIR)/$(TOP).json
PNR_FILE    := $(BUILD_DIR)/$(TOP)_pnr.json
BIT_FILE    := $(BUILD_DIR)/$(TOP).fs

#==============================================================================
# 默认目标
#==============================================================================
.PHONY: all
all: $(BIT_FILE)

#==============================================================================
# 创建构建目录
#==============================================================================
$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

#==============================================================================
# 综合 (Yosys + synth_gowin)
#==============================================================================
$(JSON_FILE): $(VERILOG_SRCS) | $(BUILD_DIR)
	@echo "=========================================="
	@echo "综合 (Yosys + synth_gowin)..."
	@echo "  顶层: $(TOP)"
	@echo "=========================================="
	yosys -p "read_verilog $(VERILOG_SRCS); synth_gowin -top $(TOP) -json $(JSON_FILE)"

#==============================================================================
# 布局布线 (nextpnr-himbaechel)
#==============================================================================
$(PNR_FILE): $(JSON_FILE) $(CST_FILE)
	@echo "=========================================="
	@echo "布局布线 (nextpnr-himbaechel)..."
	@echo "  器件 : $(DEVICE)"
	@echo "  家族 : $(FAMILY)"
	@echo "  约束 : $(CST_FILE)"
	@echo "=========================================="
	nextpnr-himbaechel \
		--json $(JSON_FILE) \
		--write $(PNR_FILE) \
		--device $(DEVICE) \
		--vopt family=$(FAMILY) \
		--vopt cst=$(CST_FILE)

#==============================================================================
# 生成比特流 (gowin_pack / apycula)
#==============================================================================
$(BIT_FILE): $(PNR_FILE)
	@echo "=========================================="
	@echo "生成比特流 (gowin_pack)..."
	@echo "  输入 : $(PNR_FILE)"
	@echo "  输出 : $(BIT_FILE)"
	@echo "=========================================="
	gowin_pack -d $(FAMILY) -o $(BIT_FILE) $(PNR_FILE)

#==============================================================================
# 下载到 FPGA (SRAM，掉电丢失)
#==============================================================================
.PHONY: prog
prog: $(BIT_FILE)
	@echo "=========================================="
	@echo "下载到 FPGA (openFPGALoader, SRAM 模式)..."
	@echo "  使用 FT232 JTAG 接口 (--c ft232)"
	@echo "=========================================="
	openFPGALoader -c ft232 $(BIT_FILE)

#==============================================================================
# 串口监控 + 频率实时曲线 (Rust freq_plotter)
#==============================================================================
.PHONY: monitor
monitor:
	@echo "=========================================="
	@echo "启动互易频率计数 UART 监控 (Rust GUI)..."
	@echo "  串口: /dev/cu.usbserial-0001  波特率: 115200"
	@echo "  fast 尺子参考时钟 FAST_CLK_HZ = $(FAST_CLK_HZ) Hz"
	@echo "=========================================="
	cargo run --manifest-path freq_plotter/Cargo.toml -- \
		--port /dev/cu.usbserial-0001 \
		--baud 115200 \
		--clk $(FAST_CLK_HZ) \
		--window-sec 10

#==============================================================================
# 清理
#==============================================================================
.PHONY: clean
clean:
	@echo "清理构建目录: $(BUILD_DIR)"
	rm -rf $(BUILD_DIR)

#==============================================================================
# 帮助
#==============================================================================
.PHONY: help
help:
	@echo "可用目标:"
	@echo "  make / make all   - 综合+布局布线+生成比特流"
	@echo "  make prog         - 通过 FT232 下载到 GW1N FPGA (SRAM)"
	@echo "  make monitor      - 启动 Rust 频率实时曲线 GUI (freq_plotter)"
	@echo "  make clean        - 删除构建目录 $(BUILD_DIR)"
	@echo "  make help         - 显示本帮助"
