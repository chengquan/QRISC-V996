#!/bin/bash
#-----------------------------------------------------------------
# QRISC-V996 JTAG 调试 demo:起仿真(带 JTAG)+ 用 OpenOCD 批处理读写内存/外设。
# 证明 OpenOCD 经 JTAG 的 System Bus Access 能读写 DRAM 与外设(不暂停 CPU)。
#
#   ./demo.sh            # 需已装 openocd
#-----------------------------------------------------------------
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
PORT=9999

command -v openocd >/dev/null || { echo "缺 openocd: sudo apt install -y openocd"; exit 1; }
[ -x "$ROOT/tb/tb_soc/build_vl/tb_soc" ] || (cd "$ROOT/tb/tb_soc" && ./build.sh)

# 生成 image.hex(若需要)
HEX="$ROOT/tb/tb_soc/image.hex"
[ -f "$HEX" ] || python3 "$ROOT/scripts/make_hex.py" "$ROOT/image/biriscv-linux-5.4.elf" "$HEX" 0x80000000

echo "== 1) 起仿真(JTAG 端口 $PORT)=="
( cd "$ROOT/tb/tb_soc" && stdbuf -o0 ./build_vl/tb_soc +IMAGE=image.hex +JTAG=$PORT +MAX_CYCLES=50000000 \
    > /tmp/qrisc_jtag_sim.log 2>&1 ) &
SIM=$!
trap "kill $SIM 2>/dev/null" EXIT

# 等仿真把 JTAG 监听起来
for i in $(seq 1 30); do grep -qa "remote_bitbang 连" /tmp/qrisc_jtag_sim.log && break; sleep 1; done

echo "== 2) OpenOCD 批处理:读写 DRAM 与 GPIO =="
openocd -f "$HERE/qrisc-v996.cfg" \
  -c "mdw 0x80000000" \
  -c "echo {--- 写 DRAM 暂存 0x80100000 = 0xA5A51234 ---}" \
  -c "mww 0x80100000 0xA5A51234" \
  -c "mdw 0x80100000" \
  -c "echo {--- 写 GPIO 输出 0x94000008 = 0xCAFE0000(看仿真侧 gpio_out)---}" \
  -c "mww 0x94000008 0xCAFE0000" \
  -c "echo {--- 读外设区(timer/uart 状态等)---}" \
  -c "mdw 0x91000000" \
  -c "shutdown"

echo "== 3) 仿真侧日志尾部(看是否收到 JTAG 连接)=="
tail -5 /tmp/qrisc_jtag_sim.log
echo "== 完成 =="
