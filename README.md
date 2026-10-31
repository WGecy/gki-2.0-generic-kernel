# GKI 2.0 通用内核 — 6.6.158

面向 GKI 2.0（android15-6.6，内核 6.6）设备的通用内核。

- **基线**：AOSP ACK `android15-6.6` 分支 tip（commit `448c303366032107c46d39006c8127a5ca967a26`）
- **形态**：单片内核（monolithic）。`arch/arm64/configs/gki_defconfig` 中 81 项 `=m` 改为 `=y`；
  剩余 19 项 `=m`（18 个 KUNIT/ZRAM 测试 + `ZSMALLOC`）
- **补丁**：共 **84 个**（`patches/`）
  - **3 个通用补丁**
    1. `kernel/module/version.c` — vermagic / 符号 CRC 校验绕过（`same_magic()`、`check_version()` 恒返回 1）
    2. `arch/arm64/configs/gki_defconfig` — `CONFIG_LOCALVERSION="-android15-8"`，关闭 `LOCALVERSION_AUTO`
    3. `Makefile` — `SUBLEVEL = 158`
  - **1 个单片/LTO 配置补丁**：`0083-arm64-gki_defconfig-align-monolithic-image-with-Haru.patch`
  - **1 个 LTO 符号名补丁**：`0084-lto-keep-plain-symbol-names-for-statics-internalized.patch`
    — 给被 ThinLTO 内部化改名的 9 处文件级 `static` 加 `__used`，恢复 vmlinux 中的普通符号名
  - **79 条 stable 回补**：从上游 stable `v6.6.143..v6.6.157` 中挑选的修复
    （f2fs 16 · clk/qcom 15 · fuse 13 · GIC-v3-ITS 4 · erofs 3 · arm64 3 · selinux 2 · overlayfs 2 · 其余各 1）
- **版本串**：形如 `6.6.<SUBLEVEL>-android15-8[-<可选后缀>]-4k`（`uname -r`）。`-android15-8`
  对应 KMI（`BRANCH=android15-6.6` 的 `KMI_GENERATION=8`，来自 `CONFIG_LOCALVERSION`），`-4k` 是页大小
  （来自 `LOCALVERSION`，永远在末尾）；可选后缀缺省为 `-WGecy`，即默认版本串
  `6.6.158-android15-8-WGecy-4k`
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

版本串由 `scripts/setlocalversion` 逐段拼接：`${KERNELVERSION}${file_localversion}` +
  `CONFIG_LOCALVERSION`（前段，`-android15-8`）+ `LOCALVERSION`（后段）+ `scm_version`。
`scripts/build.sh` 默认传 `LOCALVERSION=-WGecy-4k`，得到 `6.6.158-android15-8-WGecy-4k`；
需要自定义后缀时用 `LOCALVERSION=<后缀>` 覆盖，`-4k` 由脚本自动追加
（例如 `LOCALVERSION=-test-01` → `6.6.158-android15-8-test-01-4k`）。
**不要把 `-4k` 写回 `CONFIG_LOCALVERSION`**：它在拼接序列里排在 `LOCALVERSION` 之前，
会把后缀挤到 `-4k` 后面变成 `...-4k-<后缀>`。

- AutoFDO profile 必须用**绝对路径**：`O=out` 下编译器 cwd 是 `out/`，相对路径会报
  `clang: error: no such file or directory`。profile 位于树内
  `common/android/gki/aarch64/afdo/kernel.afdo`（4.16MB）。
