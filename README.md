# GKI 2.0 通用内核 — 6.6.158

面向 GKI 2.0（android15-6.6，内核 6.6）设备的通用内核。

- **基线**：AOSP ACK `android15-6.6` 分支 tip（commit `448c303366032107c46d39006c8127a5ca967a26`）
- **形态**：单片内核（monolithic）。`arch/arm64/configs/gki_defconfig` 中 81 项 `=m` 改为 `=y`；
  剩余 19 项 `=m`（18 个 KUNIT/ZRAM 测试 + `ZSMALLOC`）
- **补丁**：共 **83 个**（`patches/`）
  - **3 个通用补丁**
    1. `kernel/module/version.c` — vermagic / 符号 CRC 校验绕过（`same_magic()`、`check_version()` 恒返回 1）
    2. `arch/arm64/configs/gki_defconfig` — `CONFIG_LOCALVERSION=""`，关闭 `LOCALVERSION_AUTO`
    3. `Makefile` — `SUBLEVEL = 158`
  - **1 个单片/LTO 配置补丁**：`0083-arm64-gki_defconfig-align-monolithic-image-with-Haru.patch`
  - **79 条 stable 回补**：从上游 stable `v6.6.143..v6.6.157` 中挑选的修复
    （f2fs 16 · clk/qcom 15 · fuse 13 · GIC-v3-ITS 4 · erofs 3 · arm64 3 · selinux 2 · overlayfs 2 · 其余各 1）
- **版本串**：`6.6.158`（`uname -r`）
- **状态**：已在真机（Qualcomm SM8750 / HyperOS）开机验证，`uname -r` = `6.6.158`

## 通用补丁 1：vermagic / CRC 绕过做什么

`kernel/module/version.c` 中 `same_magic()` 与 `check_version()` 恒返回 1。GKI 设备的 vendor 模块
（`/vendor_dlkm`、`/system_dlkm`）在厂商的内核二进制上编译，其 vermagic（形如
`6.6.<x>-android15-8-g<commit>-ab<salt>-4k`）与本内核不一致；`CONFIG_MODVERSIONS=y` 还会比对符号 CRC。
不改内核就无法加载它们。该补丁显式放弃这两项校验。

## 构建选项

开启：`LTO`、`LTO_CLANG`、`LTO_CLANG_THIN`、`AUTOFDO_CLANG`、`CFI_PERMISSIVE`、`IDLE_PAGE_TRACKING`、
`TRANSPARENT_HUGEPAGE_ALWAYS`、`TMPFS_POSIX_ACL`、`TMPFS_XATTR`、`RCU_NOCB_CPU_DEFAULT_ALL`、
`TASKS_TRACE_RCU_READ_MB`、`PCIEASPM_POWER_SUPERSAVE`、`WQ_POWER_EFFICIENT_DEFAULT`。

关闭：`LTO_NONE`、`TRANSPARENT_HUGEPAGE_MADVISE`、`PCIEASPM_DEFAULT`。

## 构建

工具链：AOSP 预编译 clang r510928；`ARCH=arm64 LLVM=1`。

```bash
. env.sh
make O=out ARCH=arm64 LLVM=1 LOCALVERSION= \
     KCFLAGS=-D__ANDROID_COMMON_KERNEL__ \
     HOSTCFLAGS="-I$GKI_ROOT/hosttools/root/usr/include" gki_defconfig
make O=out ARCH=arm64 LLVM=1 LOCALVERSION= \
     KCFLAGS=-D__ANDROID_COMMON_KERNEL__ \
     HOSTCFLAGS="-I$GKI_ROOT/hosttools/root/usr/include" \
     CLANG_AUTOFDO_PROFILE=$GKI_ROOT/common/android/gki/aarch64/afdo/kernel.afdo \
     -j8 Image
```

- AutoFDO profile 必须用**绝对路径**：`O=out` 下编译器 cwd 是 `out/`，相对路径会报
  `clang: error: no such file or directory`。profile 位于树内
  `common/android/gki/aarch64/afdo/kernel.afdo`（4.16MB）。
- LTO 构建内存占用高，`-j8` 实测可通过（`build.sh` 默认 `-j$(nproc)`，LTO 下峰值更高）。

完整步骤见 `scripts/README-build.md`；`scripts/build.sh` 封装了 `Image` 编译。

## 打包

```bash
pack-boot.sh <stock boot.img> <Image> <out.img>
```

## 从零复现

```bash
git clone https://android.googlesource.com/kernel/common common
cd common
git checkout 448c303366032107c46d39006c8127a5ca967a26    # 基线 tip
git am /path/to/patches/*.patch                          # 83 个补丁
```

## GitHub Actions 构建（ReSukiSU-Ultra + SUSFS + NoMount + ADIOS + Unicode 绕过）

