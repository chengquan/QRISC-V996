#!/bin/bash
#-----------------------------------------------------------------
# 运行 biRISC-V + riscv_soc(全 RTL 外设)。UART 输出来自真实串行线反序列化。
#   ./run.sh               verilator
#   ./run.sh iverilog      iverilog
# 环境变量:ELF= MAX_CYCLES= TRACE=1
#-----------------------------------------------------------------
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
BACKEND="${1:-verilator}"
ELF="${ELF:-$ROOT/image/biriscv-linux-5.4.elf}"
HEX="$HERE/image.hex"
MKHEX="$ROOT/scripts/make_hex.py"

# ELF -> hex(复用 tb_rtl 的转换器)
if [ ! -f "$HEX" ] || [ "$ELF" -nt "$HEX" ]; then
    echo "== 生成 image.hex（来自 $ELF）=="
    python3 "$MKHEX" "$ELF" "$HEX" 0x80000000
fi

ARGS="+IMAGE=$HEX"
[ -n "$INPUT" ]       && ARGS="$ARGS +INPUT=$INPUT"
[ -n "$INPUT_DELAY" ] && ARGS="$ARGS +INPUT_DELAY=$INPUT_DELAY"
[ -n "$MAX_CYCLES" ]  && ARGS="$ARGS +MAX_CYCLES=$MAX_CYCLES"
[ -n "$TRACE" ]       && ARGS="$ARGS +TRACE +VCD=$HERE/tb_soc.vcd"
[ -n "$DISK" ]        && ARGS="$ARGS +DISK=$DISK"
# JTAG=端口  开启 OpenOCD 兼容的 JTAG 调试(remote_bitbang),再起 openocd 连它
[ -n "$JTAG" ]        && { ARGS="$ARGS +JTAG=$JTAG"; echo " JTAG 调试已开:OpenOCD 连 localhost:$JTAG(见 tools/openocd/)"; }

echo "=================================================================="
echo " biRISC-V + riscv_soc 全RTL外设 ($BACKEND):$ELF"
echo " UART = 真 RTL uart_lite,串行线反序列化输出。Ctrl-C 退出。"
echo "=================================================================="

cd "$HERE"
if [ "$BACKEND" = "verilator" ]; then
    [ -x build_vl/tb_soc ] || { echo "先构建: ./build.sh"; exit 1; }
    exec stdbuf -o0 ./build_vl/tb_soc $ARGS
elif [ "$BACKEND" = "iverilog" ]; then
    [ -f build/tb.vvp ] || { echo "先构建: ./build.sh iverilog"; exit 1; }
    exec stdbuf -o0 vvp build/tb.vvp $ARGS
else
    echo "未知后端: $BACKEND"; exit 1
fi
