# GKI_ROOT GKI 6.6.118 Image 构建记录（plain make + 官方 hermetic 工具，无 root）

## 目标
产出与设备 stock 内核 **逐字节相同 vermagic** 的 GKI 2.0 Image，使 stock vendor 驱动可继续加载。

- 设备 stock：`6.6.118-android15-8-gc4127a25dcf3-ab15863337-4k`
- 源码提交 `c4127a25dcf3` = 公开 tag **`android15-6.6-2026-01_r37`**（Makefile SUBLEVEL=118）
- 结果：vermagic `6.6.118-android15-8-gc4127a25dcf3-ab15863337-4k SMP preempt mod_unload modversions aarch64` ✅ 完全一致

## 目录
```
~/gki-kernel/
├── common/            kernel/common @ android15-6.6-2026-01_r37 (shallow clone)
├── clang-prebuilt/    prebuilts/clang/host/linux-x86 (sparse: clang-r510928)
├── kbt/               kernel/prebuilts/build-tools (pahole/lz4/dtc/depmod + lib64)
├── pbt/               platform/prebuilts/build-tools (bison/flex/m4/openssl)
├── hosttools/         本地解包的 Debian 包（无需 root）：bison flex m4 libelf-dev zlib1g-dev pkgconf
│   ├── bin/           自包含 wrapper: pkg-config / pahole
│   └── pkgconfig/     重写过路径的 libelf.pc
├── env.sh             环境变量
├── build.sh           编译脚本
└── Image-6.6.118-gki4k  产物（36735488 bytes, sha256 5aa68fe7…）
```

## 复现步骤
```bash
# 1) 源码
git clone --depth 1 -b android15-6.6-2026-01_r37 \
  https://android.googlesource.com/kernel/common ~/gki-kernel/common
# 2) clang r510928
git clone --filter=blob:none --sparse -b main-kernel-build-2024 \
  https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 ~/gki-kernel/clang-prebuilt
git -C ~/gki-kernel/clang-prebuilt sparse-checkout set clang-r510928
# 3) 官方宿主工具（pahole v1.25 / lz4 / dtc / depmod）
git clone --filter=blob:none --sparse -b main-kernel-build-2024 \
  https://android.googlesource.com/kernel/prebuilts/build-tools ~/gki-kernel/kbt
git -C ~/gki-kernel/kbt sparse-checkout set linux-x86/bin linux-x86/lib64
# 4) 无 root 替代 apt：本地解包 bison/flex/m4/libelf-dev/zlib1g-dev/pkgconf
cd ~/gki-kernel/hosttools && apt-get download bison flex m4 libfl2 libelf-dev zlib1g-dev pkgconf pkgconf-bin libpkgconf3
for d in *.deb; do dpkg-deb -x "$d" root/; done
# 注意：libelf-dev 带静态 libelf.a 会被误链接，需改为指向系统共享库
cd root/usr/lib/x86_64-linux-gnu && ln -sf /usr/lib/x86_64-linux-gnu/libelf.so.1 libelf.so && rm -f libelf.a
# 5) 配置 + 钉版本串
. ~/gki-kernel/env.sh && cd ~/gki-kernel/common
make O=out ARCH=arm64 LLVM=1 gki_defconfig
./scripts/config --file out/.config --disable LOCALVERSION_AUTO
printf %s "-android15-8-gc4127a25dcf3-ab15863337" > out/localversion
# 6) 编译
~/gki-kernel/build.sh        # make O=out ARCH=arm64 LLVM=1 LOCALVERSION= KCFLAGS=-D__ANDROID_COMMON_KERNEL__ -j16 Image
# 7) 校验
strings out/arch/arm64/boot/Image | grep "Linux version"
```

