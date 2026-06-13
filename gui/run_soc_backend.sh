#!/bin/bash
#-----------------------------------------------------------------
# GUI 后端(tb_soc)。两种模式:
#   MODE=linux     (默认) 跑 Linux 镜像($ELF,hvc0/ttyUL0)
#   MODE=baremetal 编译并跑裸机程序($SEL = sdk/baremetal/examples/<SEL>.c)
# 输入经 +INPUT 文件 → tb 串行发送器 → uart RX;UART 输出经 stdout 回 GUI。
#-----------------------------------------------------------------
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SOC="$ROOT/tb/tb_soc"
INPUT="${SOC_INPUT:-$SOC/.gui_input.txt}"
MODE="${MODE:-linux}"
: > "$INPUT"

if [ "$MODE" = "baremetal" ]; then
    #------- 裸机:编译选中的程序 -> hex -------
    SEL="${SEL:-hello_uart}"
    SDK="$ROOT/sdk/baremetal"
    CC=riscv64-unknown-elf-gcc
    command -v $CC >/dev/null || { echo "缺裸机工具链: sudo apt install -y gcc-riscv64-unknown-elf"; exit 1; }
    mkdir -p "$SDK/build"
    ELF="$SDK/build/$SEL.elf"
    echo "== 裸机:编译 examples/$SEL.c =="
    $CC -march=rv32ima_zicsr -mabi=ilp32 -mcmodel=medany -O2 -ffreestanding -nostdlib \
        -Wall -T "$SDK/link.ld" "$SDK/crt0.S" "$SDK/examples/$SEL.c" -o "$ELF" -lgcc
    HEX="$SOC/bm_$SEL.hex"
    python3 "$ROOT/scripts/make_hex.py" "$ELF" "$HEX" 0x80000000 >/dev/null
else
    #------- Linux:镜像 -> hex -------
    ELF="${ELF:-$ROOT/image/biriscv-linux-5.4.elf}"
    HEX="$SOC/image.hex"
    if [ ! -f "$HEX" ] || ! head -1 "$HEX" 2>/dev/null | grep -qF "$(basename "$ELF")"; then
        echo "== 生成 image.hex（来自 $(basename "$ELF")）=="
        python3 "$ROOT/scripts/make_hex.py" "$ELF" "$HEX" 0x80000000
    fi
fi

cd "$SOC"

# 虚拟磁盘:Linux 模式下若勾选(USE_DISK=1)且 disk.hex 存在,加 +DISK。
# 磁盘里的程序由 sdk/linux/mkdisk.sh 编进,开机解到 /opt(无需重建内核)。
DISKARG=""
if [ "$MODE" != "baremetal" ] && [ "$USE_DISK" = "1" ] && [ -f "$SOC/disk.hex" ]; then
    DISKARG="+DISK=$SOC/disk.hex"
    echo "== 虚拟磁盘:挂载 disk.hex(程序将出现在 /opt)=="
fi

# JTAG 调试:GUI 勾「JTAG调试」时传 JTAG=端口,仿真带 +JTAG 开 remote_bitbang
JTAGARG=""
if [ -n "$JTAG" ]; then
    JTAGARG="+JTAG=$JTAG"
    echo "== JTAG 调试:remote_bitbang 监听 :$JTAG(OpenOCD 控制台可连接)=="
fi

if [ -n "$TRACE" ]; then
    TD="${TRACE_DEPTH:-1}"
    TBIN="$SOC/build_vl_trace_d$TD/tb_soc"
    [ -x "$TBIN" ] || TRACE_DEPTH="$TD" ./build.sh verilator-trace
    rm -f "$SOC/tb_soc.fst"
    MAXC="${TRACE_CYCLES:-1000000}"
    echo "== 录波形模式:深度 $TD,跑 $MAXC 周期 -> tb_soc.fst(结束后点「查看波形」)=="
    exec stdbuf -o0 "$TBIN" +IMAGE="$HEX" +INPUT="$INPUT" $DISKARG $JTAGARG \
         +TRACE +VCD="$SOC/tb_soc.fst" +MAX_CYCLES="$MAXC"
else
    [ -x "$SOC/build_vl/tb_soc" ] || ./build.sh
    exec stdbuf -o0 ./build_vl/tb_soc +IMAGE="$HEX" +INPUT="$INPUT" $DISKARG $JTAGARG
fi
