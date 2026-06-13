# src/ —— RTL 设计

QRISC-V996 的全部**硬件设计**(可综合 RTL)都在这里。测试平台在 [`../tb/`](../tb)。

```
src/
├── core/      biRISC-V 双发射核内部模块(取指/译码/发射/执行/ALU/乘除/CSR/MMU/regfile…)
├── top/       riscv_top.v —— 核 + i/d-cache 的封装顶层,对外两条 AXI4 主口(取指 axi_i / 访存 axi_d)
├── icache/    指令 cache
├── dcache/    数据 cache(含 AXI 接口)
├── tcm/       紧耦合存储(本平台未用,保留)
└── soc/       riscv_soc 外设+互联 + biriscv_soc 集成顶层(见 soc/README.md)
                 └── debug/  JTAG 调试模块(DTM/DMI/Debug Module,见 soc/README.md)
```

## 层次关系
```
biriscv_soc.v (src/soc/)         ← SoC 集成顶层 = 核 + 外设 + 调试
   ├── riscv_top.v (src/top/)    ← biRISC-V 核 = core + icache + dcache
   │     ├── riscv_core.v (src/core/)
   │     ├── icache.v   (src/icache/)
   │     └── dcache.v   (src/dcache/)
   ├── soc.v (src/soc/)          ← riscv_soc:arb + tap + uart/timer/gpio/spi/irq_ctrl
   └── riscv_debug.v (src/soc/debug/)  ← JTAG DTM + Debug Module(OpenOCD/GDB 兼容)
```

## 本平台对核做的 RTL 改动(都在 src/core/)
1. **AXI ID 路由**(在 `src/soc/biriscv_soc.v` 给核传 `ICACHE_AXI_ID=8 / DCACHE_AXI_ID=4`):
   riscv_soc 的 arb 按 `rid[3:2]` 把读响应路由回发起口;不设对就取指 stall。
2. **sticky SEIP/MEIP → 电平跟随**(`src/core/biriscv_csr_regfile.v`):
   原 `csr_mip` 只 OR 不清,外部中断只触发一次后核就卡死;改成进 OR 前先清
   `MEIP/SEIP`,让它电平跟随 `ext_intr_i`。这是 ttyUL0 真中断路径能工作的关键。
3. **JTAG 调试支持**(为 `src/soc/debug/` 的 Debug Module 服务):
   `biriscv_issue.v` 加 halt/单步门控、读写 GPR 口、恢复重定向(经 branch_csr 通路);
   `biriscv_csr.v` 加 ebreak→debug(dcsr.ebreakm 开时抑制陷入、发 halt);
   `riscv_core.v`/`riscv_top.v` 透传调试信号。**调试不激活时这些门控信号恒 0,正常运行不受影响**。
   详见 [../tools/openocd/README.md](../tools/openocd/README.md)。

> 核 RTL 源自 [ultraembedded/biriscv](https://github.com/ultraembedded/biriscv),
> 外设/互联源自 [ultraembedded/riscv_soc](https://github.com/ultraembedded/riscv_soc)。
