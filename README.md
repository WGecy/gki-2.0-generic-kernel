# GKI 2.0 通用内核 — 6.6.158

面向 GKI 2.0（android15-6.6，内核 6.6）设备的通用内核。

- **基线**：AOSP ACK `android15-6.6` 分支 tip（commit `448c303366032107c46d39006c8127a5ca967a26`）
- **形态**：单片内核（monolithic）。`arch/arm64/configs/gki_defconfig` 中 81 项 `=m` 改为 `=y`；
  剩余 19 项 `=m`（18 个 KUNIT/ZRAM 测试 + `ZSMALLOC`）
- **补丁**：共 **84 个**（`patches/`）
  - **3 个通用补丁**
    1. `kernel/module/version.c` — vermagic / 符号 CRC 校验绕过（`same_magic()`、`check_version()` 恒返回 1）
    2. `arch/arm64/configs/gki_defconfig` — `CONFIG_LOCALVERSION="-android15-8-4k"`，关闭 `LOCALVERSION_AUTO`
    3. `Makefile` — `SUBLEVEL = 158`
  - **1 个单片/LTO 配置补丁**：`0083-arm64-gki_defconfig-align-monolithic-image-with-Haru.patch`
  - **1 个 LTO 符号名补丁**：`0084-lto-keep-plain-symbol-names-for-statics-internalized.patch`
    — 给被 ThinLTO 内部化改名的 9 处文件级 `static` 加 `__used`，恢复 vmlinux 中的普通符号名
  - **79 条 stable 回补**：从上游 stable `v6.6.143..v6.6.157` 中挑选的修复
    （f2fs 16 · clk/qcom 15 · fuse 13 · GIC-v3-ITS 4 · erofs 3 · arm64 3 · selinux 2 · overlayfs 2 · 其余各 1）
- **版本串**：形如 `6.6.<SUBLEVEL>-android15-8[-<可选后缀>]-4k`（`uname -r`）。`-android15-8`
  对应 KMI（`BRANCH=android15-6.6` 的 `KMI_GENERATION=8`），`-4k` 是页大小；可选后缀默认为空，
  即默认版本串为 `6.6.158-android15-8-4k`
- **状态**：已在 GKI 2.0（android15-6.6）真机开机验证

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

工具链：系统 clang 19 + lld 19（`/usr/lib/llvm-19/bin` 与 `$GKI_ROOT/tools/lld19/usr/bin` 前置到 `PATH`）；`ARCH=arm64 LLVM=1`。

```bash
. env.sh
make O=out ARCH=arm64 LLVM=1 \
     KCFLAGS=-D__ANDROID_COMMON_KERNEL__ \
     HOSTCFLAGS="-I$GKI_ROOT/hosttools/root/usr/include" gki_defconfig
make O=out ARCH=arm64 LLVM=1 \
     KCFLAGS=-D__ANDROID_COMMON_KERNEL__ \
     HOSTCFLAGS="-I$GKI_ROOT/hosttools/root/usr/include" \
     CLANG_AUTOFDO_PROFILE=$GKI_ROOT/common/android/gki/aarch64/afdo/kernel.afdo \
     -j$(nproc) Image
```

默认版本串取 `gki_defconfig` 的 `CONFIG_LOCALVERSION="-android15-8-4k"`；需要自定义后缀时，可在
`gki_defconfig` 改 `CONFIG_LOCALVERSION`，或在上面两条 `make` 命令后追加 `LOCALVERSION=<后缀>`
（例如 `LOCALVERSION=-android15-8-custom-4k`）覆盖。

- AutoFDO profile 必须用**绝对路径**：`O=out` 下编译器 cwd 是 `out/`，相对路径会报
  `clang: error: no such file or directory`。profile 位于树内
  `common/android/gki/aarch64/afdo/kernel.afdo`（4.16MB）。
- LTO+AutoFDO 并行峰值内存约 15GB，默认 `-j$(nproc)`；仅在 OOM 时用 `JOBS=N` 降并行。

完整步骤见 `scripts/README-build.md`；`scripts/build.sh` 封装了 `Image` 编译。

## 打包

```bash
pack-boot.sh <stock boot.img> <Image> <out.img>
```

## CI 构建（GitHub Actions）

`.github/workflows/` 提供了两条工作流，**只编译内核并打成可直刷的 AnyKernel3 包**（不发布 Release、
不构建 KernelSU 管理器），产物为 `Image` + `*-AnyKernel3.zip` + `kernel.release` + `build-info.txt`：

- `build.yml`：可被调用的构建流程（`workflow_call`）。装依赖 → 拉 ACK 基线 → `git am patches/*.patch`
  → 装 clang-19 / lld-19 / llvm-19 与 AOSP build-tools → 跑 `scripts/ci-integrate.sh` 集成
  **BakaSU(KernelSU，Built-In 内建 `CONFIG_KSU=y`) + fusebpf + SUSFS + ADIOS IO 调度器 + Unicode 零宽字符绕过**
  → 生成并校验 defconfig → 编译 Image
  → 校验产物（版本串、`kernelsu_init`、SUSFS 初始化串、`Work mode: Built-in` 启动串、ADIOS 符号）
  → 用 `third_party/AnyKernel3` 打成 `android15-6.6.158-2026-09-AnyKernel3.zip` → 上传 artifact。