## 版本串是怎么拼出来的
`scripts/setlocalversion:208` 顺序：`KERNELVERSION + file_localversion + config_localversion + LOCALVERSION + scm_version`
- `KERNELVERSION` = 6.6.118（Makefile）
- `file_localversion` = `out/localversion` 文件内容 = `-android15-8-gc4127a25dcf3-ab15863337`
- `config_localversion` = `CONFIG_LOCALVERSION="-4k"`（`arch/arm64/configs/gki_defconfig:2` 自带）
- `LOCALVERSION` 空 + `CONFIG_LOCALVERSION_AUTO` 关闭 → `scm_version` 为空
（官方 Kleaf 构建里 `-android15-8` 前缀由 `kleaf/impl/stamp.bzl` 加、`-ab<号>` 由 `workspace_status_stamp.py:166` 从 `BUILD_NUMBER` 加）

## 与官方构建的唯一有意差异
官方 config 里有 `CONFIG_TRIM_UNUSED_KSYMS=y` + `CONFIG_UNUSED_KSYMS_WHITELIST="abi_symbollist.raw"`
（由 Kleaf 注入，见 `kleaf/impl/raw_kmi_symbol_list.bzl:37`）。本构建**未开启**该裁剪
→ 导出符号是官方 KMI 的**超集**，对 stock 驱动加载更宽松（用户已确认接受）。

## 说明
- 未使用 GCC：`CONFIG_CFI_CLANG=y` 只有 clang 支持，且 CFI type hash 与 clang 版本绑定，
  因此必须用与官方完全相同的 clang-r510928（构建日志里的编译器串与 stock Image 完全一致）。
- 宿主不需要装 clang/bazel/bison/flex/libelf-dev（全部本地化，无 root）。

---

# 第二部分：KernelSU (ReSukiSU) + SUSFS 版本

## 版本选定（版本号可精确推算）
- ReSukiSU 的版本号公式（`manager/build.gradle.kts:16` 与 `kernel/Kbuild:77` 相同）：
  `version = 30000 + git_commit_count + 700`
- `main` HEAD 的 `git rev-list --count HEAD` = **4454** → **KSU_VERSION = 35154** ✅（与官方最新版号一致）
- SUSFS：`gitlab.com/simonpunk/susfs4ksu` 分支 `gki-android15-6.6`，`SUSFS_VERSION "v2.3.0"` ✅

## 集成步骤（手工复刻 `kernel/setup.sh`，避免克隆 61GB 全仓）
```bash
# 1) ReSukiSU 驱动（partial clone + sparse，保留完整 git 历史以算出 35154）
git clone --filter=blob:none --no-checkout --single-branch -b main \
    https://github.com/ReSukiSU/ReSukiSU ~/gki-kernel/resukisu-hist
git -C ~/gki-kernel/resukisu-hist sparse-checkout set kernel uapi   # uapi 必须取，否则编译报 uapi/feature.h not found
# 2) 接入内核树
cd ~/gki-kernel/common/drivers && ln -sfn ../../resukisu-hist/kernel kernelsu
printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> Makefile
sed -i '/^endmenu/i\source "drivers/kernelsu/Kconfig"' Kconfig
# 3) SUSFS 内核侧补丁
git clone --depth 1 -b gki-android15-6.6 https://gitlab.com/simonpunk/susfs4ksu.git ~/gki-kernel/susfs4ksu
cd ~/gki-kernel/common
cp ~/gki-kernel/susfs4ksu/kernel_patches/fs/susfs.c fs/
cp ~/gki-kernel/susfs4ksu/kernel_patches/include/linux/susfs{,_def}.h include/linux/
patch -p1 < ~/gki-kernel/susfs4ksu/kernel_patches/50_add_susfs_in_gki-android15-6.6.patch   # 25 文件全干净应用
# 注意：跳过 kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch —— 那是给上游 weishu/KernelSU 的，
#       ReSukiSU 驱动侧已内置 SUSFS（supercall/dispatch.c 有 31 处 SUSFS_ 处理）
# 4) 配置
make O=out ARCH=arm64 LLVM=1 olddefconfig
./scripts/config --file out/.config --enable KSU --enable KSU_SUSFS
make O=out ARCH=arm64 LLVM=1 syncconfig
# 5) 编译
~/gki-kernel/build.sh
# 6) 打包（新内核 37MB > 原内核，pack-boot.sh 已处理越界清零点）
./pack-boot.sh "/home/tees//path/to/stock_boot.img" \
    Image-6.6.118-gki4k-ksu-susfs-35154 boot-gki-kernel-6.6.118-ksu-susfs.img
```

