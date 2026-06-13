# tb_soc —— biRISC-V + 全 RTL 外设 SoC

> **两种控制台镜像**(同一个内核,只换 dtb,用 [`build-os/build_image.sh`](../../build-os/build_image.sh) 选):
> - **hvc0**(`image/biriscv-linux-5.4-hvc0.elf`,= 默认 `biriscv-linux-5.4.elf`):控制台经 SBI 固件,
>   **稳定、完整可交互**。UART 仍是真 RTL,只是内核隔着 SBI 用它。← 平时用这个。
> - **ttyUL0**(`image/biriscv-linux-5.4-ttyul0.elf`):控制台经**内核自带 uartlite 驱动**直接驱动真 UART,
>   中断经 irq_ctrl(Xilinx INTC)。**✅ 已完全可交互**(启动到 shell + `uname -a`/`cat /proc/cpuinfo`/`ls`
>   双向都走真 RTL 中断路径,实测通过)。比 hvc0 慢(每字符一次陷入+ISR),详见文末「ttyUL0 状态」。
>
> ```bash
> ELF=image/biriscv-linux-5.4-hvc0.elf   ./tb/tb_soc/run.sh   # 稳定可交互(默认)
> ELF=image/biriscv-linux-5.4-ttyul0.elf ./tb/tb_soc/run.sh   # 真驱动 WIP
> ```

这里把 **UART、Timer、GPIO、SPI、中断控制器都做成真 RTL**(取自 ultraembedded/riscv_soc,
现在在 [`src/soc/`](../../src/soc)),而不是 C++/行为模型。biRISC-V 核挂在 riscv_soc 的
AXI 互联(arb→tap)上,外设是真寄存器、真逻辑;**UART 的输出是从真实串行线 `uart_tx`
一位一位移出来的**,testbench 只像示波器一样把它反序列化成字节打印。

```
   ┌──────────── biriscv_soc (DUT) ────────────────────────────────┐
   │  biRISC-V riscv_top ──(cpu_i/cpu_d AXI)──► axi4_arb ─► axi4_tap │
   │   (含 i/d-cache)                                  │            │
   │                       0x80000000.. (else) ────────┤► mem_* ────┼──► axi4_ram (DRAM, tb)
   │                       0x90000000 irq_ctrl  ◄───────┤            │
   │                       0x91000000 timer     ◄───────┤            │
   │                       0x92000000 uart_lite ◄───────┤  真RTL外设  │──► uart_tx (真串行)
   │                       0x93000000 spi_lite  ◄───────┤            │
   │                       0x94000000 gpio      ◄───────┘            │
   │   irq_ctrl ─(intr)─► core                                       │
   └────────────────────────────────────────────────────────────────┘
                                                          tb 反序列化 uart_tx → stdout
```

## 文件(本目录只剩 testbench;设计已挪到 src/)
| 文件 | 作用 |
|---|---|
| `tb_soc.v`      | testbench:时钟/复位 + DRAM + **UART 串行反序列化器**(8N1, BIT_DIV=24) + JTAG 桥 + 调试自测 |
| `axi4_ram.v`    | 行为级 AXI4 burst DRAM(承接 `mem_*`,自己 `$readmemh` 装 +IMAGE/+DISK 镜像) |
| `jtag_rbb.cpp`  | JTAG remote_bitbang TCP 桥(DPI-C):OpenOCD 经它 bit-bang 驱动 JTAG TAP |
| `dbg_fast_test.vh` | 快速调试自测(`+DBGTEST`):直驱 DMI 跑 halt/寄存器/单步/软件断点 |
| `jtag_selftest.vh` | 经真 JTAG TAP 的 SBA + halt/寄存器自测(`+JTAGTEST`) |
| `build.sh`/`run.sh` | 编译 / 运行 |

> DUT `biriscv_soc.v`(集成顶层)+ riscv_soc 外设互联现在都在
> [`src/soc/`](../../src/soc);`build.sh` 从那里取设计。
| `build.sh`/`run.sh` | 构建/运行(verilator 默认) |

## 用法
```bash
./build.sh            # verilator --binary --timing 编译(纯RTL,无C++ harness)
./run.sh              # 启动 Linux,UART 输出来自真串行线
# 调试 AXI 互联时:
./build.sh && ./build_vl/tb_soc +IMAGE=image.hex +PROBE      # 打开取指/访存/R通道计数探针
ELF=other.elf ./run.sh ; MAX_CYCLES=300000 ./run.sh ; TRACE=1 ./run.sh
```

