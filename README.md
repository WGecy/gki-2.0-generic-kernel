# GKI 2.0 通用内核 — 6.6.158

面向 **GKI 2.0（android15-6.6，内核 6.6）** 设备的通用内核。

- **基线**：AOSP ACK `android15-6.6` 分支 tip（commit `448c303366032107c46d39006c8127a5ca967a26`）
- **差异**：共 **82 个补丁**（`patches/`）
  - **3 个通用补丁**：vermagic/CRC 绕过 · 空 `LOCALVERSION`（版本串 `6.6.158`） · `SUBLEVEL = 158`
  - **79 条回补**：从上游 stable `v6.6.143..v6.6.157` 精挑的修复
    （f2fs 16 · clk/qcom 15 · fuse 13 · GIC-v3-ITS 4 · erofs 3 · arm64 3 · selinux 2 · overlayfs 2 · 其余各 1）

  > 为什么要回补：AOSP 的 `android15-6.6` 分支**仍停在 stable 6.6.142**（未做 6.6.143+ 的批量合并，
  > 只是逐个挑 `UPSTREAM:`/`BACKPORT:` 提交）。逐条比对后，那 83 条修复里 AOSP 只挑了 4 条，
  > 故回补其余 **79** 条。

- **状态**：✅ 已在真机（Qualcomm SM8750 / HyperOS）**实测开机**，`uname -r` = `6.6.158`

## 三个通用补丁做什么

1. `kernel/module/version.c` — **vermagic / 符号 CRC 绕过**：`same_magic()` 与 `check_version()` 恒返回 1
   > GKI 设备的 vendor 模块（`/vendor_dlkm`、`/system_dlkm`）在厂商的内核二进制上编译，其 vermagic
   > （形如 `6.6.118-android15-8-g<commit>-ab<salt>-4k`）与本内核不可能一致；`CONFIG_MODVERSIONS=y`
   > 还会比对符号 CRC。不改内核就无法加载它们。这是**显式、可审计地放弃该校验**，不是伪造。
2. `arch/arm64/configs/gki_defconfig` — `CONFIG_LOCALVERSION=""`，关闭 `LOCALVERSION_AUTO`
3. `Makefile` — `SUBLEVEL = 158`

## 构建

见 `scripts/README-build.md`。要点：AOSP 预编译 clang（r510928）、`ARCH=arm64 LLVM=1`、
`make O=out ... gki_defconfig && make O=out ... Image`；`scripts/build.sh` 已封装。

## 从零复现

```bash
git clone https://android.googlesource.com/kernel/common common
cd common
git checkout 448c303366032107c46d39006c8127a5ca967a26    # 基线 tip
git am /path/to/patches/*.patch                          # 82 个补丁
```

## 说明与边界

- 不含 KSU/SUSFS —— 纯 GKI，无 root
- 不含任何编译产物（无 Image / boot.img / .o / .ko）
- 部分 OEM-GKI 设备的 stock 内核带厂商私有补丁（例如某些机型的 f2fs hybrid-UFS / IOSTAT 等）。
  本内核不含这些特性；实测**不影响启动**（vendor 模块经上述绕过正常加载）。
- 内核源码为 **GPL-2.0**，见 [LICENSE](LICENSE)
