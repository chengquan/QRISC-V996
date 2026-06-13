# QRISC-V996 —— 开箱即跑的 RV32 Linux SoC 仿真平台

**QRISC-V996** 是一个完整的 RISC-V SoC 平台:把一个从源码自编的 **RV32IMA Linux 5.4**
跑在 **biRISC-V** 双发射核 + 一整套**真 RTL 外设**(UART / Timer / GPIO / SPI / 中断
控制器)的周期级仿真上,配套 SBI 引导器、裸机/Linux 双线 SDK、虚拟磁盘、一个串口
控制台 GUI,以及一个 **OpenOCD/GDB 兼容的 JTAG 调试模块**(halt/单步/断点/读写寄存器/
内存)。在 **WSL / Linux** 上跑。

> 命名:**QRISC-V996** = 整个平台/发行;**biRISC-V** = 其采用的 CPU 核
> (源自 [ultraembedded/biriscv](https://github.com/ultraembedded/biriscv),保留原名以示署名)。

```
   ┌──────────────┐  stdin/stdout(串口) ┌─────────────────────────────────────────┐
   │ GUI / 终端    │ ───────────────────▶ │ tb_soc (Verilator 纯 RTL)                 │
   │ (敲命令)      │ ◀─────────────────── │   biRISC-V 核 + riscv_soc 全 RTL 外设      │
   └──────────────┘                      │   加载 image/biriscv-linux-5.4(SBI+内核) │
                                         └─────────────────────────────────────────┘
```

## 目录结构
```
QRISC-V996/
├── src/               RTL 设计
│   ├── core/ top/ icache/ dcache/ tcm/   biRISC-V 双发射核
│   └── soc/                              riscv_soc 外设+互联 + biriscv_soc 集成顶层
│       └── debug/                        JTAG 调试模块(jtag_dtm/dm_sba/dm_axi_master/riscv_debug)
├── tb/tb_soc/         测试平台(tb_soc.v + 行为级 AXI4 DRAM axi4_ram.v + JTAG remote_bitbang 桥)
├── tools/openocd/     OpenOCD 配置 + GDB 调试说明(qrisc-v996.cfg)
├── bootloader/        SBI 引导器源码(源自 ultraembedded/riscv-linux-boot)
├── build-os/          从源码重建 OS:Makefile + 脚本 + 内核/busybox 配置 + 内核补丁 + dts
├── sdk/               给本平台写程序:baremetal/(裸机) + linux/(用户态)
├── scripts/make_hex.py  ELF → $readmemh hex(零依赖)
├── gui/               Tkinter 串口控制台 + 后端
├── image/             预编译 OS 镜像(hvc0 / ttyul0,clone 即可跑)
└── docs/              操作 / 从零重建指南(PDF)
```

## 快速开始(用预编译镜像,免编内核)

```bash
# 1. 依赖
sudo apt install -y verilator gtkwave python3-tk device-tree-compiler \
                    gcc-riscv64-unknown-elf
# 2. 构建仿真器(纯 RTL,Verilator)
cd tb/tb_soc && ./build.sh && cd ../..
# 3a. GUI(推荐,WSLg 自带图形)
python3 gui/biriscv_soc_console.py
# 3b. 或命令行
./tb/tb_soc/run.sh
```
到 `~ #` 提示符后敲命令(`uname -a`、`ls`、`cat /proc/cpuinfo` …)。

> ⏱️ 周期级 RTL 仿真较慢,启动到 shell 需要几十秒到几分钟(取决于控制台变体)。

### 两个控制台变体(image/)
| 镜像 | 控制台 | 说明 |
|---|---|---|
| `…-hvc0.elf`(默认) | SBI(hvc0) | 轮询式,**快**;UART 仍是真 RTL,但内核经 SBI 用它 |
| `…-ttyul0.elf` | 内核 uartlite 驱动(ttyUL0) | **真中断驱动路径**(irq_ctrl + uartlite),慢但最真实 |

GUI 里「模式 = Linux」时可在下拉选 hvc0 / ttyUL0。

## SDK —— 给平台写程序(详见 [sdk/README.md](sdk/README.md))

- **裸机**(`sdk/baremetal/`):直接在核上跑、无 OS,直写 MMIO 操作 UART/GPIO/SPI。
  `./build_run.sh examples/gpio.c` —— 几秒出结果。
- **Linux**(`sdk/linux/`):作为进程跑,经 `/dev/mem` mmap 操作外设。两条送入方式:
  - **虚拟磁盘**(推荐):`./mkdisk.sh` 把程序打进 `disk.hex`,开机解到 `/opt` ——
    改程序只重建磁盘(~几秒),**不用重建内核**。GUI 勾「虚拟磁盘」即用。
  - **烤进 initramfs**:`./build_install.sh` 把程序进 `/usr/bin`,随内核镜像走(增量重建 ~1-2 分钟)。

## JTAG 调试(OpenOCD / GDB,详见 [tools/openocd/README.md](tools/openocd/README.md))

平台带一个 **OpenOCD 兼容的 JTAG 调试模块**(RISC-V Debug Spec 0.13:JTAG DTM → DMI →
Debug Module),支持 **halt/resume、单步、软件断点(ebreak)、读写 GPR·CSR、System Bus
Access(读写内存/外设)**。调试不激活时门控信号恒 0,**Linux 正常启动不受影响**。

```bash
# 1) 快速自测(不需要 OpenOCD,已验证全 PASS)
cd tb/tb_soc
./build_vl/tb_soc +IMAGE=image.hex +DBGTEST   # 直驱 DMI:halt/寄存器/单步/断点,7 项 PASS
./build_vl/tb_soc +IMAGE=image.hex +JTAGTEST  # 经真 JTAG TAP 的 SBA + halt/寄存器自测

# 2) 真 OpenOCD 客户端(实测 examine 通过、halt/reg/step/mdw 可用)
JTAG=9999 ./run.sh                            # 终端 A:起仿真,开 JTAG 端口
openocd -f tools/openocd/qrisc-v996.cfg       # 终端 B:连 OpenOCD(gdb server 起在 :3333)

# 3) GDB(实测 gdb-multiarch 端到端通过)
gdb-multiarch vmlinux
(gdb) set arch riscv:rv32
(gdb) target extended-remote :3333            # 读写寄存器/内存、单步均可
```
> 也可用 GUI:勾「JTAG调试」启动后,底部 OpenOCD 面板有 halt/单步/断点/寄存器/启动GDB 按钮。
> 连不上或命令没反应?多半是残留 openocd 占着连接槽 —— `pkill -9 openocd` 再连(桥支持重连)。

## 从源码重建整个 OS(可选)

工程含完整重建链;体积巨大的外部源码(Linux 5.4 / BusyBox / 工具链)不入库,
由 `build-os/Makefile` 拉取:
```bash
make -C build-os clone_toolchain build_gcc_linux   # 自建 rv32ima-linux GCC(慢)
make -C build-os clone_kernel clone_busybox        # Linux v5.4 + BusyBox 1.37.0 源码
make -C build-os busybox kernel image              # rootfs → 内核 → 可引导镜像
```
`build-os/_kernel54.sh` 会自动套用本平台的内核改动(Xilinx INTC 根中断处理器、
CSR 旧名/zicsr 补丁、配置),无需手改内核源码。完整背景见
**`docs/QRISC-V996-操作指南.pdf`**。

> ⚠️ 内核必须 **≥ 5.4**:现代 rv32 glibc 用 64 位 time_t,需要 5.1+ 的 time64
> 系统调用;5.0 能启动但用户态僵死。

## 验证这是真·自编系统
```sh
~ # cat /proc/version      # 编译者@编译机 + 时刻烙进二进制,造不了假
~ # cat /proc/cpuinfo      # isa: rv32ima  mmu: sv32  ← biRISC-V 核
```

## 致谢 / 上游
- CPU 核 RTL:[ultraembedded/biriscv](https://github.com/ultraembedded/biriscv)
- SoC 外设/互联 RTL:[ultraembedded/riscv_soc](https://github.com/ultraembedded/riscv_soc)
- SBI 引导器:[ultraembedded/riscv-linux-boot](https://github.com/ultraembedded/riscv-linux-boot)
- Linux 5.4 · BusyBox 1.37.0 · RISC-V GNU 工具链(均自源码编译)