## 生效的配置
```
CONFIG_KSU=y                      # 内置（非 LKM）
CONFIG_KSU_SUSFS=y                # 选择 SUSFS Inline Hook（choice，自动关掉 TRACEPOINT/MANUAL）
# CONFIG_KSU_TRACEPOINT_HOOK is not set
# CONFIG_KSU_MANUAL_HOOK is not set
CONFIG_KSU_SUSFS_{SUS_PATH,SUS_MOUNT,SUS_KSTAT,SPOOF_UNAME,ENABLE_LOG,
  HIDE_KSU_SUSFS_SYMBOLS,SPOOF_CMDLINE_OR_BOOTCONFIG,OPEN_REDIRECT,SUS_MAP}=y
CONFIG_LOCALVERSION="-4k"         # 保持，版本串不变
# CONFIG_LOCALVERSION_AUTO is not set
```

## 回归验证（关键）
| 项目 | 结果 |
|---|---|
| vermagic | `6.6.118-android15-8-gc4127a25dcf3-ab15863337-4k SMP preempt mod_unload modversions aarch64` 与 stock **完全一致** ✅ |
| 导出符号 CRC | 基线 16555 个符号 → **CRC 变化 0、消失 0、新增 0**（`baseline-vmlinux.symvers` vs `out/vmlinux.symvers`）✅ → stock 驱动不会因 CRC 失配而拒载 |
| 镜像内容 | 含 `KernelSU`/`susfs` 字符串；Image 37,001,728 B（纯净版 +266KB）|
| boot.img | v4/4096 页/无 ramdisk/AVB 已清、内核区 sha256 校验一致 |

## 刷机
```bash
fastboot flash boot boot-gki-kernel-6.6.118-ksu-susfs.img
# 之后安装 ReSukiSU Manager 35154（版本号必须与内核 KSU_VERSION 匹配）
# 验证：
adb shell uname -r                      # 必须仍是 6.6.118-android15-8-gc4127a25dcf3-ab15863337-4k
adb shell su -c 'dmesg | grep -iE "susfs|KernelSU version"'
adb shell 'cat /proc/modules | wc -l'    # 约 604，与刷机前一致
```

---

# 第三部分：zram 内置 + LZ4KD 压缩 + 隐藏算法列表

## 来源与血统（重要）
- LZ4K / LZ4KD 源码：`https://github.com/ShirkNeko/SukiSU_patch` → `other/zram/lz4k`
  记录 commit：`547ae94bcaec53d030398f857950c64662043a5d`
- 代码版权：`Copyright (c) Huawei Technologies Co., Ltd. 2022`（GPL / Dual BSD-GPL），
  `lz4kd_version() = "2022.03.20"`。LZ4KD = LZ4K + delta（用前一缓冲当字典），
  state 缓冲在 tfm 上下文里**只分配一次并跨调用复用** —— 等价于 Honor 2026 补丁
  "字典只预处理一次"的思路，而且更彻底。
- 集成补丁：`SukiSU_patch/other/zram/zram_patch/6.6/lz4kd.patch`（6.6 官方版）

## 落地内容
新增（内建，非模块）：
```
include/linux/lz4k.h  include/linux/lz4kd.h
lib/lz4k/{lz4k_encode.c,lz4k_decode.c,lz4k_private.h,lz4k_encode_private.h,Makefile}
lib/lz4kd/{lz4kd_encode.c,lz4kd_encode_delta.c,lz4kd_decode.c,lz4kd_decode_delta.c,
           lz4kd_private.h,lz4kd_encode_private.h,Makefile}
crypto/lz4k.c  crypto/lz4kd.c          # 注册 crypto 算法 "lz4k" / "lz4kd"
```
接线：`lib/Kconfig`(+LZ4K[KD]_COMPRESS/DECOMPRESS)、`lib/Makefile`、`crypto/Kconfig`(+CRYPTO_LZ4K/CRYPTO_LZ4KD)、
`crypto/Makefile`、`drivers/block/zram/Kconfig`(+DEF_COMP 选项)、`drivers/block/zram/zcomp.c`(backends[] 加 lz4k/lz4kd/deflate)

