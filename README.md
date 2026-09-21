# GKI 2.0 通用内核 — 6.6.158-lts

面向 **GKI 2.0（android15-6.6，内核 6.6）** 设备的通用内核。

- **基线**：AOSP ACK `android15-6.6` 分支 tip（截至 2026-09-17，commit `448c303366032107c46d39006c8127a5ca967a26`）
- **差异**：仅 3 个补丁（见 `patches/`）

## 三个补丁做什么

1. `kernel/module/version.c` — **vermagic / 符号 CRC 绕过**：`same_magic()` 与 `check_version()` 恒返回 1
   > GKI 设备的 vendor 模块（`/vendor_dlkm`、`/system_dlkm`）在厂商的内核二进制上编译，vermagic
   > （形如 `6.6.118-android15-8-g<commit>-ab<salt>-4k`）与本内核不可能一致；`CONFIG_MODVERSIONS=y`
   > 还会比对符号 CRC。不改内核就无法加载它们。这是**显式、可审计地放弃该校验**，不是伪造。
2. `arch/arm64/configs/gki_defconfig` — `CONFIG_LOCALVERSION="-lts"`，关闭 `LOCALVERSION_AUTO`
3. `Makefile` — `SUBLEVEL = 158`

`uname -r` → `6.6.158-lts`

## 为什么直接用分支 tip，而不是自己挑补丁

`android15-6.6` tip 已包含 AOSP 为 6.6 合并/回移的全部安全与性能修复（含上游 stable 的后续版本）。
直接用 tip 比逐个 cherry-pick 更可靠 —— AOSP 做过适配与冲突解决。

## 构建

见 `scripts/README-build.md`。要点：AOSP 预编译 clang（r510928）、`ARCH=arm64 LLVM=1`、
`make O=out ... gki_defconfig && make O=out ... Image`；`scripts/build.sh` 已封装。

## 从零复现

```bash
git clone https://android.googlesource.com/kernel/common common
cd common
git checkout 448c303366032107c46d39006c8127a5ca967a26    # 基线 tip
git am /path/to/patches/*.patch
```

## 说明与边界

- 不含 KSU/SUSFS —— 纯 GKI，无 root
- 不含任何编译产物（无 Image / boot.img / .o / .ko）
- 部分 OEM-GKI 设备的 stock 内核带厂商私有补丁（例如某些机型的 f2fs hybrid-UFS / IOSTAT 等）。
  本内核不含这些特性；实测**不影响启动**（vendor 模块经上述绕过正常加载）。
- 内核源码为 **GPL-2.0**，见 [LICENSE](LICENSE)
