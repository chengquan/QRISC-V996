#!/usr/bin/env python3
# 为公众号文章生成 3 张 PNG 架构图(matplotlib,中文用文泉驿)。
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mp
from matplotlib import font_manager as fm
import os

FONT = "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc"
fp = fm.FontProperties(fname=FONT)
plt.rcParams["axes.unicode_minus"] = False
HERE = os.path.dirname(os.path.abspath(__file__))

BLUE="#1a4d7a"; LBLUE="#dbe7f1"; GREEN="#2e7d4f"; LGREEN="#dceede"
ORANGE="#c2722a"; LORANGE="#f6e7d6"; GREY="#555"; LGREY="#eee"

def box(ax,x,y,w,h,text,fc,ec=BLUE,fs=11,bold=False):
    ax.add_patch(mp.FancyBboxPatch((x,y),w,h,boxstyle="round,pad=0.02,rounding_size=0.06",
                 linewidth=1.4,edgecolor=ec,facecolor=fc))
    ax.text(x+w/2,y+h/2,text,ha="center",va="center",fontproperties=fp,
            fontsize=fs,fontweight="bold" if bold else "normal",color="#1a1a1a")

def arrow(ax,x1,y1,x2,y2,text="",color=GREY,fs=9):
    ax.annotate("",xy=(x2,y2),xytext=(x1,y1),
        arrowprops=dict(arrowstyle="-|>",color=color,lw=1.6,shrinkA=2,shrinkB=2))
    if text:
        ax.text((x1+x2)/2,(y1+y2)/2,text,ha="center",va="center",
                fontproperties=fp,fontsize=fs,color=color,
                bbox=dict(boxstyle="round,pad=0.15",fc="white",ec="none"))

def save(fig,name):
    fig.savefig(os.path.join(HERE,name),dpi=150,bbox_inches="tight",facecolor="white")
    plt.close(fig); print("  ->",name)

# ---------- 图1:整体全景(你敲命令 → 仿真 → 自编 Linux) ----------
def fig_overview():
    fig,ax=plt.subplots(figsize=(9,5)); ax.set_xlim(0,10); ax.set_ylim(0,7); ax.axis("off")
    ax.text(5,6.6,"QRISC-V996 全景:把自编 Linux 跑在自己的 RISC-V 芯片(仿真)上",
            ha="center",fontproperties=fp,fontsize=13,fontweight="bold",color=BLUE)
    box(ax,0.3,4.2,2.4,1.4,"你\n(GUI / 终端\n敲命令)",LGREEN,GREEN,11,True)
    box(ax,3.4,3.4,6.2,2.6,"",LBLUE)
    ax.text(6.5,5.6,"tb_soc  ——  Verilator 周期级仿真",ha="center",fontproperties=fp,fontsize=11,fontweight="bold",color=BLUE)
    box(ax,3.7,3.7,2.6,1.4,"biRISC-V 核\n(双发射 RV32IMA\n+ i/d-cache + MMU)",LORANGE,ORANGE,9.5)
    box(ax,6.6,3.7,2.7,1.4,"全 RTL 外设\nUART/Timer/GPIO\nSPI/中断控制器",LORANGE,ORANGE,9.5)
    box(ax,2.6,0.6,4.8,1.7,"image/*.elf  =  自编的 OS 镜像\nSBI 引导器 + Linux 5.4 内核 + 文件系统",LGREY,GREY,10,True)
    arrow(ax,2.7,5.2,3.7,5.2,"敲命令(串口)")
    arrow(ax,3.7,4.7,2.7,4.7,"输出(串口)")
    arrow(ax,5.0,3.4,5.0,2.35,"加载运行")
    ax.text(5.0,0.15,"全部从源码自己编译 —— 核、外设、引导器、内核、根文件系统",
            ha="center",fontproperties=fp,fontsize=9,color=GREY,style="italic")
    save(fig,"fig1_overview.png")

