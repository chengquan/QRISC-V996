# JTAG 调试（OpenOCD 兼容，全功能）

给 QRISC-V996 加的 **OpenOCD 兼容 JTAG 调试模块**。经 JTAG → DMI → Debug Module，
现已支持完整的核内调试能力：

| 能力 | 机制 | 状态 |
|---|---|---|
| **halt / resume** | dmcontrol.haltreq → 门控 issue 取指；流水线排空后报 halted | ✅ 已验证 |
| **读/写 GPR** | 抽象命令 access-register（halt 时核读/写指定寄存器口） | ✅ 已验证 |
| **读 CSR** | misa / dpc / dcsr（内置值 + dpc 寄存器） | ✅ 已验证 |
| **单步** | dcsr.step：强制单发射 + 发射一条后自动重新 halt | ✅ 已验证 |
| **软件断点** | dcsr.ebreakm：ebreak 命中即进调试，dpc = ebreak 的 PC | ✅ 已验证 |
| **恢复重定向** | resume 时把 pc_x_q + 取指经 branch_csr 通路重定向到 dpc | ✅ 已验证 |
| **System Bus Access** | sbcs/sbaddr/sbdata → AXI 直读写内存+外设（**不暂停核**） | ✅ 已验证 |

```
OpenOCD ──TCP(remote_bitbang)──> tb_soc 里 C++ 桥 ──TCK/TMS/TDI/TDO──> jtag_dtm(TAP)
   │                              DMI ──> dm_sba(Debug Module)
   │                                       ├── 抽象命令 ──> 核 halt/单步/读写 GPR·CSR
   │                                       ├── ebreak ────> 命中即 halt（dcsr.ebreakm）
   │                                       └── SBA ───────> AXI 主口 ──> 互联 ──> DRAM/外设
```

> **设计原则：全部调试逻辑都被门控**（dbg_halt / dbg_step / dbg_ebreakm / dbg_redirect）。
> 调试不激活时（无 `+DBGTEST`、无 `+JTAG` 的 haltreq），这些信号恒为 0，核的行为与原版
> biriscv 完全一致 —— **Linux 正常启动不受影响**（已回归确认）。

## 组成
| 文件 | 作用 |
|---|---|
| `src/soc/debug/jtag_dtm.v` | JTAG TAP/DTM（RISC-V Debug 0.13：IDCODE/DTMCS/DMI 扫描链，单时钟域过采样） |
| `src/soc/debug/dm_sba.v` | Debug Module：dmcontrol/dmstatus + 抽象命令（GPR/CSR/halt/step/断点）+ sbcs/sbaddr/sbdata |
| `src/soc/debug/dm_axi_master.v` | SBA 读/写 → AXI4 单拍事务（8/16/32 位），接 soc 空闲 inport |
| `src/soc/debug/riscv_debug.v` | 上述封装顶层 + tb 直驱 DMI 测试口 |
| 核改动 | `biriscv_issue.v`（halt/单步门控、读写 GPR 口、redirect 经 branch_csr）、`biriscv_csr.v`（ebreak→debug）、`riscv_core.v` / `riscv_top.v` / `biriscv_soc.v`（接线） |
| `tb/tb_soc/jtag_rbb.cpp` | 仿真侧 remote_bitbang TCP 桥（DPI-C） |
| `tb/tb_soc/dbg_fast_test.vh` | 快速调试自测（`+DBGTEST`，直驱 DMI，绕过慢 JTAG） |
| `tb/tb_soc/jtag_selftest.vh` | 经 JTAG TAP 的 SBA 自测（`+JTAGTEST`） |
| `tools/openocd/qrisc-v996.cfg` | OpenOCD 配置 + halt/step/断点/SBA 的 TCL 过程 |

## 方式一：快速自测（不需要 OpenOCD，已验证全 PASS）
直驱 DMI，几千周期即可跑完 halt→读 misa/dpc→读写 GPR→单步→软件断点：
```bash
cd tb/tb_soc && ./build.sh
./build_vl/tb_soc +IMAGE=image.hex +DBGTEST +MAX_CYCLES=2000000
cat dbg_result.txt
```
预期输出（ERR=0 全 PASS）：
```
[DBG]   halt:PASS                          # dmstatus=0x382（allhalted）
[DBG]   读 misa:PASS                       # 0x40001101（RV32IMA）
[DBG]   读 dpc:PASS                        # halt 处 PC
[DBG]   写/读 GPR x10:PASS                 # 0x1234abcd 回环
[DBG]   单步(PC 前进):PASS                 # dpc +4
[DBG]   软件断点(ebreak->halt):PASS        # dpc = ebreak 的 PC(0x80200004)
[DBG] ===== 调试快速自测 全 PASS(halt/寄存器/单步/断点)=====
```
另有经真实 JTAG TAP 的 SBA 自测：
```bash
./build_vl/tb_soc +IMAGE=image.hex +JTAGTEST +MAX_CYCLES=3000000
```