- `kernel-android15-6-6.yml`：手动触发（`workflow_dispatch`）。读 `data/android15/6.6.json` 的 `entries`
  生成矩阵，逐个调用 `build.yml`。输入：`ksu_branch`、`susfs_branch`、`susfs_pin`、`adios_lock`(off|cpq|all)、
  `custom_suffix`、`build_time`。

  BakaSU 按[官方文档](https://bakasu.org/guide/build)做**内建（Built-In）**集成：把
  `WGecy/BakaSU` 的 `kernel/` 以软链接放进内核树的 `drivers/kernelsu`，defconfig 打开
  `CONFIG_KSU=y`。钩子方式由 BakaSU 的 `kernel/Kconfig` choice 决定：SUSFS 打开时走
  `CONFIG_KSU_SUSFS`（SUSFS Inline Hook），否则走 GKI 2.0 默认的
  `CONFIG_KSU_TRACEPOINT_HOOK`（tracepoint syscall redirect）——两种都**不需要**手工改
  `fs/exec.c`、`fs/stat.c` 的内核源码；`CONFIG_KSU_MANUAL_HOOK` 会被显式关闭（那是给
  non-GKI 的，少写一个 hook 就编译失败）。上游 BakaSU 已移除 NoMount，因此产物里不再有
  `ksu_nomount_init` 符号或 `NoMount: Loaded successfully` 串。

  BakaSU 的源码是 **blobless + sparse-checkout** 克隆（`git clone --filter=blob:none` 后只
  checkout `kernel/`）：`kernel/Kbuild` 会检查 `../.git` 并用 `git rev-list --count` /
  `git describe --tags` 算版本号，且发现 `.git/shallow` 时会跑 `git fetch --unshallow`，
  所以不能用 `--depth 1` 浅克隆（CI 里容易拉不下来，版本号也会算错）。

  `susfs_pin` 是 SUSFS 的固定提交，默认 `93114563fd6b08092b9ce8c0309738c921ac8bd1`：非空时
  `ci-integrate.sh` 直接按该 commit 抓取（不克隆分支）并校验 `HEAD` 与之相等，构建期集成的 SUSFS
  版本就固定在这个提交上；留空则回退为跟随 `susfs_branch`。实际使用的提交会写进产物
  `build-info.txt` 的 `SUSFS_COMMIT` / `SUSFS_PIN` 两行。

内核树本身仍是纯 GKI：KSU/fusebpf/SUSFS/ADIOS/Unicode 全由 `scripts/ci-integrate.sh` 在 CI 构建期
集成，不会以源码形式进仓库。`third_party/` 里只有构建期素材：

| 目录 | 内容 | 集成方式 |
| --- | --- | --- |
| `third_party/adios/` | `14-adios.patch`（IO 调度器源码 + Kconfig/Makefile） | stage 4：`patch -p1` |
| `third_party/fusebpf/` | `fusebpf-lookup-revalidate-v3.patch`、`fusebpf-no-eexist.patch`（FUSE 直通 lookup 重新校验 + EEXIST→ENOENT 归一化，v3） | stage 2：`patch -p1`，无运行时开关、无配置项 |
| `third_party/unicode_bypass/` | `fusebpf-unicode-bypass-fix.patch`（UTF-8 归一化不再忽略零宽字符） | stage 5：`patch -p1`，需 `CONFIG_UNICODE=y` |
| `third_party/AnyKernel3/` | 打包脚本与工具 | 编译完成后把 Image 打成可直刷 zip |

这三个补丁的文件名与发布用的 `fusebpf-fix.zip` 内**一字不差**：换新补丁时把 zip 解压后直接覆盖
`third_party/fusebpf/` 与 `third_party/unicode_bypass/` 即可，不必改名，也不必改
`scripts/ci-integrate.sh`。文件名集中在脚本顶部（`FUSEBPF_PATCH` / `FUSEBPF_EEXIST_PATCH` /
`UNICODE_PATCH`），确实要换名时只改这三行。

集成顺序固定为 BakaSU → fusebpf → SUSFS → ADIOS → Unicode → defconfig；每个 stage 应用补丁后都会
校验落点标记（例如 fusebpf 的 `fuse_lookup_revalidate_initialize/backing/finalize`、Unicode 的
`utf8data[64080]`），缺失即构建失败，不会静默跳过。

## 从零复现

```bash
git clone https://android.googlesource.com/kernel/common common
cd common
git checkout 448c303366032107c46d39006c8127a5ca967a26    # 基线 tip
git am /path/to/patches/*.patch                          # 84 个补丁
```

## 说明与边界

- 仓库里的内核源码本身不含 KSU/SUSFS —— 纯 GKI，无 root；带 root 的版本由 CI 在构建期集成
- fusebpf 与 Unicode 绕过同样是构建期打的补丁，仓库里的 `common/` 树保持上游原样
- 不含任何编译产物（无 Image / boot.img / .o / .ko）
- 部分 OEM-GKI 设备的 stock 内核带厂商私有补丁（例如某些机型的 f2fs hybrid-UFS / IOSTAT 等）。
  本内核不含这些特性；实测不影响启动（vendor 模块经通用补丁 1 正常加载）。
- 内核源码为 **GPL-2.0**，见 [LICENSE](LICENSE)
