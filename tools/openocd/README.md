# JTAG 调试(OpenOCD 兼容,System Bus Access)

给 QRISC-V996 加的 **OpenOCD 兼容 JTAG 调试模块**。经 JTAG → DMI → Debug Module 的
**System Bus Access(SBA)** 直接读写系统总线上的 **DRAM 与所有外设寄存器**——**不暂停 CPU**。

```
OpenOCD ──TCP(remote_bitbang)──> tb_soc 里 C++ 桥 ──TCK/TMS/TDI/TDO──> jtag_dtm(TAP)
   └── mdw/mww 命令              DMI ──> dm_sba(sbcs/sbaddr/sbdata) ──> AXI 主口 ──> 互联 ──> DRAM/外设
```

> 本平台的 biRISC-V 核**没有调试模式**(无 halt/单步/读 CPU 寄存器)。SBA 不需要核改动,
> 是「不动核」能做到的最大调试能力:读写内存与外设、灌程序、做硬件 bring-up。
> halt/单步/断点需要给核加调试模式(独立的「阶段二」,见末尾)。

## 组成
| 文件 | 作用 |
|---|---|
| `src/soc/debug/jtag_dtm.v` | JTAG TAP/DTM(RISC-V Debug 0.13:IDCODE/DTMCS/DMI 扫描链,单时钟域过采样) |
| `src/soc/debug/dm_sba.v` | Debug Module 子集:dmcontrol/dmstatus + sbcs/sbaddress0/sbdata0 |
| `src/soc/debug/dm_axi_master.v` | SBA 读/写 → AXI4 单拍事务(8/16/32 位),接 soc 空闲 inport |
| `src/soc/debug/riscv_debug.v` | 上述三者的封装顶层(JTAG 4 线 + 1 个 AXI 主口) |
| `tb/tb_soc/jtag_rbb.cpp` | 仿真侧 remote_bitbang TCP 桥(DPI-C) |
| `tb/tb_soc/jtag_selftest.vh` | 不依赖 OpenOCD 的 JTAG/SBA 自测 |
| `tools/openocd/qrisc-v996.cfg` | OpenOCD 配置(remote_bitbang + riscv sysbus) |

## 方式一:自测(不需要 OpenOCD,已验证 PASS)
```bash
cd tb/tb_soc && ./build.sh
./build_vl/tb_soc +IMAGE=image.hex +JTAGTEST +MAX_CYCLES=3000000
```
tb 自己当 JTAG 主机 bit-bang TAP,做 SBA 写/读:
```
用例1  SBA 写 GPIO -> 引脚 gpio_out=0xCAFE0000          PASS
用例2  SBA 写 DRAM 0x80100000=0xA5A51234,读回一致      PASS
用例3  SBA 读 DRAM 0x80000000 = 镜像首指令(非0)        PASS
```

## 方式二:真 OpenOCD 客户端
需要装 OpenOCD(自带 remote_bitbang 驱动):
```bash
sudo apt install -y openocd
```
一键 demo(起仿真 + OpenOCD 批处理读写):
```bash
./tools/openocd/demo.sh
```
或手动两个终端:
```bash
# 终端 A:起仿真,开 JTAG 端口 9999
cd tb/tb_soc && JTAG=9999 ./run.sh
# 终端 B:连 OpenOCD,再 telnet 进交互
openocd -f tools/openocd/qrisc-v996.cfg
telnet localhost 4444
```
进了 OpenOCD telnet(4444)后:
```
> mdw 0x80000000          # 读 DRAM 头(镜像首字)
> mww 0x80100000 0xA5A51234 ; mdw 0x80100000    # 写 DRAM 再读回
> mww 0x94000008 0xCAFE0000     # 写 GPIO 输出(仿真侧 gpio_out 变 0xCAFE0000)
> mdw 0x92000008                # 读 UART 状态寄存器
```

## 参数
- IDCODE:`0xDEB10001`(见 `jtag_dtm.v` 与 `.cfg` 的 `-expected-id`)
- JTAG 端口:仿真用 `+JTAG=<端口>`(或 `JTAG=<端口> ./run.sh`),OpenOCD `.cfg` 里 `remote_bitbang port` 对应
- 内存映射同主平台:DRAM 0x80000000 / irq 0x90000000 / timer 0x91000000 / uart 0x92000000 / spi 0x93000000 / gpio 0x94000000

## 实现要点 / 踩坑
- **单时钟域过采样**:DTM 在系统时钟对 TCK/TMS/TDI 做 2-FF 同步 + 边沿检测,免 TCK/clk 跨时钟域;
  C++ 桥每条命令保持引脚若干系统时钟,保证不漏边沿。
- **AW/W 必须并发**:外设经 axi4_lite_tap 转 AXI-Lite,要求 AW 与 W 同时有效;
  早期「先 AW 再 W」会卡死在 W 阶段(本仓库已修)。
- **响应路由**:arb 按 `bid/rid[3:2]` 路由响应;调试主口用 id=0 接 inport0(=[3:2]=00),自然回路。

## 阶段二(可选,未做):halt/单步/断点
需要给 biRISC-V 核加 **调试模式**(dcsr/dpc/dret、halt 请求进调试 ROM、抽象命令读写 GPR/CSR、
单步、ebreak→debug)。那是对核的较大改动、会与上游 biriscv 分叉,作为独立任务排期。