## 方式二：真 OpenOCD 客户端（examine + 标准命令已实测通过）
```bash
sudo apt install -y openocd   # 需 0.12+
```
两个终端：
```bash
# 终端 A：起仿真，开 JTAG 端口 9999（与 .cfg 的 remote_bitbang port 对应）
cd tb/tb_soc && JTAG=9999 ./run.sh
# 终端 B：连 OpenOCD
openocd -f tools/openocd/qrisc-v996.cfg
```
**OpenOCD 的 examine 完整通过**，并起 gdb server（实测输出）：
```
Info :  hart 0: XLEN=32, misa=0x40001101
Info : starting gdb server for riscv.cpu on 3333
Info : Listening on port 3333 for gdb connections
```
**标准 OpenOCD 调试命令直接可用**（实测：halt / reg pc / step / mdw / resume）：
```
> halt
> reg pc
pc (/32): 0x80000104
> step ; reg pc
pc (/32): 0x80000108        # 单步 PC 精确 +4
> step ; reg pc
pc (/32): 0x8000010c        # 再 +4
> mdw 0x80000000
0x80000000: 15c0006f        # 经 SBA 读内存
> resume
```
也可 telnet 进交互（端口 4444），用 `.cfg` 里封装的过程（`dbg_halt` / `dbg_regs` /
`dbg_step` / `dbg_bp_set` / `sba_read` …），等价于标准命令但走底层 DMI。

> **重连**：JTAG 桥（`jtag_rbb.cpp`）支持 OpenOCD 反复连接/断开——一个 OpenOCD 退出后
> （正常 shutdown、断开、甚至被 kill），**仿真继续运行**，下一个 OpenOCD 可直接再连,
> 无需重启仿真。

### 连不上排错（`Bad file descriptor`）
若 OpenOCD 报：
```
Info : Connecting to localhost:9999
Error: Error on socket 'Failed to connect': errno==9, Bad file descriptor.
```
说明**仿真的 JTAG 连接槽被一个残留的 OpenOCD 占着**（同一仿真同一时刻只接一个 OpenOCD）。
此时 examine 实际失败、核没真正连上，于是 `mdw`/halt 等命令**毫无反应**。解决：
```bash
pkill -9 openocd        # 清掉所有残留 openocd,再重连
```
GUI 场景同理：底部面板若一直不出现「✅ 就绪」、或敲命令没反应,多半是有残留 openocd——
先在终端 `pkill -9 openocd` 再点「🔌连接」。（桥已修成可重连,但若旧仿真二进制未重 build,
仍是一次性连接,记得 `cd tb/tb_soc && ./build.sh` 重编。）

### 为让标准 OpenOCD 跑通,DM 做的几处协议适配
| 现象 | 根因 | 修复(dm_sba.v) |
|---|---|---|
| OpenOCD 误判 XLEN=64 | examine 先试 64 位 access-register,我们不报 cmderr 就被当成支持 | aarsize>2(64/128 位)回 `abstractcs.cmderr=2`,OpenOCD 回退到 32 位 → XLEN=32 |
| `unable to resume`(examine 卡住) | resume 后 OpenOCD 等 `dmstatus.allresumeack`(bit17),我们没实现 | 加 `resumeack_q`(bit16/17),resumereq 处理后置位;**sticky**——只由 haltreq/新 resumereq 清,单步/ebreak 的自动 halt 不清(否则 OpenOCD 来不及看到) |
| `Failed to read mstatus` | OpenOCD 读 mstatus 等 CSR,我们回 cmderr=2 → 中止 | 未建模的 CSR 读一律回 0(不报错);无核内 CSR 读口时这是诚实近似(halt 在 M 态) |
| 轮询 data0 取到早值 | abstractcs.busy 恒 0 | 命令处理中(abs_go!=0)置 busy=1,让调试器等结果 |

> **仍是精简 DM**：未实现 progbuf、硬件触发(triggers,OpenOCD 报 "Found 0 triggers")、
> abstractauto。GDB 断点用**软件断点**(ebreak)即可;硬件 watchpoint 不支持。
> `mdw/mww` 经 SBA(不暂停核);progbuf=0 时 OpenOCD 对 fence 一致性给 warning,功能不受影响。