**刻意没有采用**（社区补丁里夹带的"黑科技"）：
- `kernel/module/main.c`：把 CRC 不匹配从失败改成通过（`bad_version: return 1`）→ 放弃 KMI 保证，**不抄**
- `kernel/module/main.c`：硬编码 `custom_module_blacklist[]`（lzo/lzo_rle/zram/zsmalloc/oplus_*）→ 拒绝加载 ROM 自己的模块，**不抄**
- `CONFIG_CRYPTO_DELTA` / `CRYPTO_ALG_EXT_PROP_DELTA` / `coa_compress_delta` —— OPLUS 对 crypto 层的私有扩展（mainline 无），未定义该 config 时 lz4kd 自动走**非 delta** 路径（安全、随机访问友好）

## 我们自己的两处定制
1. `CONFIG_ZRAM_HIDE_COMP_ALGORITHM`（新增 Kconfig 开关）
   - `zcomp.c: zcomp_available_show()` 直接 `return 0` → `comp_algorithm` / `recomp_algorithm` **读出来是空的**
   - `zram_drv.c: __comp_algorithm_store()` 对 **primary** 算法"接受但忽略"（返回成功，避免 ROM init 的 zram 建立流程中断），
     secondary/recomp 仍可写（保留 Android 空闲页重压缩能力）
   - 压缩照常：实际算法取自 `zram->comp_algs[]` ← `default_compressor` ← `CONFIG_ZRAM_DEF_COMP`；`backends[]` 与 `zcomp_create()` 校验未动
2. `zcomp.c: zcomp_create()` 增加 `pr_info("zcomp: using compressor '%s'")`
   - 列表隐藏后唯一的运行时验证手段（root 下 `dmesg | grep zcomp`）

## 生效配置
```
CONFIG_ZRAM=y                      # 内置（不再是模块）
CONFIG_ZSMALLOC=y                  # 由 select 自动提升为 y
CONFIG_ZRAM_DEF_COMP="lz4kd"       # CONFIG_ZRAM_DEF_COMP_LZ4KD=y
CONFIG_ZRAM_HIDE_COMP_ALGORITHM=y
CONFIG_CRYPTO_LZ4KD=y (→ LZ4KD_COMPRESS/DECOMPRESS=y)
CONFIG_ZRAM_WRITEBACK=y / CONFIG_ZRAM_MULTI_COMP=y
# CONFIG_LOCALVERSION_AUTO is not set   # 直接写进 gki_defconfig，版本串可复现
CONFIG_KSU=y / CONFIG_KSU_SUSFS=y       # 保留
```

## 回归验证（本轮）
| 项目 | 结果 |
|---|---|
| vermagic | 与 stock **完全一致** ✅ |
| 既有符号 CRC | 变化 **0** / 消失 **0** ✅（新增 18 个均为追加：zsmalloc 内建导出 6 个 + lz4kd 导出 7 个 + 其余 5 个）|
| Image 内容 | `zram` 字符串 35 个、`lz4kd` 32 个（旧版均为 0，证明 zram/lz4kd 已进内核镜像）|
| boot.img | v4/4096 页、内核区 sha256 一致、AVB 已清 |

## 刷机后怎么验证
```bash
adb shell 'cat /sys/block/zram0/comp_algorithm'      # 期望：空
adb shell 'cat /sys/block/zram0/recomp_algorithm'    # 期望：空（或 "#1: " 后为空）
adb shell 'cat /sys/block/zram0/mm_stat'             # 期望：9 个数字（压缩仍在工作）
adb shell 'cat /sys/block/zram0/disksize'            # 期望：16G 级别
adb shell cat /proc/swaps                            # zram0 仍是 swap
adb shell uname -r                                   # 仍必须是 6.6.118-android15-8-gc4127a25dcf3-ab15863337-4k
adb shell su -c 'dmesg | grep -E "zcomp: using compressor|comp_algorithm write ignored"'
#   → 期望看到 zcomp: using compressor 'lz4kd'
adb shell 'cat /proc/modules | wc -l'                # 会比之前少（zram/zsmalloc 变内建，ROM 的 zram.ko 会加载失败，属预期）
```
注意：`CONFIG_ZRAM=y` 后 ROM 里 vendor_dlkm 的 `zram.ko`/`zsmalloc.ko` 会加载失败（驱动已内建）——这是"内建"的固有结果，
与本项目**没有**用黑名单挡它。若想日志干净，可后续把这两个 .ko 从 vendor_dlkm 镜像里删掉。

