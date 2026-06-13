# gui/ —— 串口控制台 GUI

WSLg / X11 上的 Tkinter 图形控制台,跟仿真里的 Linux(或裸机程序)交互。

```bash
python3 gui/biriscv_soc_console.py
```

## 文件
| 文件 | 作用 |
|---|---|
| `biriscv_soc_console.py` | GUI 本体(Tkinter):工具栏 + 输出窗 + 输入框 + 历史命令 |
| `run_soc_backend.sh` | GUI 调用的后端:按模式编译/取镜像 → 转 hex → 起 `tb/tb_soc` |

## 工具栏
```
[▶启动][■停止][Ctrl-C][清屏]  模式:[Linux/裸机]  选择:[…]  ☐虚拟磁盘  ☐JTAG调试  ☐录波形 周期[…] 深度:[…] [📊查看波形]
```
- **模式 = Linux**:选 hvc0 / ttyUL0 镜像,启动到 `~ #`。
  - **虚拟磁盘**(默认勾):挂 `disk.hex`,程序出现在 `/opt`(配合 `sdk/linux/mkdisk.sh`)。
- **模式 = 裸机**:选 `sdk/baremetal/examples/` 下的 `.c`,**现编现跑**(无 OS,几秒出结果)。
- **JTAG调试**:勾上启动时仿真带 `+JTAG`,下方 OpenOCD 面板可连(见下)。
- **录波形**:勾上 + 选深度/周期 → 跑完用「📊 查看波形」开 gtkwave 看 FST(GPIO/SPI 引脚时序等)。

## OpenOCD / JTAG 调试面板(窗口底部)
勾「JTAG调试」启动仿真后,点「🔌 连接 OpenOCD」即起 openocd 连仿真 JTAG(examine 通过、
gdb server 起在 :3333)。连上后两行控件:

- **第 1 行(内存/外设,不暂停核)**:命令输入框 + 内存地址框 + 读/写 —— 走 SBA(`sba_read`/`sba_write`),
  可读写整片内存映射(DRAM/uart/gpio/…)而不打断 CPU。
- **第 2 行(核调试)**:`⏸暂停`(halt) · `▶继续`(resume) · `⤵单步`(PC +4) · `📋寄存器`(打印 x0..x31+pc) ·
  `断点@<地址> 设断点`(写 ebreak 当软件断点) · `🐞启动GDB`(开新终端跑 `gdb-multiarch` 连 :3333)。

这些按钮经 telnet:4444 调 [`tools/openocd/qrisc-v996.cfg`](../tools/openocd/qrisc-v996.cfg) 里封装的
`dbg_*` TCL 过程,与命令行 / GDB 走完全相同的 DMI 路径。完整说明见
[`tools/openocd/README.md`](../tools/openocd/README.md)。需装 `openocd`(0.12+);GDB 按钮还需
`gdb-multiarch`。

## 实现要点
- 后端 stdout = UART 真串行线反序列化的字节,经**增量 UTF-8 解码**(中文不被拆成乱码)
  + **去 `\r`**(行尾不留豆腐块)+ **ANSI 转义剥离**(`ls` 颜色码不花屏)后显示。
- 窗口标题用纯 ASCII(WSLg 窗口管理器字体无中文字形,中文标题会变方块)。
- WSLg 偶尔把窗口开到屏幕外:`xdotool search --name QRISC-V windowmove 60 60` 可拉回。

> 早期还有 `biriscv_console.py`(对接已删除的 SystemC `tb_top`),已随旧 tb 一并删除。