- LTO+AutoFDO 并行峰值内存约 15GB，默认 `-j$(nproc)`；仅在 OOM 时用 `JOBS=N` 降并行。

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
git am /path/to/patches/*.patch                          # 84 个补丁
```

## GitHub Actions 构建（BakaSU + SUSFS + NoMount + ADIOS + Unicode 绕过）

仓库自带一套 Actions 工作流，在 CI 里把 **BakaSU（KernelSU）+ SUSFS + NoMount +
ADIOS IO 调度器 + Unicode 零宽字符绕过** 集成到本内核上，产出可直接刷入的 AnyKernel3 包与
合并 Release。迁移自老内核项目 `ReSukiSU-Ultra-Kernel` 的 `kernel-android15-6-6.yml` 工作流。

```
.github/workflows/
├── kernel-android15-6-6.yml   入口: 版本矩阵 + 调用构建 + 拉管理器 APK + 合并发布
├── build.yml                  可复用: 拉源码 → git am patches → 集成 → 编译 → 打包
└── get-manager.yml            拉取 BakaSU 管理器 APK (Release → Actions 制品 两级降级)
data/android15/6.6.json        版本矩阵 (含基线 commit)
docs/feature-diff.md           新老内核功能差异表 (迁移状态 + 维护指引)
scripts/ci-integrate.sh        KSU + fusebpf + SUSFS + NoMount + ADIOS + Unicode 绕过 集成
third_party/AnyKernel3/        打包模板 (迁移自老项目)
third_party/adios/             ADIOS IO 调度器补丁 (迁移自老项目)
third_party/fusebpf/           fusebpf 内核侧补丁 v3 (lookup revalidate + EEXIST 归一化)
third_party/nomount/           NoMount v2.2.0 内核源 (Kconfig/Makefile/nomount.c+nomount.h)
third_party/unicode_bypass/    Unicode 零宽字符绕过补丁 (改 fs/unicode 归一化数据表)
```

要点：

- **KernelSU 指向**：集成脚本默认拉 `https://github.com/WGecy/BakaSU`（分支 `main`），
  可用 `--ksu-repo` / 工作流输入 `ksu_repo` 覆盖。
- **管理器 APK 来源**：`WGecy/BakaSU` 目前没有 Release，get-manager 会退回下载其
  `build-manager` 最近一次成功运行的 `Manager-release` 制品；跨仓库读制品需在本仓库配置
  secret `KSU_REPO_TOKEN`（详见 [`scripts/README-ci.md`](scripts/README-ci.md)）。
- **基线可复现**：按 `data/android15/6.6.json` 里的 `baseline_commit` 精确浅取 ACK 源码，
  `git am patches/*.patch` 之后才开始集成；基线不一致直接失败（补丁是按该 commit 生成的）。
- **工具链**：系统 clang 19 + lld 19（Ubuntu 24.04 的 `clang-19`/`lld-19`/`llvm-19`，
  `/usr/lib/llvm-19/bin` 前置到 `PATH`，与 `scripts/env.sh` 同一套做法；CFI type hash 与 clang
  版本绑定，必须与 KMI 同为 clang 19）+ `kernel/prebuilts/build-tools`（pahole/lz4/dtc，
  走 Actions 缓存）；`ARCH=arm64 LLVM=1`。
- **集成顺序**：KernelSU（`drivers/kernelsu` 内建）→ fusebpf（`third_party/fusebpf`，
  上游式 lookup revalidate v3 + `EEXIST→ENOENT` 归一化）→ SUSFS（gitlab 上游
  50_add_susfs 补丁 + 源码）→ NoMount v2.2.0（目录式内建 `fs/nomount/`，dentry/inode ops
  劫持 + `add_key` 单页 payload IPC；v2 起不再需要 VFS hook 补丁）→ ADIOS（调度器补丁 +
  无条件把 `elevator_get_default()` 改成 adios；`adios_lock` 只决定是否在
  `elevator_change()` 注入拦截，默认 `off` 不拦）→ Unicode 绕过
  （改 `fs/unicode` 归一化数据表，去掉零宽字符 ignore 类）→ defconfig 注入开关。
- **fusebpf v3**：`third_party/fusebpf/fusebpf-lookup-revalidate.patch` 是上游式
  `fuse_lookup_revalidate_{initialize,backing,finalize}` 实现（`fs/fuse/{backing.c,dir.c,fuse_i.h}`
  + fuse selftest），`fusebpf-no-eexist.patch` 把 mknod/mkdir/link/symlink 的 `EEXIST` 归一化为
  `ENOENT`（hidden 目录不再把"已存在"当成"创建失败"）。v3 让该修复**无条件生效**，运行时开关随之下线：
  ReSukiSU-Ultra 侧（BakaSU 沿用）已同步删除 `CONFIG_KSU_FUSEBPF_FIX`、`CMD_FUSEBPF_SET`、`ksud fusebpf`
  子命令与 `kernel-patches/fusebpf/`，因此内核侧不再需要任何兼容垫片；若换回仍引用旧符号的
  KSU，`ci-integrate.sh` 会立即报错（否则内建 KSU 会在链接 vmlinux 时报 undefined symbol）。
- **ADIOS 默认调度器与锁定**：只要编了 ADIOS（非 `--no-adios`），就注入
  `elevator_get_default()` 并打开 `CONFIG_MQ_IOSCHED_DEFAULT_ADIOS`，**默认调度器恒为 adios**，
  与 `adios_lock` 无关。`adios_lock` 只控制 `elevator_change()` 的运行时拦截：
  `off`（默认）= 不拦截（澎湃OS4 的 `init.qti.kernel.rc` 每次开机写 `cpq` 会生效，调度器被切走）；
  `cpq` = 拒绝切到 `cpq`；`all` = 拒绝任何非 adios 切换。工作流输入 `adios_lock`（`off`/`cpq`/`all`）。
- **构建后强校验**：`kernel.release` 与 Image 里的版本串、`vmlinux` 里必须出现
  `kernelsu_init`、`susfs is initialized` —— 防止“补丁打上了但没编译进去”。
  NoMount v2.2.0 已无 v1 的 `nm_rules` slab 名，改为三条判据**任一命中即通过**：
  `vmlinux` 里的 `nomount_init` 符号（`fs_initcall` 注册，必然保留）、
  `.rodata` 里的 `NoMount: Loaded successfully`（`nm_info` 前缀 + 格式串编译期拼接）、
  或 `out/modules.builtin.modinfo` 里的 `NoMount Path Redirection VFS Subsystem`。
  **`MODULE_DESCRIPTION` 串不能当唯一判据**：它只落在 `.modinfo` 段，而该段被
  `include/asm-generic/vmlinux.lds.h` 的 `COMMON_DISCARDS` 在链接最终 `vmlinux` 时丢弃。
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
