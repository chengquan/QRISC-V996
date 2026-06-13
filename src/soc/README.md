# src/soc/ —— SoC 设计(外设 + 互联 + 集成顶层)

把 biRISC-V 核接进一整套**真 RTL 外设**,构成 QRISC-V996 的 SoC。

## 文件
| 文件 | 作用 |
|---|---|
| **biriscv_soc.v** | **集成顶层**:`riscv_top`(核,2 路 AXI 主口)+ `soc`(互联+外设);对外只暴露 DRAM 的 AXI4 主口 + UART 串行线 + SPI/GPIO 引脚。 |
| **soc.v** | riscv_soc 顶层:AXI 仲裁(arb)→ 地址译码(tap)→ 分发到各外设 + DRAM 主口 |
| axi4_arb.v / axi4_lite_tap.v / axi4_retime.v | AXI 互联(仲裁 / 地址分发 / 打拍) |
| uart_lite.v (+_defs) | Xilinx UART-Lite,真串行 tx_o/rx_i —— Linux 控制台 |
| timer.v (+_defs) | 定时器 |
| gpio.v (+_defs) | GPIO |
| spi_lite.v (+_defs) | Xilinx AXI SPI |
| irq_ctrl.v (+_defs) | Xilinx XPS 中断控制器(汇聚各外设中断 → 核的 ext_intr) |
| **debug/** | **JTAG 调试模块**(OpenOCD/GDB 兼容):`jtag_dtm.v`(TAP/DTM)+ `dm_sba.v`(Debug Module:dmcontrol/dmstatus/抽象命令 + SBA)+ `dm_axi_master.v`(SBA→AXI)+ `riscv_debug.v`(封装顶层)。详见 [../../tools/openocd/README.md](../../tools/openocd/README.md) |

## 内存映射(物理地址)
| 区域 | 基址 | 说明 |
|---|---|---|
| DRAM | `0x80000000` | 内核 RAM 32MB;仿真内存 36MB,顶部 4MB(`0x82000000`)给虚拟磁盘 |
| irq_ctrl | `0x90000000` | Xilinx INTC(= 内核的 XILINX_INTC) |
| timer | `0x91000000` | |
| **uart_lite** | `0x92000000` | RX@0 TX@4 STATUS@8(bit0=RX有效 / bit3=TX满) |
| **spi_lite** | `0x93000000` | CR@0x60 SR@0x64 DTR@0x68 DRR@0x6c SSR@0x70 |
| **gpio** | `0x94000000` | DIR@0 IN@4 OUT@8 |

复位向量 = `0x80000000`(SBI 引导器加载在此)。

> **调试接口**:JTAG TAP(`debug/jtag_dtm.v`)经 DMI 与 Debug Module(`debug/dm_sba.v`)通信,
> **不占物理地址空间**;Debug Module 经 System Bus Access(SBA)读写上表整片物理地址(不暂停核)。

## 关键集成要点(踩过的坑)
- **AXI ID 路由**:`biriscv_soc.v` 给核传 `ICACHE_AXI_ID=4'd8`(rid[3:2]=10)、
  `DCACHE_AXI_ID=4'd4`(rid[3:2]=01)。soc 的 arb 按 `rid[3:2]` 把读响应送回对应口;
  不设对则取指口收不到响应 → 永久 stall。
- **中断电平**:irq_ctrl 的 `intr_o` 接核 `ext_intr_i`,要求核侧 SEIP/MEIP 电平跟随
  (见 src/core 的 sticky-SEIP 修复),否则中断只来一次。
- **debug 模块集成**:`riscv_debug.v` 封装 jtag_dtm + dm_sba,在 `biriscv_soc.v` 里与核平行实例化;
  SBA 的 AXI 主口接 SoC 一个空闲 inport。核侧 halt/单步/读写 GPR/ebreak 的门控信号在
  `src/core/biriscv_issue.v` 与 `biriscv_csr.v`,**调试不激活时恒 0**,不影响正常运行。