---

# 第四部分：卡 logo 事故的根因与修复（已上机验证）

## 现象
候选 #1（zram 内建 + LZ4KD + 隐藏算法列表，无模块处理）刷入后**卡在开机 logo**。

## 根因（设备 dmesg 实证）
ROM 的 vendor_dlkm 里仍留有 `zsmalloc.ko` / `zram.ko`，而这两个驱动已内建，于是 ROM 在**两个阶段**各尝试加载一次：
```
[    0.460153] [GKI] zsmalloc: driver is built-in, faking successful load   ← 首阶段 init
[    0.569108] [GKI] zram:     driver is built-in, faking successful load
[    1.604227] [GKI] zsmalloc: driver is built-in, faking successful load   ← 第二阶段
[    1.619030] [GKI] zram:     driver is built-in, faking successful load
```
修复前这两次 `insmod` 是**失败**的，HyperOS 的 init 对失败敏感 → 启动中断 → 卡 logo。

## 修复：内建同名残留模块"假装加载成功"
`kernel/module/main.c`，在 `load_module()` 里 `early_mod_check()` 之前：
```c
static const char * const builtin_duplicate_modules[] = {
#if IS_BUILTIN(CONFIG_ZRAM)       "zram",
#endif
#if IS_BUILTIN(CONFIG_ZSMALLOC)  "zsmalloc",
#endif
#if IS_BUILTIN(CONFIG_CRYPTO_LZO) "lzo", "lzo_rle",
#endif
};
...
if (is_builtin_duplicate_module(info->name)) {
        pr_info("[GKI] %s: driver is built-in, faking successful load\n", info->name);
        err = 0;          /* 返回成功但不加载 */
        goto free_copy;
}
```
设计要点：
- **只对"同名且已内建"的模块生效**；厂商自有模块（如小米内存扩展）不受影响
- 返回**成功**而不是像社区版那样只"拒绝加载"（拒绝仍然是 insmod 失败，无法覆盖"失败即卡启动"的 ROM）
- 驱动已内建 → `/sys/module/<name>` 等状态一致，假装成功不会造成状态不一致
- 打日志便于定位（本轮就是靠它确认的）

## 上机验证结果（候选 #2 = boot-c2-ksu-susfs-lz4kd-builtin.img）
| 项目 | 结果 |
|---|---|
| `uname -r` | `6.6.118-android15-8-gc4127a25dcf3-ab15863337-4k`（与 stock 一致）|
| `comp_algorithm` / `recomp_algorithm` | **空（0 字节）** |
| `mm_stat` | 有数据、持续变化；实测压缩率 ≈ **3.12×** |
| `dmesg` | `zcomp: using compressor 'lz4kd'` |
| `/proc/modules` | 604 → **602**（zram/zsmalloc 变内建）|
| vermagic / 既有符号 CRC | 完全一致 / 变化 0 消失 0 |

## 可选的进一步收尾
把 `zram.ko`/`zsmalloc.ko`（及内建的 `lzo.ko`/`lzo_rle.ko`）从 `vendor_dlkm.img` 里删掉，
这样连那 4 行 "[GKI] faking successful load" 日志都不会出现（纯日志层面的整洁，
不影响功能）。需要 dump vendor_dlkm → `mkfs.erofs` 重打 → 刷入（`~/gki-kernel/kbt/bin` 里工具齐全）。

---

# 第五部分：方案 C 阶段 S1+S2 —— zswap(zsmalloc) + lz4kd(acomp) + 内存压力 shrinker

