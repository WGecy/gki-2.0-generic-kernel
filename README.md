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

## 说明与边界

- 不含 KSU/SUSFS —— 纯 GKI，无 root
- 不含任何编译产物（无 Image / boot.img / .o / .ko）
- 部分 OEM-GKI 设备的 stock 内核带厂商私有补丁（例如某些机型的 f2fs hybrid-UFS / IOSTAT 等）。
  本内核不含这些特性；实测不影响启动（vendor 模块经通用补丁 1 正常加载）。
- 内核源码为 **GPL-2.0**，见 [LICENSE](LICENSE)