### JTAG 调试(OpenOCD / GDB)
tb 内置 JTAG remote_bitbang 桥(`jtag_rbb.cpp`),让 OpenOCD 经 TCP bit-bang 驱动 SoC 的
JTAG 调试模块([`src/soc/debug/`](../../src/soc/debug))。两种自测 + 真 OpenOCD 入口:
```bash
# 1) 快速自测(直驱 DMI,不需要 OpenOCD;期望 dbg_result.txt 里 ERR=0)
./build_vl/tb_soc +IMAGE=image.hex +DBGTEST  +MAX_CYCLES=2000000
# 2) 经真 JTAG TAP 的自测(SBA + halt + 寄存器读写)
./build_vl/tb_soc +IMAGE=image.hex +JTAGTEST +MAX_CYCLES=3000000
# 3) 开 JTAG 端口供 OpenOCD/GDB 远程连(remote_bitbang)
JTAG=9999 ./run.sh        # 再起 openocd -f tools/openocd/qrisc-v996.cfg
```
桥支持 OpenOCD **反复连接/断开**(一个 OpenOCD 退出后仿真继续,下一个可直接再连)。
> 连不上、报 `Bad file descriptor`?是残留 openocd 占着连接槽 —— `pkill -9 openocd` 再连。
> (改 `jtag_rbb.cpp` 后记得 `./build.sh` 重编,否则还是旧的一次性连接行为。)

完整 OpenOCD/GDB 流程见 [`tools/openocd/README.md`](../../tools/openocd/README.md)。

## ⚠️ 关键修复:biRISC-V 过 riscv_soc 互联的 AXI ID(否则 fetch stall)
直接把 biRISC-V 塞进 riscv_soc 会**在第一条 cache line 取指后卡死、跑 0 条指令**。
根因在 `rtl/axi4_arb.v`:它按 **读响应 ID 的高 2 位 `rid[3:2]`** 把响应路由回某个 inport,
但转发 AR 时 **不改 ID**(原样透传 master 的 arid)。soc.v 的接法是 `inport1=cpu_d,
inport2=cpu_i`,于是要求:

| master | 接到 arb | 需要 ID[3:2] | 设的 AXI_ID |
|---|---|---|---|
| icache (cpu_i) | inport2 | `2'b10` | **8** |
| dcache (cpu_d) | inport1 | `2'b01` | **4** |

而 biRISC-V 默认 `ICACHE_AXI_ID = DCACHE_AXI_ID = 0` → 响应全被路由到 inport0(没接核)→
读数据永远回不到 icache → stall。修复就是在 `biriscv_soc.v` 里给核传
`.ICACHE_AXI_ID(4'd8)`、`.DCACHE_AXI_ID(4'd4)`。改完即可一路启动到 shell。

诊断方法(留作参考):`+PROBE` 打开后能看到 `mem_R`(DRAM 发出的读拍)持续增长但
`core_R`(icache 收到的读拍)恒为 0 —— 说明读数据死在互联里,据此定位到 arb 的 rid 路由。

## 为什么是 tb_soc(早两代已删)
早期有 `tb_top`(SystemC+C++,UART/内存都是 C++ 模型)和 `tb_rtl`(纯 RTL 但 UART 是
tb 内 MMIO 钩子、无真外设)。两代都已被 **tb_soc** 取代并删除:tb_soc 的 UART/Timer/
GPIO/SPI/中断控制器**全是真 RTL**,UART 输出是**真串行线一位位反序列化**,且支持
**真中断驱动路径(ttyUL0)**——前两代都做不到。通用 ELF→hex 工具已移到
[`scripts/make_hex.py`](../../scripts)。

## 交互输入(已支持,真串行)
tb 里有一个串行**发送器**:把 `+INPUT` 文件里的字符按 8N1/BIT_DIV 一位位移进真
uart_lite 的 `rx_i` 引脚 → SBI getchar → hvc0 → shell。字符源用「重开文件+fseek」,
所以可在另一个终端 `echo 'ls /' >> live.txt` 实时发命令。

```bash
# 命令行:
: > live.txt
INPUT=live.txt ./run.sh
# 另一个终端,看到 ~ # 后:
echo 'uname -a' >> live.txt

# 或直接用 GUI(推荐):
python3 ../../gui/biriscv_soc_console.py
```