产物：`~/gki-kernel/boot-cZ12-zswap-lz4kd.img`（Image: `~/gki-kernel/Image-cZ12-zswap-lz4kd`）

## 做了什么
- **(A) lz4kd 补 scomp/acomp 前端**：`crypto/lz4kd.c` 在原 comp 算法（"lz4kd"/"lz4kd-generic"，
  zram 继续走 `crypto_alloc_comp()`）之外，再用 `crypto_register_scomp()` 注册同一份编解码函数为
  **"lz4kd"/"lz4kd-scomp"**（scomp 核心自动包成 acomp，供 zswap 的 `crypto_alloc_acomp("lz4kd")` 使用）。
  与 `crypto/lz4.c` 完全同构；没有新增 EXPORT_SYMBOL。`crypto/Kconfig` 的 `CRYPTO_LZ4KD` 增加
  `select CRYPTO_ACOMP2`。
- **(B) 打开 zswap**：`gki_defconfig` 加 `CONFIG_ZSWAP=y`、`ZSWAP_DEFAULT_ON=y`、
  `ZSWAP_COMPRESSOR_DEFAULT_LZ4KD=y`（mm/Kconfig 新增该 choice 项 + `default "lz4kd"`）、
  `ZSWAP_ZPOOL_DEFAULT_ZSMALLOC=y`；ZBUD/Z3FOLD 关闭；`GKI_ROOT_ZSWAP_MEMCG_ACCOUNTING=n`。
  `mm/zswap.c` 参数默认值 `max_pool_percent` 20→25、`accept_threshold_percent` 90→100。
- **(C) 内存压力 shrinker**（`mm/zswap.c`，全 static，用本树 6.6 旧 API）：
  `zswap_shrinker_count()` 返回 LRU 上可回收页数（stored - same_filled）；
  `zswap_shrinker_scan()` 取 current pool kref 后按 `sc->nr_to_scan` 限额循环调用现有
  `zswap_reclaim_entry()`，返回实际回收页数。`register_shrinker(&zswap_shrinker, "zswap")`
  在 `zswap_setup()` 里 pool/workqueue 之后注册；失败路径注销。未引入 list_lru /
  `CONFIG_ZSWAP_SHRINKER_DEFAULT_ON`，未改 `include/linux/shrinker.h`，未动 mm/swapfile.c。

## 回归验证（本轮）
| 项目 | 结果 |
|---|---|
| vermagic | `6.6.118-android15-8-gc4127a25dcf3-ab15863337-4k SMP preempt mod_unload modversions aarch64` 与 stock 完全一致 ✅ |
| 导出符号 CRC | 基线 16555 → changed **0** / removed **0** / added 21（全是 lz4kd/zpool/zsmalloc，追加）✅ |
| 关键字符串 | Image 内 zswap(75)、zsmalloc、lz4kd(42 含 `lz4kd-scomp`、`zswap_shrinker_*`) ✅ |
| boot.img | v4/4096、内核区 sha256 一致、AVB 已清 |

## 上机只读验证
```bash
adb shell uname -r                                        # 必须与 stock 一致
adb shell 'cat /sys/module/zswap/parameters/enabled'       # Y
adb shell 'cat /sys/module/zswap/parameters/compressor'    # lz4kd
adb shell 'cat /sys/module/zswap/parameters/zpool'         # zsmalloc
adb shell 'cat /sys/module/zswap/parameters/max_pool_percent'        # 25
adb shell 'cat /sys/module/zswap/parameters/accept_threshold_percent' # 100
adb shell su -c 'dmesg | grep -iE "zswap|lz4kd-scomp"'
#   → 期望: "zswap: loaded using pool lz4kd/zsmalloc"；若报 compressor not available 则 scomp 注册失败
adb shell 'cat /sys/kernel/debug/zswap/stored_pages'
adb shell 'cat /sys/kernel/debug/zswap/pool_total_size'
adb shell 'cat /proc/meminfo | grep -i -E "swap|zswap"'
adb shell 'cat /sys/block/zram0/mm_stat'                   # zram 仍工作
adb shell su -c 'grep zswap /proc/slabinfo'
```
