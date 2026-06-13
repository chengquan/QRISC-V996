#!/bin/bash
#-----------------------------------------------------------------
# 构建 biRISC-V + riscv_soc(全 RTL 外设)仿真。
#   ./build.sh                 verilator --binary --timing(默认,快)
#   ./build.sh verilator-trace 带 --trace 的版本(能导出 VCD 波形,慢)
#   ./build.sh iverilog        iverilog(慢,主要用于调试/短程序)
#-----------------------------------------------------------------
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SRC="$ROOT/src"
BACKEND="${1:-verilator}"

# biriscv 核 RTL
CORE="$SRC/top/riscv_top.v $(ls $SRC/core/*.v) $(ls $SRC/icache/*.v) $(ls $SRC/dcache/*.v)"
# SoC 设计:riscv_soc 外设+互联 + biriscv_soc 集成顶层 + JTAG 调试子系统(都在 src/soc/)
SOC="$(ls $SRC/soc/*.v) $(ls $SRC/soc/debug/*.v)"
# tb(测试平台:顶层 + 行为级 DRAM)+ JTAG remote_bitbang DPI 桥(C++)
TB="$HERE/tb_soc.v $HERE/axi4_ram.v"
CPP="$HERE/jtag_rbb.cpp"

INCS="-I$HERE -I$SRC/soc -I$SRC/soc/debug -I$SRC/core -I$SRC/icache -I$SRC/dcache -I$SRC/top"

cd "$HERE"
mkdir -p build

if [ "$BACKEND" = "verilator" ]; then
    command -v verilator >/dev/null || { echo "缺 verilator"; exit 1; }
    echo "== verilator --binary 编译 =="
    verilator --binary --timing -j 0 \
        -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH -Wno-CASEINCOMPLETE \
        --unroll-count 512 \
        --top-module tb_soc \
        $INCS \
        --Mdir build_vl -o tb_soc \
        $TB $SOC $CORE $CPP
    echo "✅ 完成: build_vl/tb_soc   (用 ./run.sh 运行)"

elif [ "$BACKEND" = "verilator-trace" ]; then
    command -v verilator >/dev/null || { echo "缺 verilator"; exit 1; }
    # TRACE_DEPTH:录波形的层次深度。1=只顶层 tb_soc(到 DRAM 的 AXI/uart 串行/中断,最小最快);
    #             2=再下一层(SoC 的 cpu_i/cpu_d 接口);0/大值=全层次(巨大)。默认 1。
    TD="${TRACE_DEPTH:-1}"
    # 0 = 全层次(--trace-depth 不传);否则限定前 TD 层。按深度分目录缓存。
    [ "$TD" = "0" ] && DEPTH_OPT="" || DEPTH_OPT="--trace-depth $TD"
    echo "== verilator --binary --trace-fst $DEPTH_OPT 编译(深度 $TD,FST 格式比 VCD 小很多) =="
    verilator --binary --timing -j 0 --trace-fst $DEPTH_OPT \
        -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH -Wno-CASEINCOMPLETE \
        --unroll-count 512 \
        --top-module tb_soc \
        $INCS \
        --Mdir "build_vl_trace_d$TD" -o tb_soc \
        $TB $SOC $CORE $CPP
    echo "✅ 完成: build_vl_trace_d$TD/tb_soc   (录波形用,深度 $TD)"

elif [ "$BACKEND" = "iverilog" ]; then
    command -v iverilog >/dev/null || { echo "缺 iverilog"; exit 1; }
    echo "== iverilog 编译 =="
    # 注:iverilog 不支持 DPI/C++,JTAG 调试请用 verilator 后端
    iverilog -g2012 -Wall -Wno-timescale -o build/tb.vvp $INCS $TB $SOC $CORE
    echo "✅ 完成: build/tb.vvp   (用 ./run.sh iverilog 运行;JTAG 需 verilator)"
else
    echo "未知后端: $BACKEND"; exit 1
fi