## GDB（gdb-multiarch 实测通过）
装 RISC-V 的 gdb：
```bash
sudo apt install -y gdb-multiarch          # 通用,可连 RV32(本仓库即用它实测)
# 或 riscv32-unknown-elf-gdb / riscv-none-elf-gdb(工具链自带)
```
三层链路：`gdb ──RSP──> OpenOCD(gdb server :3333) ──DMI/JTAG──> Debug Module ──> 核`
```bash
gdb-multiarch vmlinux           # 或你的 .elf(无符号也行)
(gdb) set arch riscv:rv32
(gdb) set remotetimeout 300     # 仿真里 bit-bang JTAG 慢,超时调大
(gdb) target extended-remote :3333
(gdb) info reg pc sp ra a0      # 读 GPR + pc(已实测)
(gdb) x/2xw 0x80000000          # 读内存,首字 0x15c0006f(经 SBA,已实测)
(gdb) set $a0 = 0x1234abcd      # 写寄存器(已实测,读回一致)
(gdb) monitor step              # 单步(PC +4,已实测)
(gdb) break *0x80200004         # 软件断点(GDB 写 ebreak)
(gdb) continue
```
**已用 gdb-multiarch 15.1 + OpenOCD 0.12 实测端到端通过**：connect / `info reg`(读出真实
pc·sp·ra·a0) / `x`(读内存正确) / `set $reg`(写读一致) / 单步(PC 前进) 全 OK。
> **单步用 `monitor step` 而非 GDB 的 `stepi`**：仿真里 JTAG 是逐位过采样,一次 `stepi`
> 要多轮 DMI + 全寄存器回读,耗时数秒,触发 OpenOCD 的 1s keep_alive warning(会重试但很慢)。
> `monitor step` 走 OpenOCD 侧单步,少一轮 GDB 回读,快得多。真实 FPGA 上 JTAG 是并行硬件,
> `stepi` 也会很快。复杂场景(硬件 watchpoint)受精简 DM 限制,用软件断点即可。

## 参数
- IDCODE：`0xDEB10001`（见 `jtag_dtm.v` 与 `.cfg` 的 `-expected-id`）
- JTAG 端口：仿真用 `+JTAG=<端口>`（或 `JTAG=<端口> ./run.sh`）
- ebreak 编码：`0x00100073`（注意 `0x00000073` 是 **ECALL** 不是 EBREAK）
- 内存映射：DRAM 0x80000000 / irq 0x90000000 / timer 0x91000000 / uart 0x92000000 / spi 0x93000000 / gpio 0x94000000

## 实现要点 / 踩坑
- **halt = 门控 issue 取指**：`fetch0_accept_o &= ~dbg_halt`，流水线自然排空；不动取指的分支逻辑。
- **单步**：强制单发射 + 检测 `dbg_issued`（发射一条）后立刻重新 halt。
- **软件断点**：`dcsr.ebreakm` 开时，CSR 把 ebreak 的陷入抑制掉、改发 `dbg_ebreak` 脉冲让 DM 进 halt，dpc 锁 ebreak 的 PC。
- **恢复重定向（关键）**：要让核 resume 后跳到任意 dpc，**不能**先撤 halt 再跳（会先执行旧 PC 的指令而derail）。正确做法：**核仍 halt（冻结）时**经核自带的 `branch_csr_request` 通路（陷入级最高优先级）把 `pc_x_q` 和取指**一起**重定向到 dpc，等取指对齐 dpc 后再撤 halt —— 核就从 dpc 干净起跑。
- **单时钟域过采样**：DTM 在系统时钟对 TCK/TMS/TDI 做 2-FF 同步 + 边沿检测，免跨时钟域。
- **JTAG 桥可重连**：`jtag_rbb.cpp` 检测 OpenOCD 异常断开（recv 返回 RST/`n<0`）即释放连接槽；
  OpenOCD `shutdown`（发 `Q`）只断连接、**不再让仿真 $finish** —— 故同一仿真可反复连/断。
  早期一次性连接的实现会让第二次连接报 `Bad file descriptor`、命令无反应（见上方排错）。
- **AW/W 必须并发**：外设经 axi4_lite_tap 转 AXI-Lite，要求 AW 与 W 同时有效。
- **响应路由**：arb 按 `bid/rid[3:2]` 路由响应；调试主口用 id=0 接 inport0。
