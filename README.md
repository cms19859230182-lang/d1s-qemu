# d1s-qemu — 全志 D1s 最小化 QEMU 机型 / A minimal Allwinner D1s machine for QEMU

[中文](#中文) | [English](#english)

---

## 中文

### 简介

本仓库为 QEMU 10.1.2 提供一个最小化的全志 D1s（RDC2022 开发板，单核
T-Head C906，RV64GC）机型 `d1s`。它不是完整的 SoC 仿真，目的只有一个：
没有板子时，也能把 RT-Thread 直接加载进 DRAM 启动到 `msh />` 并调试。

仓库不包含整棵 QEMU 源码，只有针对 QEMU **v10.1.2**（上游 tag `v10.1.2`，
提交 `ccaea6b2656ec6eab966585f7b16438208f98de7`）的补丁系列和构建脚本，
版本与校验值见 `QEMU_VERSION`。

### 编译

依赖（Ubuntu / Debian）：

```sh
sudo apt-get install -y \
    build-essential ninja-build python3 python3-venv pkg-config \
    libglib2.0-dev libpixman-1-dev bison flex git
```

```sh
scripts/fetch-qemu.sh      # 下载 QEMU 10.1.2 并校验 SHA-256，解压到 ./qemu-10.1.2
scripts/apply-patches.sh   # 打上 patches/ 里的补丁（已打过会报错退出）
scripts/build.sh           # 只编 riscv64-softmmu，产物 qemu-10.1.2/build/qemu-system-riscv64
```

已有本地压缩包时可用 `QEMU_TARBALL=/path/to/qemu-10.1.2.tar.xz` 跳过下载（照常校验）；
`JOBS=4 scripts/build.sh` 指定并行度。

### 一键启动

```sh
./run.sh path/to/rtthread.bin --bsp path/to/rt-thread/bsp/allwinner/d1s
```

`--bsp` 目录里需要有 `sbi.bin`（OpenSBI）和 `u-boot.dtb`，它们是 RT-Thread
上游 `bsp/allwinner/d1s` 自带的文件，本仓库不再收录；也可以用环境变量
`RTT_D1S_BSP` 代替 `--bsp`。

| 参数 | 说明 |
|------|------|
| `--console uart3\|uart0` | 哪个 UART 接到终端（默认 `uart3`；上游 RT-Smart d1s BSP 用 `uart0`） |
| `--uart0-log FILE` | 另一个 UART 的输出写进 FILE（默认丢弃） |
| `--trace FILE` | 打开 `-d guest_errors,unimp` 并写进 FILE（默认关闭，日志增长很快） |
| `--timeout SECS` | 到时自动退出 |

启动链（全部直接加载进 DRAM）：

```
0x40100000  firmware/tramp/tramp.bin  跳板：开 UART3 门控/引脚、配 500000 波特率、打印 banner，按 fw_dynamic 约定跳 OpenSBI
0x40000000  sbi.bin                   OpenSBI（来自 --bsp）
0x40200000  u-boot.dtb                设备树（来自 --bsp），作为 a1 传给 OpenSBI
0x40400000  rtthread.bin              RT-Thread 镜像
```

跳板源码在 `firmware/tramp/`（`tramp.S` 可读汇编，`asm.py` 纯 Python 汇编器，
`build.sh` 可重新生成并核对 `tramp.SHA256`），不需要 RISC-V 交叉工具链。

### rtthread.bin 从哪里来

RT-Thread 的 D1s BSP 在上游 `bsp/allwinner/d1s`：
<https://github.com/RT-Thread/rt-thread/tree/master/bsp/allwinner/d1s>
（按该目录 README 用默认配置 `scons` 编译；工具链前缀可用
`RTT_EXEC_PATH` / `RTT_CC_PREFIX` 环境变量覆盖）。

如实说明目前的验证情况：

- **到 `msh />` 的测试固件**来自一个**尚未合入上游**的 D1s 设备模型（DM/OFW）
  移植，它基于 RT-Thread PR #11877 的设备模型框架，console 在 UART3。在本模拟器上
  能进 `msh />`，`version`、`free`、`list thread` 都正常，空闲 2 分钟后复测仍正常；
  该移植的早期版本在真板上也已进到 `msh />`。该移植以后会单独整理提交。
- **上游 `bsp/allwinner/d1s`（RT-Smart，默认配置）**：能编过，启动链正确，
  用 `./run.sh rtthread.bin --bsp <d1s 目录> --console uart0` 能打印出
  RT-Thread Smart 的启动 banner；但随后在 SD/MMC 初始化时出现 Load Page Fault，
  因为本模拟器**没有 SD/MMC 控制器**，所以**暂时到不了 `msh />`**。这是后续工作。

### 外设支持情况

| 外设 | 地址 | 状态 | 说明 |
|------|------|------|------|
| CPU（T-Head C906） | — | 完整 | QEMU 自带 `thead-c906` 型号，单核 |
| DRAM | `0x40000000`，64 MiB | 完整 | |
| UART3 | `0x02500c00` | 完整 | 16550（reg-shift 2），IRQ 21；另含 DesignWare USR/HALT 状态寄存器（固定值：TX FIFO 永远空、从不忙） |
| UART0 | `0x02500000` | 完整 | 同上，IRQ 18 |
| PLIC | `0x10000000` | 完整 | 上游 `sifive_plic`，177 个中断源 |
| CLINT | `0x14000000` | 完整 | 上游 `riscv_aclint`，mtime 24 MHz |
| 其他所有外设（CCU、PIO/GPIO、其他 UART、定时器、看门狗、DMA、SPI、I2C、USB、SD/MMC、以太网、显示、音频、DDR 控制器……） | 其余地址 | 未模拟 | 兜底区：读返回 0、写被忽略（`--trace` 可看到访问日志） |

### 已知局限

- T-Head 扩展只做到“能跑”：自定义 CSR（`mxstatus`、`mhcr` 等）只是可读写的存储，
  没有副作用；**MAEE / mxstatus 的页表属性位 `PTE[63:59]` 只是剥掉再翻译，
  不建模**缓存性 / 强序语义。
- **没有 USB、没有 SD 卡**，也没有显示、音频、以太网。
- 只能直接加载到 RAM，不模拟 BROM / FEL / SPI flash 启动。
- 单核（`max_cpus = 1`）。
- 时钟树不模拟：写 CCU 无效果，读回为 0；依赖读回值的驱动可能卡住或算错。
- 无 GPIO 中断。
- 早期测试固件上 `list thread` 会崩，原因是固件里 idle 线程栈太小（RT-Thread 侧问题），
  已在新固件里修复，与模拟器无关。
- `--trace` 日志很大（几十秒可到数百 MB），只在排查问题时打开。

### 自检

```sh
tests/smoke.sh path/to/rtthread.bin path/to/rt-thread/bsp/allwinner/d1s
LIST_THREAD=1 IDLE=120 tests/smoke.sh ...   # 加测 list thread，并在空闲 120 秒后复测
```

最后一行输出 `PASS` 或 `FAIL`；`LOGDIR=/some/dir` 可保留串口日志。

### 许可

GPL-2.0-or-later（全文见 `LICENSE`）。补丁与 QEMU 同许可；QEMU 原有文件的版权和
SPDX 头保持不变。

### AI 声明

本仓库的代码与文档在 AI（Grok）协助下编写，经人工审阅和实测。

### 致谢

感谢 @BernardXiong 的支持

---

## English

### What this is

A minimal `d1s` machine for QEMU 10.1.2 modelling the Allwinner D1s
(RDC2022 board, single-core T-Head C906, RV64GC). It is not a full SoC
model; it exists so that RT-Thread can be loaded straight into DRAM and
booted to `msh />` without a board.

The repository does not carry the QEMU tree, only a patch series against
QEMU **v10.1.2** (upstream tag `v10.1.2`, commit
`ccaea6b2656ec6eab966585f7b16438208f98de7`) plus build scripts. See
`QEMU_VERSION` for the tarball URL and SHA-256.

### Building

```sh
sudo apt-get install -y build-essential ninja-build python3 python3-venv \
    pkg-config libglib2.0-dev libpixman-1-dev bison flex git
scripts/fetch-qemu.sh      # download + verify QEMU 10.1.2 into ./qemu-10.1.2
scripts/apply-patches.sh   # apply patches/ (refuses to apply twice)
scripts/build.sh           # riscv64-softmmu only
```

`QEMU_TARBALL=/path/to/qemu-10.1.2.tar.xz` uses a local tarball (still
verified); `JOBS=N` sets build parallelism.

### One-command boot

```sh
./run.sh path/to/rtthread.bin --bsp path/to/rt-thread/bsp/allwinner/d1s
```

The `--bsp` directory must contain `sbi.bin` (OpenSBI) and `u-boot.dtb`,
both shipped by upstream RT-Thread in `bsp/allwinner/d1s` and not
duplicated here (`RTT_D1S_BSP` works too). Options: `--console uart3|uart0`
(default `uart3`; the upstream RT-Smart d1s BSP uses `uart0`),
`--uart0-log FILE` (the other UART), `--trace FILE` (enables
`-d guest_errors,unimp`, off by default), `--timeout SECS`.

Boot chain: trampoline `firmware/tramp/tramp.bin` @ 0x40100000 → OpenSBI
@ 0x40000000 (DTB @ 0x40200000 in a1, `fw_dynamic` info in a2) →
RT-Thread @ 0x40400000. The trampoline source is in `firmware/tramp/` and
rebuilds with Python only.

### Where rtthread.bin comes from

The D1s BSP lives upstream in `bsp/allwinner/d1s`:
<https://github.com/RT-Thread/rt-thread/tree/master/bsp/allwinner/d1s>.

Current status, stated plainly:

- The test firmware that reaches `msh />` comes from a D1s device-model
  (DM/OFW) port that is **not upstream yet** (built on the framework from
  RT-Thread PR #11877, console on UART3). On this machine it reaches
  `msh />`; `version`, `free` and `list thread` work, also after two
  minutes idle. An earlier build of the port also reached `msh />` on the real board.
- Upstream `bsp/allwinner/d1s` (RT-Smart, default config) builds, and with
  `--console uart0` prints the RT-Thread Smart banner, then takes a load
  page fault during SD/MMC init because **SD/MMC is not modelled**. It does
  **not reach `msh />` yet**.

### Peripherals

| Peripheral | Address | Status | Notes |
|------------|---------|--------|-------|
| CPU (T-Head C906) | — | full | QEMU `thead-c906`, one hart |
| DRAM | `0x40000000`, 64 MiB | full | |
| UART3 | `0x02500c00` | full | 16550, IRQ 21, plus DesignWare USR/HALT status (fixed: TX FIFO empty, never busy) |
| UART0 | `0x02500000` | full | same, IRQ 18 |
| PLIC | `0x10000000` | full | upstream `sifive_plic`, 177 sources |
| CLINT | `0x14000000` | full | upstream `riscv_aclint`, 24 MHz mtime |
| Everything else (CCU, PIO/GPIO, other UARTs, timers, watchdog, DMA, SPI, I2C, USB, SD/MMC, Ethernet, display, audio, DRAM controller, …) | rest of the map | not modelled | catch-all window: reads 0, writes ignored |

### Known limitations

- T-Head custom CSRs are plain storage with no side effects; the MAEE /
  mxstatus page-table attribute bits `PTE[63:59]` are stripped before
  translation, their cacheability / strong-order semantics are **not
  modelled**.
- No USB, no SD card, no display, audio or Ethernet.
- Direct RAM load only; BROM / FEL / SPI flash boot is not modelled.
- Single hart. No clock tree (CCU writes have no effect). No GPIO interrupts.
- `list thread` crashed on an early test image because of a too-small idle
  thread stack in that firmware (an RT-Thread side issue, fixed since).
- `--trace` output grows to hundreds of MB quickly.

### Self test

`tests/smoke.sh <rtthread.bin> <bsp-dir>` (add `LIST_THREAD=1 IDLE=120`
to also test `list thread` and re-test after 120 s idle); prints `PASS`
or `FAIL`.

### License

GPL-2.0-or-later (full text in `LICENSE`). Original QEMU copyright and
SPDX headers are kept unchanged.

### AI disclosure

The code and documentation in this repository were written with help from
an AI (Grok), and were reviewed and tested by a human.

### Acknowledgements

感谢 @BernardXiong 的支持

Thanks to @BernardXiong for his support.
