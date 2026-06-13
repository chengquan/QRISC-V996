#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
QRISC-V996 串口控制台 —— biRISC-V SoC,tb_soc(全 RTL 外设)版

和 biriscv_console.py(tb_top / SystemC 版)长得一样,区别只在输入路径:
tb_soc 的 UART 是真 RTL,输入要经一条真实串行线。GUI 把你键入的命令**追加到一个
输入文件**,tb 里的串行发送器(reopen+fseek)把它按 8N1/BIT_DIV 一位位移进
uart_lite 的 RX 引脚 -> SBI console_getchar -> hvc0 -> busybox sh;内核/shell 的输出
从真实 uart_tx 串行线移出、被 tb 反序列化,经 stdout 回到这里。

依赖:  python3-tk
显示:  Windows 11 的 WSLg 自带图形;直接 `python3 biriscv_soc_console.py` 弹窗。
"""
import os
import re
import time
import codecs
import queue
import shutil
import socket
import threading
import subprocess
import tkinter as tk

# 剥掉 ANSI 转义码(busybox ls 等的颜色码),Tkinter 不解析它们,否则显示成乱码
_ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
from tkinter import scrolledtext

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.join(HERE, "run_soc_backend.sh")
ROOT = os.path.dirname(HERE)
INPUT_FILE = os.path.join(ROOT, "tb", "tb_soc", ".gui_input.txt")
VCD_FILE = os.path.join(ROOT, "tb", "tb_soc", "tb_soc.fst")
OPENOCD_CFG = os.path.join(ROOT, "tools", "openocd", "qrisc-v996.cfg")
JTAG_PORT = 9999          # 仿真 remote_bitbang 监听端口(与 .cfg 一致)
OCD_TELNET = 4444         # OpenOCD telnet 命令端口

# 波形深度(verilator --trace-depth):录的层次越深 VCD 越大越慢。切换会重编对应深度的二进制(缓存)。
DEPTHS = {"顶层": "1", "+SoC接口": "2", "全部(大)": "0"}

# 可选镜像(下拉框):hvc0 = SBI 控制台(快);ttyUL0 = 内核 uartlite 驱动(真驱动,慢)
IMAGES = {
    "hvc0  (快)":          os.path.join(ROOT, "image", "biriscv-linux-5.4-hvc0.elf"),
    "ttyUL0  (真驱动·慢)": os.path.join(ROOT, "image", "biriscv-linux-5.4-ttyul0.elf"),
}

BM_EX_DIR = os.path.join(ROOT, "sdk", "baremetal", "examples")

def list_baremetal():
    """扫 sdk/baremetal/examples/*.c,返回 {程序名: 程序名}"""
    out = {}
    try:
        for f in sorted(os.listdir(BM_EX_DIR)):
            if f.endswith(".c"):
                out[f[:-2]] = f[:-2]
    except OSError:
        pass
    return out or {"(无示例)": ""}

BG, FG, BG2 = "#1e1e1e", "#d4d4d4", "#252526"
ACCENT, DIM, ERRCOL = "#4ec9b0", "#6a9955", "#f48771"


class Console(tk.Tk):
    def __init__(self):
        super().__init__()
        # 标题用纯 ASCII:WSLg 的窗口管理器字体没中文字形,中文标题会变方块
        self.title("QRISC-V996 Console  (biRISC-V SoC, full-RTL peripherals / real serial UART)")
        self.geometry("960x620")
        self.configure(bg=BG)
        self.proc = None
        self.q = queue.Queue()
        self._hist, self._hist_i = [], 0
        self._ansi_pending = ""        # 跨批次剥离 ANSI 码时,暂存末尾半截的转义序列
        # 增量 UTF-8 解码器:跨 drain 批次缓存半个多字节字符(否则汉字被拆 -> 乱码/?)
        self._dec = codecs.getincrementaldecoder("utf-8")("replace")
        self._build_ui()
        self.after(40, self._drain)
        self.protocol("WM_DELETE_WINDOW", self._on_close)

    def _build_ui(self):
        bar = tk.Frame(self, bg=BG2); bar.pack(side="top", fill="x")
        self.btn_start = tk.Button(bar, text="▶ 启动 Linux", command=self.start,
                                   bg="#0e639c", fg="white", relief="flat", padx=10, pady=4)
        self.btn_start.pack(side="left", padx=(8, 4), pady=6)
        self.btn_stop = tk.Button(bar, text="■ 停止", command=self.stop, state="disabled",
                                  bg="#5a1d1d", fg="white", relief="flat", padx=10, pady=4)
        self.btn_stop.pack(side="left", padx=4, pady=6)
        self.btn_ctrlc = tk.Button(bar, text="Ctrl-C", command=lambda: self._send_raw("\x03"),
                                   state="disabled", bg="#3a3d41", fg="white", relief="flat",
                                   padx=8, pady=4)
        self.btn_ctrlc.pack(side="left", padx=4, pady=6)
        tk.Button(bar, text="清屏", command=self.clear, bg="#3a3d41", fg="white",
                  relief="flat", padx=8, pady=4).pack(side="left", padx=4, pady=6)
        # 模式下拉(Linux / 裸机)
        tk.Label(bar, text="模式:", bg=BG2, fg="#999").pack(side="left", padx=(12, 2))
        self.mode_var = tk.StringVar(value="Linux")
        self.mode_menu = tk.OptionMenu(bar, self.mode_var, "Linux", "裸机", command=self._on_mode)
        self.mode_menu.configure(bg="#3a3d41", fg="white", relief="flat",
                                 highlightthickness=0, activebackground="#0e639c")
        self.mode_menu["menu"].configure(bg="#3a3d41", fg="white")
        self.mode_menu.pack(side="left", padx=2, pady=6)
        # 选择下拉(随模式变:Linux=镜像, 裸机=程序)
        self.sel_var = tk.StringVar(value=list(IMAGES.keys())[0])
        self.sel_menu = tk.OptionMenu(bar, self.sel_var, *IMAGES.keys())
        self.sel_menu.configure(bg="#3a3d41", fg="white", relief="flat",
                                highlightthickness=0, activebackground="#0e639c")
        self.sel_menu["menu"].configure(bg="#3a3d41", fg="white")
        self.sel_menu.pack(side="left", padx=2, pady=6)
        # 虚拟磁盘(仅 Linux):勾上则挂载 disk.hex,程序出现在 /opt(不用重建内核)
        self.disk_var = tk.BooleanVar(value=True)
        self.chk_disk = tk.Checkbutton(bar, text="虚拟磁盘", variable=self.disk_var,
                                       bg=BG2, fg=FG, selectcolor=BG, activebackground=BG2,
                                       activeforeground=FG, relief="flat")
        self.chk_disk.pack(side="left", padx=(10, 0))
        # JTAG 调试:勾上启动时仿真带 +JTAG,可用下方 OpenOCD 控制台连接
        self.jtag_var = tk.BooleanVar(value=False)
        self.chk_jtag = tk.Checkbutton(bar, text="JTAG调试", variable=self.jtag_var,
                                       bg=BG2, fg=FG, selectcolor=BG, activebackground=BG2,
                                       activeforeground=FG, relief="flat")
        self.chk_jtag.pack(side="left", padx=(10, 0))
        # 录波形 + 查看波形
        self.trace_var = tk.BooleanVar(value=False)
        self.chk_trace = tk.Checkbutton(bar, text="录波形", variable=self.trace_var,
                                        bg=BG2, fg=FG, selectcolor=BG, activebackground=BG2,
                                        activeforeground=FG, relief="flat")
        self.chk_trace.pack(side="left", padx=(12, 0))
        tk.Label(bar, text="周期", bg=BG2, fg="#999").pack(side="left")
        self.cyc_entry = tk.Entry(bar, width=8, bg="#3c3c3c", fg=FG, insertbackground=FG, relief="flat")
        self.cyc_entry.insert(0, "1000000")
        self.cyc_entry.pack(side="left", padx=2, pady=6)
        tk.Label(bar, text="深度", bg=BG2, fg="#999").pack(side="left")
        self.depth_var = tk.StringVar(value=list(DEPTHS.keys())[0])
        self.depth_menu = tk.OptionMenu(bar, self.depth_var, *DEPTHS.keys())
        self.depth_menu.configure(bg="#3a3d41", fg="white", relief="flat", highlightthickness=0)
        self.depth_menu["menu"].configure(bg="#3a3d41", fg="white")
        self.depth_menu.pack(side="left", padx=2, pady=6)
        self.btn_wave = tk.Button(bar, text="📊 查看波形", command=self.view_wave,
                                  bg="#3a3d41", fg="white", relief="flat", padx=8, pady=4)
        self.btn_wave.pack(side="left", padx=4, pady=6)
        self.status = tk.Label(bar, text="○ 未启动", bg=BG2, fg="#999")
        self.status.pack(side="right", padx=10)

        self.out = scrolledtext.ScrolledText(self, bg=BG, fg=FG, insertbackground=FG,
                                             font=("Monospace", 10), wrap="char",
                                             relief="flat", padx=8, pady=6, state="disabled")
        self.out.pack(side="top", fill="both", expand=True)
        self.out.tag_config("sys", foreground=ACCENT)
        self.out.tag_config("err", foreground=ERRCOL)

        # ---- OpenOCD 调试控制台(底部,默认折叠成一行;连接后展开输出窗)----
        dbg = tk.Frame(self, bg=BG2); dbg.pack(side="bottom", fill="x")
        # 第 1 行:连接 + 命令输入 + 内存读写(SBA,不暂停核)
        dbgbar = tk.Frame(dbg, bg=BG2); dbgbar.pack(side="top", fill="x")
        self.btn_ocd = tk.Button(dbgbar, text="🔌 连接 OpenOCD", command=self.ocd_toggle,
                                 bg="#3a3d41", fg="white", relief="flat", padx=8, pady=2)
        self.btn_ocd.pack(side="left", padx=(8, 4), pady=4)
        tk.Label(dbgbar, text="OpenOCD>", bg=BG2, fg="#999").pack(side="left", padx=(6, 2))
        self.ocd_entry = tk.Entry(dbgbar, bg="#3c3c3c", fg=FG, insertbackground=FG,
                                  relief="flat", font=("Monospace", 10), state="disabled")
        self.ocd_entry.pack(side="left", fill="x", expand=True, pady=4)
        self.ocd_entry.bind("<Return>", lambda e: self.ocd_send())
        # 快捷:内存/外设读写(SBA,不暂停核)
        tk.Label(dbgbar, text="内存", bg=BG2, fg="#999").pack(side="left", padx=(8, 2))
        self.ocd_addr = tk.Entry(dbgbar, width=12, bg="#3c3c3c", fg=FG, insertbackground=FG, relief="flat")
        self.ocd_addr.insert(0, "0x94000008"); self.ocd_addr.pack(side="left", pady=4)
        self.btn_rd = tk.Button(dbgbar, text="读", command=self.ocd_read, state="disabled",
                                bg="#3a3d41", fg="white", relief="flat", padx=8, pady=2)
        self.btn_rd.pack(side="left", padx=2, pady=4)
        self.ocd_wval = tk.Entry(dbgbar, width=12, bg="#3c3c3c", fg=FG, insertbackground=FG, relief="flat")
        self.ocd_wval.insert(0, "0xCAFE0000"); self.ocd_wval.pack(side="left", pady=4)
        self.btn_wr = tk.Button(dbgbar, text="写", command=self.ocd_write, state="disabled",
                                bg="#3a3d41", fg="white", relief="flat", padx=8, pady=2)
        self.btn_wr.pack(side="left", padx=2, pady=4)

        # 第 2 行:核调试(halt/单步/断点/寄存器/GDB)—— 连接后才启用
        dbgbar2 = tk.Frame(dbg, bg=BG2); dbgbar2.pack(side="top", fill="x")
        tk.Label(dbgbar2, text="核调试:", bg=BG2, fg="#999").pack(side="left", padx=(8, 2))
        self.btn_halt = tk.Button(dbgbar2, text="⏸ 暂停", command=self.ocd_halt, state="disabled",
                                  bg="#3a3d41", fg="white", relief="flat", padx=8, pady=2)
        self.btn_halt.pack(side="left", padx=2, pady=4)
        self.btn_resume = tk.Button(dbgbar2, text="▶ 继续", command=self.ocd_resume, state="disabled",
                                    bg="#3a3d41", fg="white", relief="flat", padx=8, pady=2)
        self.btn_resume.pack(side="left", padx=2, pady=4)
        self.btn_step = tk.Button(dbgbar2, text="⤵ 单步", command=self.ocd_step, state="disabled",
                                  bg="#3a3d41", fg="white", relief="flat", padx=8, pady=2)
        self.btn_step.pack(side="left", padx=2, pady=4)
        self.btn_regs = tk.Button(dbgbar2, text="📋 寄存器", command=self.ocd_regs, state="disabled",
                                  bg="#3a3d41", fg="white", relief="flat", padx=8, pady=2)
        self.btn_regs.pack(side="left", padx=2, pady=4)
        # 软件断点:地址 + 设置
        tk.Label(dbgbar2, text="断点@", bg=BG2, fg="#999").pack(side="left", padx=(10, 2))
        self.ocd_bpaddr = tk.Entry(dbgbar2, width=12, bg="#3c3c3c", fg=FG, insertbackground=FG, relief="flat")
        self.ocd_bpaddr.insert(0, "0x80200004"); self.ocd_bpaddr.pack(side="left", pady=4)
        self.btn_bp = tk.Button(dbgbar2, text="设断点", command=self.ocd_bp_set, state="disabled",
                                bg="#3a3d41", fg="white", relief="flat", padx=8, pady=2)
        self.btn_bp.pack(side="left", padx=2, pady=4)
        # 启动 GDB(开新终端连 :3333)
        self.btn_gdb = tk.Button(dbgbar2, text="🐞 启动 GDB", command=self.ocd_launch_gdb, state="disabled",
                                 bg="#3a3d41", fg="white", relief="flat", padx=8, pady=2)
        self.btn_gdb.pack(side="left", padx=(10, 2), pady=4)

        self.ocd_out = scrolledtext.ScrolledText(dbg, bg="#15170f", fg="#cfe0b0", height=6,
                                                 font=("Monospace", 9), wrap="char",
                                                 relief="flat", padx=8, pady=4, state="disabled")
        # ocd_out 默认不 pack(连接后才显示)
        self.ocd_proc = None        # openocd 子进程
        self.ocd_sock = None        # 到 openocd telnet 的 socket

        row = tk.Frame(self, bg=BG2); row.pack(side="bottom", fill="x")
        tk.Label(row, text="输入:", bg=BG2, fg="#999").pack(side="left", padx=(8, 4), pady=6)
        self.entry = tk.Entry(row, bg="#3c3c3c", fg=FG, insertbackground=FG,
                              relief="flat", font=("Monospace", 10))
        self.entry.pack(side="left", fill="x", expand=True, pady=6)
        self.entry.bind("<Return>", lambda e: self.send_line())
        self.entry.bind("<Up>", self._hist_up)
        self.entry.bind("<Down>", self._hist_down)
        self.btn_send = tk.Button(row, text="发送 ⏎", command=self.send_line, state="disabled",
                                  bg="#0e639c", fg="white", relief="flat", padx=10, pady=2)
        self.btn_send.pack(side="left", padx=6, pady=6)

        self._write("QRISC-V996 串口控制台 —— biRISC-V SoC,tb_soc(全RTL外设,真串行UART)\n", "sys")
        self._write("点「▶ 启动 Linux」开始。周期级 RTL 仿真:到 shell (~ #) 约 4-5 分钟。\n"
                    "到提示符后在「输入」框敲命令(uname -a、cat /proc/cpuinfo、ls /)回车发送。\n"
                    "命令经真实串行线送入,约 15 字符/秒,回车后等一两秒回显属正常。\n\n", "sys")

    def _on_mode(self, *_):
        # 切模式 → 重填「选择」下拉:Linux=镜像, 裸机=程序
        items = IMAGES if self.mode_var.get() == "Linux" else list_baremetal()
        m = self.sel_menu["menu"]; m.delete(0, "end")
        for k in items:
            m.add_command(label=k, command=lambda v=k: self.sel_var.set(v))
        self.sel_var.set(list(items.keys())[0])

    def start(self):
        if self.proc:
            return
        if not os.access(BACKEND, os.X_OK):
            try: os.chmod(BACKEND, 0o755)
            except OSError: pass
        try:
            open(INPUT_FILE, "w").close()
        except OSError:
            pass
        env = dict(os.environ, SOC_INPUT=INPUT_FILE)
        if self.mode_var.get() == "裸机":
            sel = self.sel_var.get()
            env["MODE"] = "baremetal"; env["SEL"] = sel
            self._write(f"[裸机] 编译并运行 sdk/baremetal/examples/{sel}.c(无 OS,直接在核上)\n", "sys")
        else:
            elf = IMAGES[self.sel_var.get()]
            env["MODE"] = "linux"; env["ELF"] = elf
            self._write(f"[Linux] {self.sel_var.get()}  ({os.path.basename(elf)})\n", "sys")
            if self.disk_var.get():
                env["USE_DISK"] = "1"
                self._write("[虚拟磁盘] 挂载 disk.hex —— 程序会出现在 /opt(开机后 ls /opt 看；改程序跑 sdk/linux/mkdisk.sh,不用重建内核)\n", "sys")
        if self.jtag_var.get():
            env["JTAG"] = str(JTAG_PORT)
            self.jtag_running = True
            self._write(f"[JTAG] 调试模式:仿真带 +JTAG={JTAG_PORT}。到下方 OpenOCD 控制台点「🔌连接」即可 mdw/mww 读写内存/外设(不暂停 CPU)\n", "sys")
        else:
            self.jtag_running = False
        if self.trace_var.get():
            cyc = (self.cyc_entry.get().strip() or "1000000")
            depth = DEPTHS[self.depth_var.get()]
            env["TRACE"] = "1"; env["TRACE_CYCLES"] = cyc; env["TRACE_DEPTH"] = depth
            self._write(f"[波形] 录制开启:深度「{self.depth_var.get()}」,跑 {cyc} 周期后自动停 -> tb_soc.fst"
                        f"(该深度首次会先编译带 --trace 的版本,慢)\n", "sys")
            self._write("[波形] 点「停止」或等到周期上限,都会生成波形(到结束那一刻为止),"
                        "再点「📊 查看波形」打开。\n", "sys")
        self._dec.reset(); self._ansi_pending = ""   # 新一轮:清掉上次残留的半字符/转义
        try:
            self.proc = subprocess.Popen(["bash", BACKEND], stdout=subprocess.PIPE,
                                         stderr=subprocess.STDOUT, bufsize=0, env=env)
        except Exception as e:
            self._write(f"\n[无法启动仿真] {e}\n", "err"); self.proc = None; return
        threading.Thread(target=self._read_worker, daemon=True).start()
        self._set_running(True)
        self._write("[启动仿真中…首次会先构建,稍候]\n", "sys")
        self.entry.focus_set()

    def stop(self):
        if not self.proc:
            return
        try: self.proc.terminate()
        except Exception: pass
        try: subprocess.Popen(["pkill", "-TERM", "-f", "build_vl.*tb_soc"])
        except Exception: pass
        self.proc = None
        self._set_running(False)
        self._write("\n[仿真已停止]\n", "sys")

    def _read_worker(self):
        f = self.proc.stdout
        try:
            while True:
                b = f.read(1)
                if not b:
                    break
                self.q.put(b)
        except Exception:
            pass
        self.q.put(None)

    def _drain(self):
        buf = []
        try:
            while True:
                item = self.q.get_nowait()
                if item is None:
                    if buf:
                        self._feed_bytes(b"".join(buf)); buf = []
                    self._feed_sim(self._dec.decode(b"", final=True))   # 冲掉残留半字符
                    self._write("\n[仿真进程已退出]\n", "sys")
                    self.proc = None; self._set_running(False); continue
                buf.append(item)
        except queue.Empty:
            pass
        if buf:
            self._feed_bytes(b"".join(buf))
        self.after(40, self._drain)

    def _feed_bytes(self, data):
        # 增量解码(半个汉字留到下批)+ 去掉 \r(否则行尾留个字体画不出的 口)
        text = self._dec.decode(data).replace("\r", "")
        if text:
            self._feed_sim(text)

    def send_line(self):
        text = self.entry.get()
        self._send_raw(text + "\n")
        if text.strip():
            self._hist.append(text)
        self._hist_i = len(self._hist)
        self.entry.delete(0, "end")

    def _send_raw(self, s):
        # tb_soc 的输入走文件追加:串行发送器(reopen+fseek)会读到新内容并移进串口
        if not self.proc:
            self._write("[未运行,无法发送]\n", "err"); return
        try:
            with open(INPUT_FILE, "a") as f:
                f.write(s); f.flush()
        except Exception as e:
            self._write(f"[发送失败] {e}\n", "err")

    def _hist_up(self, _e):
        if self._hist and self._hist_i > 0:
            self._hist_i -= 1
            self.entry.delete(0, "end"); self.entry.insert(0, self._hist[self._hist_i])
        return "break"

    def _hist_down(self, _e):
        if self._hist_i < len(self._hist) - 1:
            self._hist_i += 1
            self.entry.delete(0, "end"); self.entry.insert(0, self._hist[self._hist_i])
        else:
            self._hist_i = len(self._hist); self.entry.delete(0, "end")
        return "break"

    def _feed_sim(self, text):
        # 仿真输出:流式剥离 ANSI 颜色码。转义码可能被串口逐字节读取拆散在多批里,
        # 所以把末尾"半截还没结束的转义序列"暂存,和下一批拼起来再剥。
        text = self._ansi_pending + text
        self._ansi_pending = ""
        m = re.search(r"\x1b\[?[0-9;?]*$", text)   # 末尾不完整的 CSI 序列
        if m:
            self._ansi_pending = text[m.start():]
            text = text[:m.start()]
        self._write(_ANSI_RE.sub("", text))

    def _write(self, text, tag=None):
        self.out.configure(state="normal")
        self.out.insert("end", text, (tag,) if tag else ())
        self.out.see("end"); self.out.configure(state="disabled")

    def view_wave(self):
        if not os.path.exists(VCD_FILE) or os.path.getsize(VCD_FILE) == 0:
            self._write("[波形] 还没有波形文件 —— 勾选「录波形」跑一次(到设定周期会自动停)后再看\n", "err")
            return
        try:
            subprocess.Popen(["gtkwave", VCD_FILE], stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
            self._write(f"[波形] gtkwave 打开 {VCD_FILE}\n", "sys")
        except FileNotFoundError:
            self._write("[波形] 没装 gtkwave:sudo apt install -y gtkwave\n", "err")
        except Exception as e:
            self._write(f"[波形] 打开失败:{e}\n", "err")

    def clear(self):
        self.out.configure(state="normal"); self.out.delete("1.0", "end")
        self.out.configure(state="disabled")

    # ---------------- OpenOCD 调试控制台 ----------------
    def _ocd_write(self, text):
        self.ocd_out.configure(state="normal")
        self.ocd_out.insert("end", text)
        self.ocd_out.see("end"); self.ocd_out.configure(state="disabled")

    def ocd_toggle(self):
        if self.ocd_sock:
            self.ocd_disconnect()
        else:
            self.ocd_connect()

    def ocd_connect(self):
        if not getattr(self, "jtag_running", False) or not self.proc:
            self._ocd_show()
            self._ocd_write("✗ 请先勾选「JTAG调试」并点▶启动仿真,再连接 OpenOCD。\n")
            return
        if not os.path.exists(OPENOCD_CFG):
            self._ocd_show(); self._ocd_write(f"✗ 找不到配置 {OPENOCD_CFG}\n"); return
        self._ocd_show()
        self._ocd_write("启动 openocd,连接仿真 JTAG…\n")
        try:
            self.ocd_proc = subprocess.Popen(
                ["openocd", "-f", OPENOCD_CFG],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                cwd=ROOT, bufsize=1, universal_newlines=True)
        except FileNotFoundError:
            self._ocd_write("✗ 没装 openocd:sudo apt install -y openocd\n"); return
        except Exception as e:
            self._ocd_write(f"✗ openocd 启动失败:{e}\n"); return
        threading.Thread(target=self._ocd_log_reader, daemon=True).start()
        # 等 openocd 起 telnet,再连 4444
        threading.Thread(target=self._ocd_open_telnet, daemon=True).start()

    def _ocd_log_reader(self):
        # 监测 OpenOCD 日志:examine 完成(出现 "Listening on port 4444" /
        # gdb server / XLEN=)后才算"真正就绪",此前敲命令 OpenOCD 在忙 examine 不处理。
        try:
            for line in self.ocd_proc.stdout:
                self.after(0, self._ocd_write, "  [ocd] " + line)
                if (("Listening on port %d" % OCD_TELNET) in line
                        or "Examined RISC-V core" in line
                        or "starting gdb server" in line):
                    self.after(0, self._ocd_ready)
        except Exception:
            pass

    def _ocd_open_telnet(self):
        for _ in range(60):                      # 最多等 ~12s(examine 慢)
            try:
                s = socket.create_connection(("localhost", OCD_TELNET), timeout=1)
                self.ocd_sock = s
                self.after(0, self._ocd_connected)
                threading.Thread(target=self._ocd_recv, daemon=True).start()
                return
            except OSError:
                time.sleep(0.2)
        self.after(0, self._ocd_write, "✗ 连不上 openocd telnet(4444)。看上面 openocd 日志排错。\n")

    def _ocd_connected(self):
        # telnet 的 TCP 连上了,但 OpenOCD 可能还在 examine(仿真里 bit-bang JTAG 慢)。
        # 先只改按钮文案,输入框/按钮等 _ocd_ready(examine 完成)再启用,避免过早敲命令没反馈。
        self.btn_ocd.configure(text="⛔ 断开 OpenOCD")
        self.ocd_ready = False
        self._ocd_write("⏳ 已连上 OpenOCD,正在 examine 核(仿真里较慢,请等「✅就绪」再操作)…\n")
        # 兜底:即使没在日志里匹配到就绪标志,25s 后也启用(避免卡住无法操作)
        self.after(25000, self._ocd_ready)

    def _ocd_ready(self):
        if getattr(self, "ocd_ready", False) or not self.ocd_sock:
            return                                # 只触发一次
        self.ocd_ready = True
        for w in (self.ocd_entry, self.btn_rd, self.btn_wr,
                  self.btn_halt, self.btn_resume, self.btn_step, self.btn_regs,
                  self.btn_bp, self.btn_gdb):
            w.configure(state="normal")
        self._ocd_write("✅ 就绪(examine 通过,XLEN=32,核支持完整调试):\n"
                        "   核调试:⏸暂停 / ▶继续 / ⤵单步 / 📋寄存器 / 设软件断点 / 🐞启动GDB\n"
                        "   内存/外设:地址框 + 读/写(经 SBA,不暂停核),或敲 mdw/sba_read、halt、reg pc 等\n")

    def _ocd_recv(self):
        try:
            while self.ocd_sock:
                data = self.ocd_sock.recv(4096)
                if not data:
                    break
                txt = data.decode("utf-8", "replace").replace("\r", "")
                # 去掉 telnet 提示符控制字符
                txt = txt.replace("\x00", "")
                self.after(0, self._ocd_write, txt)
        except OSError:
            pass

    def ocd_send(self, cmd=None):
        if not self.ocd_sock:
            return
        if cmd is None:
            cmd = self.ocd_entry.get().strip()
            self.ocd_entry.delete(0, "end")
        if not cmd:
            return
        self._ocd_write(f"> {cmd}\n")
        try:
            self.ocd_sock.sendall((cmd + "\n").encode())
        except OSError as e:
            self._ocd_write(f"✗ 发送失败:{e}\n")

    def ocd_read(self):
        # 「读」按钮用 sba_read:经 SBA 读,不暂停核(mdw 会先 halt 核;手敲 mdw 也行)
        a = self.ocd_addr.get().strip()
        if a: self.ocd_send(f"sba_read {a}")

    def ocd_write(self):
        a = self.ocd_addr.get().strip(); v = self.ocd_wval.get().strip()
        if a and v: self.ocd_send(f"sba_write {a} {v}")

    # ---- 核调试(走 .cfg 里的 dbg_* TCL 过程)----
    def ocd_halt(self):
        self.ocd_send("dbg_halt")               # 暂停 CPU(看 allhalted)

    def ocd_resume(self):
        self.ocd_send("dbg_resume")             # 恢复运行

    def ocd_step(self):
        self.ocd_send("dbg_step")               # 单步一条,回报新 pc

    def ocd_regs(self):
        self.ocd_send("dbg_regs")               # 打印 x0..x31 + pc(dpc)

    def ocd_bp_set(self):
        a = self.ocd_bpaddr.get().strip()
        if a:
            self.ocd_send("dbg_bp_enable")      # 开 dcsr.ebreakm
            self.ocd_send(f"dbg_bp_set {a}")    # 在地址写 ebreak 当软件断点

    def ocd_launch_gdb(self):
        # 开一个新终端跑 gdb-multiarch 连 OpenOCD 的 gdb server(:3333)
        gdb = None
        for cand in ("gdb-multiarch", "riscv32-unknown-elf-gdb", "riscv-none-elf-gdb"):
            if shutil.which(cand):
                gdb = cand; break
        if not gdb:
            self._ocd_write("✗ 没装 RISC-V gdb:sudo apt install -y gdb-multiarch\n"); return
        gdb_cmds = (f"{gdb} "
                    "-ex 'set arch riscv:rv32' "
                    "-ex 'set remotetimeout 300' "
                    "-ex 'target extended-remote :3333'")
        # 找一个可用的终端模拟器,开窗跑 gdb
        for term, args in (("x-terminal-emulator", ["-e", "bash", "-c"]),
                           ("gnome-terminal", ["--", "bash", "-c"]),
                           ("xterm", ["-e", "bash", "-c"])):
            if shutil.which(term):
                try:
                    subprocess.Popen([term] + args + [f"{gdb_cmds}; exec bash"], cwd=ROOT)
                    self._ocd_write(f"🐞 已在新终端启动 {gdb},连 :3333。\n"
                                    "   试:info reg pc sp a0  /  x/2xw 0x80000000  /  monitor step\n")
                    return
                except Exception as e:
                    self._ocd_write(f"✗ 启动终端失败:{e}\n")
        # 没有图形终端(如纯 WSL):给出手动命令
        self._ocd_write("✗ 没找到图形终端。请手动在另一个终端运行:\n"
                        f"   {gdb_cmds}\n")

    def ocd_disconnect(self):
        try:
            if self.ocd_sock:
                try: self.ocd_sock.sendall(b"shutdown\n")
                except OSError: pass
                self.ocd_sock.close()
        finally:
            self.ocd_sock = None
        if self.ocd_proc:
            try: self.ocd_proc.terminate()
            except Exception: pass
            self.ocd_proc = None
        self.ocd_ready = False
        self.btn_ocd.configure(text="🔌 连接 OpenOCD")
        for w in (self.ocd_entry, self.btn_rd, self.btn_wr,
                  self.btn_halt, self.btn_resume, self.btn_step, self.btn_regs,
                  self.btn_bp, self.btn_gdb):
            w.configure(state="disabled")
        self._ocd_write("— 已断开 —\n")

    def _ocd_show(self):
        if not self.ocd_out.winfo_ismapped():
            self.ocd_out.pack(side="top", fill="both", expand=False)

    def _set_running(self, on):
        self.btn_start.configure(state="disabled" if on else "normal")
        self.btn_stop.configure(state="normal" if on else "disabled")
        self.btn_ctrlc.configure(state="normal" if on else "disabled")
        self.btn_send.configure(state="normal" if on else "disabled")
        self.mode_menu.configure(state="disabled" if on else "normal")
        self.sel_menu.configure(state="disabled" if on else "normal")
        self.chk_disk.configure(state="disabled" if on else "normal")
        self.chk_jtag.configure(state="disabled" if on else "normal")
        self.chk_trace.configure(state="disabled" if on else "normal")
        self.cyc_entry.configure(state="disabled" if on else "normal")
        self.depth_menu.configure(state="disabled" if on else "normal")
        self.status.configure(text="● 运行中" if on else "○ 已停止",
                              fg=ACCENT if on else "#999")
        if not on and self.ocd_sock:        # 仿真停 -> 自动断开 OpenOCD
            self.ocd_disconnect()

    def _on_close(self):
        try: self.stop()
        finally: self.destroy()


if __name__ == "__main__":
    Console().mainloop()
