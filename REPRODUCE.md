# QRISC-V996 —— 完整复现指南

从零把 **QRISC-V996**(biRISC-V 双发射核 + 全 RTL 外设 SoC，跑自编 RV32IMA Linux 5.4）
在 **WSL / Linux** 上跑起来、写程序、看波形、从源码重建 OS。照着这篇即可复现。

> 速览看 [README.md](README.md)；各子系统细节看各文件夹的 README。本文是端到端总流程。

---

## 0. 名词与全景

| 名字 | 是什么 |
|---|---|
| **QRISC-V996** | 整个平台/发行（本工程） |
| **biRISC-V** | 采用的 CPU 核（[ultraembedded/biriscv](https://github.com/ultraembedded/biriscv)，RV32IMA 双发射，i/d-cache，sv32 MMU） |
| **riscv_soc** | 外设 + AXI 互联（[ultraembedded/riscv_soc](https://github.com/ultraembedded/riscv_soc)：uart_lite/timer/gpio/spi/irq_ctrl） |
| **SBI 引导器** | `bootloader/`（源自 ultraembedded/riscv-linux-boot）：把 vmlinux+dtb 打成可引导 ELF，M 态模拟原子指令、提供 hvc0 控制台 |
| **tb_soc** | 纯 Verilog 测试平台（Verilator），DUT = biRISC-V + 全 RTL 外设 |
| **JTAG 调试** | `src/soc/debug/`：OpenOCD 兼容的 JTAG DTM → DMI → Debug Module(`dm_sba.v`)，支持 halt/单步/断点/读写寄存器/内存。详见 [tools/openocd/README.md](tools/openocd/README.md) |

数据流：
```
GUI/终端 ──串口字节──> tb_soc(Verilator: biRISC-V核 + riscv_soc外设) ──加载──> image/*.elf(SBI+内核+initramfs)
```

内存映射：DRAM `0x80000000`（内核 32MB；仿真 36MB，顶部 4MB `0x82000000` 给虚拟磁盘）·
irq_ctrl `0x90000000` · timer `0x91000000` · uart_lite `0x92000000` · spi `0x93000000` · gpio `0x94000000`。

---

## 1. 装依赖（Ubuntu / WSL）

```bash
sudo apt update
sudo apt install -y \
    verilator gtkwave device-tree-compiler \
    python3 python3-tk \
    gcc-riscv64-unknown-elf \
    build-essential git
```
- `verilator` 跑仿真；`gtkwave` 看波形；`device-tree-compiler`(dtc) 编 dts。
- `python3-tk` 给 GUI；`gcc-riscv64-unknown-elf` 给裸机 SDK。
- **JTAG 调试（可选，§7）还需**：`openocd`（0.12+）+ 一个 RISC-V gdb（`gdb-multiarch` 或工具链自带的 `riscv32-unknown-elf-gdb`）。
- **重建 Linux 还需** rv32ima-linux glibc 工具链（自建，见 §5），跑预编译镜像不需要。

WSL 图形（GUI）：Windows 11 的 WSLg 自带；老环境需 X server。

---

## 2. 跑预编译镜像（最快，免编内核）

工程自带编好的 OS 镜像（`image/`），clone 即可跑。

```bash
# 编译仿真器（纯 RTL，Verilator，一次，~1-2 分钟）
cd tb/tb_soc && ./build.sh && cd ../..

# 方式 A：GUI（推荐）
python3 gui/biriscv_soc_console.py
#   → 模式选 Linux、选 hvc0、点 ▶启动，等到 ~ # 提示符

# 方式 B：命令行
./tb/tb_soc/run.sh
```

到 `~ #` 后试：
```sh
uname -a
cat /proc/cpuinfo      # isa: rv32ima  mmu: sv32  ← biRISC-V 核
ls /
```

> ⏱️ 周期级 RTL 仿真慢，到 shell 几十秒~几分钟。**命令首字符偶尔被吃**
> （`ls`→`s`）：敲命令前**留一个空格**即可。

### 两个控制台变体
| 镜像 | 控制台 | 特点 |
|---|---|---|
| `image/biriscv-linux-5.4-hvc0.elf`（默认） | SBI(hvc0) | 轮询，**快** |
| `image/biriscv-linux-5.4-ttyul0.elf` | 内核 uartlite 驱动(ttyUL0) | **真中断路径**(irq_ctrl+uartlite)，慢但最真实 |

命令行切换：`ELF=image/biriscv-linux-5.4-ttyul0.elf ./tb/tb_soc/run.sh`；
GUI 里「模式=Linux」下拉选。

---

## 3. 写程序：裸机（无 OS，最快迭代）

直接在核上跑、直写 MMIO 操作外设。详见 [sdk/baremetal/README.md](sdk/baremetal/README.md)。

```bash
cd sdk/baremetal
./build_run.sh examples/hello_uart.c     # 编译 + 跑，几秒出 UART 输出
./build_run.sh examples/gpio.c           # 翻转 GPIO
TRACE=1 ./build_run.sh examples/gpio.c   # 录波形看 gpio_out 引脚
```
写自己的：`examples/` 放个 `.c`（`#include "../bm.h"`，写 `int main()`），
`./build_run.sh examples/你的.c`。GUI 里「模式=裸机」也能选着跑。

---

## 4. 写程序：Linux 用户态（两条路）

详见 [sdk/linux/README.md](sdk/linux/README.md)。经 `/dev/mem` mmap 操作外设。

### 路 A：虚拟磁盘（推荐，改程序不重建内核，~几秒）
```bash
cd sdk/linux
./mkdisk.sh                  # 编 examples/ → tb/tb_soc/disk.hex
```
GUI（Linux 模式）勾「虚拟磁盘」启动 → `~ #` 后：
```sh
 ls /opt                     # gpio_mmap  hello   （前面留空格防吃字符）
 hello
 gpio_mmap
```
改完程序只重跑 `./mkdisk.sh` + 重启仿真，**内核不动**。

**`disk.hex` 是怎么生成的**（`mkdisk.sh` 内部这条链，全自动）：

```
sdk/linux/examples/*.c
   │  ① riscv32-unknown-linux-gnu-gcc -static + strip        （编成静态 RV32 可执行）
   ▼
sdk/linux/build/disk/{hello,gpio_mmap,...}
   │  ② mkcpio.py  打成 newc 格式 cpio                        （主机无 cpio，用 Python 自造）
   ▼
sdk/linux/build/disk.cpio   （上限 4MB，超了会报错）
   │  ③ bin2hex.py  原始二进制 → $readmemh hex，落在 0x82000000
   ▼
tb/tb_soc/disk.hex
```

三个脚本都在 `sdk/linux/`：`mkdisk.sh`(总控) · `mkcpio.py`(打 cpio) · `bin2hex.py`(转 hex)。
手动等价于：
```bash
cd sdk/linux
riscv32-unknown-linux-gnu-gcc -march=rv32ima -mabi=ilp32 -O2 -static \
    examples/hello.c -o build/disk/hello          # ① 编译(可再 strip 缩小)
python3 mkcpio.py build/disk build/disk.cpio       # ② 目录 → newc cpio
python3 bin2hex.py build/disk.cpio ../../tb/tb_soc/disk.hex 0x82000000   # ③ → hex@0x82000000
```

**然后整条链怎么用起来**：
```
disk.hex ──tb 加载(+DISK)──> DRAM 0x82000000  ──开机 /init: vdiskcat | cpio──> /opt/{程序}
```
- tb 用 `+DISK=disk.hex` 把它 `$readmemh` 进 DRAM 顶部（hex 自带 `@0x800000` 词偏移，与内核
  `image.hex` 同一片内存不冲突）；GUI 勾「虚拟磁盘」即自动加 `+DISK`。
- 开机 `/init` 用 `vdiskcat`（经 `/dev/mem` **mmap** 读 0x82000000，因为 read() 读不到
  内核 RAM 之外）把 cpio 解到 `/opt`，并加进 PATH。
- 放 0x82000000 是因为内核镜像本身已占满约 31MB，32MB 内腾不出空间，所以把仿真内存扩到
  36MB、磁盘放在内核 RAM 之外那 4MB。

### 路 B：烤进 initramfs（随镜像分发，增量重建内核 ~1-2 分钟）
```bash
cd sdk/linux
./build_install.sh           # 编 + 装进 rootfs/usr/bin + 重建内核镜像
```
程序进 `/usr/bin`。需自建好 Linux 工具链（§5）。

---

## 5. 从源码重建整个 OS（可选）

外部源码（Linux 5.4 / BusyBox / 工具链）不入库，由 `build-os/Makefile` 拉取。
详见 [build-os/README.md](build-os/README.md)。

```bash
# 1) RISC-V 工具链：拉源码 + 自建 rv32ima-linux GCC（慢，~1 小时）
make -C build-os clone_toolchain
make -C build-os build_gcc_linux        # 装到 ~/rvlinux/toolchain/riscv32ima-linux

# 2) 内核 5.4 + BusyBox 1.37.0 源码
make -C build-os clone_kernel           # torvalds/linux @ v5.4 -> ~/rvlinux/linux-5.4
make -C build-os clone_busybox          # busybox @ 1_37_0   -> ~/rvlinux/busybox

# 3) 构建（用 build-os/ 里的配置/补丁/dts）
make -C build-os busybox                # 静态 rootfs
make -C build-os kernel                 # 套补丁 + 编 vmlinux
make -C build-os image                  # 打 hvc0 + ttyUL0 镜像 -> image/
```

`_kernel54.sh` 会**自动套用本平台的内核改动**（无需手改内核源码）：
- Xilinx INTC 驱动加根中断处理器（`kernel-patches/irq-xilinx-intc.c` 覆盖进去）；
- Kconfig 让 `XILINX_INTC` 在 RISC-V 可选；
- arch/riscv/Makefile 加 `_zicsr_zifencei`、CSR 旧名 `sbadaddr→stval` 等（GCC16/binutils）；
- 写 `/init`（解虚拟磁盘到 /opt、起 shell）、设备节点、`/etc/passwd`、烤入 `vdiskcat`。

> ⚠️ 内核必须 **≥ 5.4**：现代 rv32 glibc 用 64 位 time_t，需要 5.1+ 的 time64
> 系统调用；5.0 能启动但用户态僵死。

---

## 6. 录波形

GUI 勾「录波形」+ 选深度（顶层/更深）+ 周期 → 启动 → 跑到周期后自停 → 「📊 查看波形」开 gtkwave。
- 输出 FST 格式（比 VCD 小 ~20 倍）。
- 深度 1 = 只顶层（DRAM 的 AXI / UART 串行线 / 中断，最小最快）；更深看 SoC 内部接口。
- 裸机模式录波形最适合看 GPIO/SPI 引脚时序。

命令行：`TRACE=1 ./tb/tb_soc/run.sh`（产 `tb_soc.fst`），或裸机 `TRACE=1 ./build_run.sh ...`。

---

## 7. JTAG 调试（OpenOCD / GDB）

平台带一个 **OpenOCD 兼容的 JTAG 调试模块**(RISC-V Debug Spec 0.13)：JTAG DTM → DMI →
Debug Module(`dm_sba.v`)。支持 **halt/resume、单步、软件断点(ebreak)、读写 GPR·CSR、
System Bus Access（读写内存/外设，不暂停核）**。调试不激活时所有门控信号恒 0，
**Linux 正常启动不受影响**（已回归确认）。完整说明见 [tools/openocd/README.md](tools/openocd/README.md)。

### 7.1 快速自测（不需要 OpenOCD，已验证全 PASS）
直驱 DMI，几千周期跑完 halt→读 misa/dpc→读写 GPR→单步→软件断点：
```bash
cd tb/tb_soc
./build_vl/tb_soc +IMAGE=image.hex +DBGTEST +MAX_CYCLES=2000000
cat dbg_result.txt      # 期望 ERR=0,7 项全 PASS
```
另有经真实 JTAG TAP 的 SBA + halt/寄存器自测：
```bash
./build_vl/tb_soc +IMAGE=image.hex +JTAGTEST +MAX_CYCLES=3000000   # 全 PASS
```

### 7.2 真 OpenOCD 客户端（实测 examine 通过）
两个终端：
```bash
# 终端 A：起仿真，开 JTAG 端口 9999
cd tb/tb_soc && JTAG=9999 ./run.sh
# 终端 B：连 OpenOCD（examine 通过、gdb server 起在 :3333）
openocd -f tools/openocd/qrisc-v996.cfg
```
标准 OpenOCD 命令实测可用（telnet localhost 4444 或 GDB 的 `monitor`）：
```
halt ; reg pc            # pc (/32): 0x...
step ; reg pc            # 单步,PC +4
mdw 0x80000000           # 经 SBA 读内存 = 0x15c0006f
resume
```
桥支持 OpenOCD 反复连/断（一个退出后仿真继续，下一个直接再连）。
> **连不上 / 命令没反应**：报 `Bad file descriptor` 是残留 openocd 占着连接槽 —— `pkill -9 openocd`
> 再连。改 `jtag_rbb.cpp` 后需 `cd tb/tb_soc && ./build.sh` 重编(否则还是旧的一次性连接)。

### 7.3 GDB（实测 gdb-multiarch 端到端通过）
```bash
gdb-multiarch vmlinux                  # 或你的 .elf
(gdb) set arch riscv:rv32
(gdb) set remotetimeout 300            # 仿真 bit-bang JTAG 慢,超时调大
(gdb) target extended-remote :3333
(gdb) info reg pc sp ra a0             # 读寄存器(已实测)
(gdb) x/2xw 0x80000000                 # 读内存,首字 0x15c0006f(已实测)
(gdb) set $a0 = 0x1234abcd             # 写寄存器(已实测,读回一致)
(gdb) monitor step                     # 单步(PC 前进;比 GDB 自带 stepi 在仿真里快得多)
```
> 仿真里 JTAG 逐位过采样,GDB 自带 `stepi` 每步要多轮 DMI + 全寄存器回读、耗时数秒(触发
> OpenOCD keep_alive warning,会重试)；用 `monitor step` 走 OpenOCD 侧单步更快。真实 FPGA 上
> JTAG 是并行硬件,`stepi` 也会很快。

---

## 8. 常见问题

| 现象 | 原因 / 解决 |
|---|---|
| 命令首字符被吃（`ls`→`s`） | tb 串行注入在提示符那一刻的时序边界；**命令前留个空格**。 |
| `/opt` 是空的 | 没勾「虚拟磁盘」或没加 `+DISK`；或没跑 `mkdisk.sh`。开机有「虚拟磁盘已挂载到 /opt」才算挂上。 |
| 中文/`ls` 颜色乱码 | 旧版问题，现 GUI 已做增量 UTF-8 解码 + 去 `\r` + 剥 ANSI；用最新 `gui/`。 |
| GUI 标题栏方块 | WSLg 窗口管理器字体无中文字形；标题已改纯 ASCII。 |
| GUI 窗口看不见 | WSLg 开到屏外：`xdotool search --name QRISC-V windowmove 60 60 windowactivate`。 |
| ttyUL0 很慢 | 真中断驱动每字符一次 trap+ISR，本就慢；要快用 hvc0。 |
| `whoami: unknown uid 0` | 缺 `/etc/passwd`；已在 rootfs 里加（重建内核后生效）。 |
| 取指 stall / 启动卡死 | AXI ID 路由：`biriscv_soc.v` 必须给核传 `ICACHE_AXI_ID=8 / DCACHE_AXI_ID=4`（已设）。 |
| 外部中断只来一次后卡死 | sticky-SEIP：`biriscv_csr_regfile.v` 需电平跟随 `ext_intr_i`（已修）。 |

---

## 9. 目录速查
| 目录 | 内容 |
|---|---|
| [src/](src) | RTL 设计（[core/top/icache/dcache](src) + [soc/](src/soc) + [soc/debug/](src/soc/debug) JTAG 调试模块） |
| [tb/tb_soc/](tb/tb_soc) | 测试平台（含 JTAG remote_bitbang 桥） |
| [tools/openocd/](tools/openocd) | OpenOCD 配置 + GDB 调试说明 |
| [bootloader/](bootloader) | SBI 引导器源码 |
| [build-os/](build-os) | 从源码重建 OS |
| [sdk/](sdk) | [裸机](sdk/baremetal) + [Linux](sdk/linux) SDK |
| [gui/](gui) | 串口控制台 GUI |
| [scripts/](scripts) | make_hex.py |
| [image/](image) | 预编译镜像 |
| [docs/](docs) | PDF 操作指南 |

## 致谢
biRISC-V 核 · riscv_soc 外设 · riscv-linux-boot（均 ultraembedded）· Linux 5.4 · BusyBox 1.37.0 · RISC-V GNU 工具链。