仓库自带一套 Actions 工作流，在 CI 里把 **ReSukiSU-Ultra（KernelSU）+ SUSFS + NoMount +
ADIOS IO 调度器 + Unicode 零宽字符绕过** 集成到本内核上，产出可直接刷入的 AnyKernel3 包与
合并 Release。迁移自老内核项目 `ReSukiSU-Ultra-Kernel` 的 `kernel-android15-6-6.yml` 工作流。

```
.github/workflows/
├── kernel-android15-6-6.yml   入口: 版本矩阵 + 调用构建 + 拉管理器 APK + 合并发布
├── build.yml                  可复用: 拉源码 → git am patches → 集成 → 编译 → 打包
└── get-manager.yml            拉取 ReSukiSU-Ultra 管理器 APK
data/android15/6.6.json        版本矩阵 (含基线 commit)
docs/feature-diff.md           新老内核功能差异表 (迁移状态 + 维护指引)
scripts/ci-integrate.sh        KSU + fusebpf + SUSFS + NoMount + ADIOS + Unicode 绕过 集成
third_party/AnyKernel3/        打包模板 (迁移自老项目)
third_party/adios/             ADIOS IO 调度器补丁 (迁移自老项目)
third_party/fusebpf/           KSU fusebpf 内核侧补丁 (迁移自老项目, KSU_FUSEBPF_FIX 依赖)
third_party/nomount/           NoMount hook 补丁 + nomount.c/h 源码
third_party/unicode_bypass/    Unicode 零宽字符绕过补丁 (迁移自老项目)
```

要点：

- **基线可复现**：按 `data/android15/6.6.json` 里的 `baseline_commit` 精确浅取 ACK 源码，
  `git am patches/*.patch` 之后才开始集成；基线不一致直接失败（补丁是按该 commit 生成的）。
- **工具链**：AOSP 预编译 `clang-r510928` + `kernel/prebuilts/build-tools`（pahole/lz4/dtc），
  `ARCH=arm64 LLVM=1`，与 `scripts/build.sh` 完全一致；工具链走 Actions 缓存。
- **集成顺序**：KernelSU（`drivers/kernelsu` 内建）→ fusebpf（KSU 仓库
  `kernel-patches/fusebpf`，提供内核侧 `fuse_bpf_lookup_revalidate_*`）→ SUSFS（gitlab 上游
  50_add_susfs 补丁 + 源码）→ NoMount（hook 补丁 + 源码）→ ADIOS（调度器补丁 +
  `elevator_get_default()` 强制 adios + `elevator_change()` 拦截 `cpq`）→ Unicode 绕过
  （改 `fs/unicode` 归一化数据表）→ defconfig 注入开关。
- **ADIOS 锁定**：澎湃OS4（Android 17）的 `init.qti.kernel.rc` 会在每次开机把 userdata
  调度器写成 `cpq`，因此默认在 `elevator_change()` 拒绝切到 `cpq`（工作流输入
  `adios_lock`：`cpq`/`all`/`off`）；刷机后可验 `cat /sys/block/sda/queue/scheduler` 应为 `[adios]`。
- **构建后强校验**：`kernel.release` 与 Image 里的版本串、`vmlinux` 里必须出现
  `kernelsu_init`、`susfs is initialized`、`nm_rules` —— 防止“补丁打上了但没编译进去”。
- **产物**：`android15-6.6.<sub>-<snapshot>-AnyKernel3.zip`、裸 `Image-6.6.<sub>`、
  `build-info.txt`，合并发布到 `kernel-latest`（含管理器 APK）。

触发方式：`Actions → GKI 2.0 内核构建 - Android 15 (6.6) → Run workflow`，
可填 KSU 仓库/分支、SUSFS 分支、自定义内核后缀、自定义构建时间。详见
[scripts/README-ci.md](scripts/README-ci.md)；**还缺哪些老项目功能、怎么补**见
[docs/feature-diff.md](docs/feature-diff.md)。

## 说明与边界

- 仓库内的内核树是**纯 GKI**（不含 KSU/SUSFS/NoMount/ADIOS/Unicode 绕过）；root 与隐藏能力
  由上面这套 Actions 工作流在构建时集成，本地构建（`scripts/build.sh`）默认仍是纯 GKI。
- 不含任何编译产物（无 Image / boot.img / .o / .ko）
- 部分 OEM-GKI 设备的 stock 内核带厂商私有补丁（例如某些机型的 f2fs hybrid-UFS / IOSTAT 等）。
  本内核不含这些特性；实测不影响启动（vendor 模块经通用补丁 1 正常加载）。
- 内核源码为 **GPL-2.0**，见 [LICENSE](LICENSE)