**★ 流控(关键)**:Linux 的 hvc0 是自适应轮询,空闲时最慢隔数秒才读一次 UART,
而 uart_lite RX 只有 1 深缓冲。所以发送器**盯着 `u_dut.u_soc.u_uart.rx_ready_q`**
(收满=1,内核读 RX 寄存器后=0),只有上一个字符被读空才发下一个 —— 无论内核多久
轮询都不丢字。实测 `uname -a / ls / cat /proc/cpuinfo` 命令文本回显 + 输出全部完整。

## GUI
[`gui/biriscv_soc_console.py`](../../gui/biriscv_soc_console.py)(+ `run_soc_backend.sh`)
是 tb_soc 的 Tkinter 控制台:启动按钮 / 输出窗 / 输入框 / 历史命令 / Ctrl-C / 虚拟磁盘 /
录波形。输入走文件追加(由上面的串行发送器送入)。需 `python3-tk`。详见 [`gui/README.md`](../../gui/README.md)。

## ttyUL0 状态(内核直接驱动 uartlite,WIP)
目标:让内核自带的 uartlite 驱动 + Xilinx INTC 驱动直接驱动真 UART(中断驱动),不经 SBI。

**已做的改动**(都在仓库里,可复现):
- `~/rvlinux/linux-5.4/drivers/irqchip/irq-xilinx-intc.c`:打补丁,primary 模式调 `set_handle_irq()`
  + 加根中断处理函数,让自定义 `irq_ctrl`(=Xilinx XPS INTC)能在 **RISC-V 5.4 上当根中断控制器**
  (5.4 无 `riscv,cpu-intc` domain;原驱动只支持 MicroBlaze)。Kconfig 给 `XILINX_INTC` 加 prompt。
- 内核 config(见 [`build-os/_kernel54.sh`](../../build-os/_kernel54.sh)):开 `CONFIG_XILINX_INTC` /
  `CONFIG_SERIAL_UARTLITE` / `_CONSOLE`。
- dts([`build-os/dts/config32_ttyul0.dts`](../../build-os/dts/config32_ttyul0.dts)):加 `intc`(xps-intc @0x90000000)
  + `uart0`(uartlite @0x92000000,中断接 intc 第 1 号线),`console=ttyUL0`。

**已验证工作**:
- intc 驱动初始化 `irq-xilinx: num_irq=4`;uartlite probe `ttyUL0 at MMIO 0x92000000 (irq=1)`;
- `console [ttyUL0] enabled`,**整段内核启动日志经真 uartlite 驱动(polled)输出**;
- SBI 固件 `mideleg` 把外部中断委托给 S 态;uart 每字符触发一次中断(硬件链路通)。

**关键根因(biriscv 核 sticky SEIP)——已修复**:`src/core/biriscv_csr_regfile.v` 里
`csr_mip_r = csr_mip_r | csr_mip_next_r`(只 OR、永不清),而 `mip.SEIP` 对软件只读,所以
外部中断一置位 SEIP 就**永久粘住** → 外部中断只触发 1 次后核陷在幽灵 pending 上。修复:在 OR 前
清掉 `csr_mip_r[MEIP]/[SEIP]`,让它们电平跟随 `ext_intr_i`(timer/软件位不动;hvc0 无外部中断不受影响)。
**这是个真实的 biriscv RTL bug**——任何用它做中断驱动外设的人都会踩。修复后外部中断能链式触发,
ttyUL0 完整启动到 shell 并双向交互。

**之前误判为"挂死"其实是"慢 + 显示假象"**:中断驱动每输出一个字符要一次 CPU 陷入 + ISR(开 MMU 还会
页表遍历),比 hvc0 的轮询慢得多;再加上 tb 的反序列化器原本会丢中断驱动 TX 的**背靠背(无间隔)字符**,
两者叠加让"慢"看着像"死"。**已加固反序列化器**(采样停止位、消除 U_DONE 延迟,背靠背不丢)。

**调试工具(保留,调 RTL 有用)**:tb 的 `+PROBE`(数 intr_edges/intr_hi/tx_wr/tx_chars + 打印
intc pending/enable、uart rx_ready)、`+EVLOG=<周期>`(逐事件记录 TX 写/IAR ack/intr 边沿);
隔离镜像 `build-os/dts/config32_diag.dts`(console=hvc0 + uart0/intc 节点)可 `echo >/dev/ttyUL0`
单独测中断驱动 TX(initramfs 有静态 `/dev/ttyUL0` 节点 `c 204 187`,已在 `_kernel54.sh`)。

> 小瑕疵:交互时偶有首条命令的**第一个字符**丢失(首字符 RX 时序边沿),重敲即可;不影响后续。