# ---------- 图2:SoC 内部结构 + 内存映射 ----------
def fig_soc():
    fig,ax=plt.subplots(figsize=(9,6)); ax.set_xlim(0,10); ax.set_ylim(0,8); ax.axis("off")
    ax.text(5,7.6,"SoC 内部:核 + AXI 互联 + 真 RTL 外设",ha="center",
            fontproperties=fp,fontsize=13,fontweight="bold",color=BLUE)
    box(ax,0.4,4.6,2.6,2.2,"biRISC-V 核\n\n取指口 (AXI)\n访存口 (AXI)",LORANGE,ORANGE,10,True)
    box(ax,3.6,4.9,2.4,1.6,"AXI 互联\n(仲裁 arb +\n地址译码 tap)",LBLUE,BLUE,10,True)
    arrow(ax,3.0,5.7,3.6,5.7,"2 路 AXI")
    periphs=[("DRAM  0x80000000",LGREEN,GREEN),
             ("irq_ctrl  0x90000000",LBLUE,BLUE),
             ("timer  0x91000000",LBLUE,BLUE),
             ("uart_lite  0x92000000",LORANGE,ORANGE),
             ("spi_lite  0x93000000",LBLUE,BLUE),
             ("gpio  0x94000000",LBLUE,BLUE)]
    y=6.5
    for name,fc,ec in periphs:
        box(ax,6.7,y,2.9,0.7,name,fc,ec,9.5)
        arrow(ax,6.0,5.7,6.7,y+0.35,"")
        y-=0.95
    ax.text(8.15,0.5,"地址一映射,软件读写寄存器\n就能操作真实硬件外设",ha="center",
            fontproperties=fp,fontsize=9,color=GREY,style="italic")
    ax.text(1.7,4.0,"两处关键修复:\n· AXI ID 路由(取指不卡死)\n· 中断电平跟随(中断不只来一次)",
            ha="left",va="top",fontproperties=fp,fontsize=9,color="#a33",
            bbox=dict(boxstyle="round,pad=0.3",fc="#fdeeee",ec="#d99"))
    save(fig,"fig2_soc.png")

# ---------- 图3:虚拟磁盘(改程序不重建内核) ----------
def fig_disk():
    fig,ax=plt.subplots(figsize=(9,4.6)); ax.set_xlim(0,10); ax.set_ylim(0,6); ax.axis("off")
    ax.text(5,5.6,"虚拟磁盘:改一个程序,几秒搞定(不用重建内核)",ha="center",
            fontproperties=fp,fontsize=13,fontweight="bold",color=BLUE)
    box(ax,0.3,3.4,2.5,1.4,"写/改程序\nhello.c",LGREEN,GREEN,10,True)
    box(ax,3.3,3.4,2.4,1.4,"mkdisk.sh\n编译 + 打包\n(~几秒)",LBLUE,BLUE,10,True)
    box(ax,6.2,3.4,3.4,1.4,"disk.hex\n放进 DRAM 顶部\n0x82000000",LORANGE,ORANGE,9.5,True)
    arrow(ax,2.8,4.1,3.3,4.1); arrow(ax,5.7,4.1,6.2,4.1)
    box(ax,6.2,0.6,3.4,1.5,"开机 /init 用 mmap\n把程序解到  /opt\n→ 直接运行",LGREEN,GREEN,10,True)
    arrow(ax,7.9,3.4,7.9,2.1,"仿真加载")
    ax.text(2.6,1.5,"对比:\n烤进内核要重建\n(~1-2 分钟)\n虚拟磁盘:只重建磁盘\n(~几秒,内核不动)",
            ha="left",va="center",fontproperties=fp,fontsize=9.5,color=GREY,
            bbox=dict(boxstyle="round,pad=0.3",fc=LGREY,ec="#bbb"))
    save(fig,"fig3_vdisk.png")

if __name__=="__main__":
    print("生成架构图:")
    fig_overview(); fig_soc(); fig_disk()
    print("完成。")
