# 新旧内核功能对照表（维护用）

| | 老项目 | 新项目 |
| --- | --- | --- |
| 仓库 | `ReSukiSU-Ultra-Kernel` | `gki-2.0-generic-kernel`（本仓库） |
| 基线 | ACK `android15-6.6` 两个分支：`2015-03`(6.6.77) / `2026-01`(6.6.118)，repo manifest | ACK `android15-6.6` tip 单一 commit `448c3033`(6.6.142) + `patches/` 83 个补丁 → **6.6.158** |
| 构建 | kleaf/bazel（`--config=fast --lto=thin --defconfig_fragment`），产物 dist（含模块） | plain make + AOSP clang-r510928 + AutoFDO（与 `scripts/build.sh` 一致），产物 `Image` |
| 集成入口 | `build.py`（10 步）+ `patches.py` + `config.yaml` 开关 + `build.yml` | `scripts/ci-integrate.sh`（7 个 stage）+ `.github/workflows/build.yml` |
| 打包 | AnyKernel3 + 管理器 APK → `kernel-latest` Release | 同（AnyKernel3 已迁移），另附裸 `Image` 与 `build-info.txt` |

状态图例：✅ 已迁移 · ➖ 基线/上游已内置（无需迁移）· ❌ 未迁移 · ⛔ 不适用（构建体系不同）

## 1. Root / 隐藏（核心）

| 功能 | 老项目实现 | 新项目实现 | 状态 |
| --- | --- | --- | --- |
| ReSukiSU-Ultra (KernelSU) | `build.py step05c` + `third_party/ksu/setup-local.sh`（drivers/kernelsu 软链 + Makefile/Kconfig） | `ci-integrate.sh stage_ksu()`：同样软链 + `obj-$(CONFIG_KSU)`，走 KSU 仓库 `kernel/Kbuild` 内建 | ✅ |
| fusebpf 内核侧补丁 | `patches.py apply_fusebpf()`（优先 KSU `kernel-patches/fusebpf`，回退 `third_party/fusebpf`） | `stage_fusebpf()` + `third_party/fusebpf/`（与 KSU 仓库逐字节一致），并校验符号 | ✅ |
| SUSFS | `build.py step05e`（gitlab 上游 50_add_susfs + 源码拷贝 + 6.6 上下文修复） | `stage_susfs()`（同源同流程，含 `dma-buf.h`/`susfs_def.h` 修复与 sucompat 硬校验） | ✅ |
| NoMount | `patches.py apply_nomount()`（hook 补丁 + `nomount.c/h`） | `stage_nomount()` + `third_party/nomount/`（含 `fs/Makefile`、`fs/Kconfig` 兜底修复） | ✅ |
| 管理器 APK 发布 | `.github/workflows/get-manager.yml` | 同名工作流迁移 | ✅ |
| 管理器签名（`manager_sign.h`/`apk_sign.c`） | `build.py step07` 注入 `RESUKISU_ULTRA` 签名 | ReSukiSU 仓库已内置 `RESUKISU_ULTRA`（pengzenzen-creator）与 `RESUKISU_ULTRA_CUSTOM`（WGecy release-key） | ➖ |
| KSU seccomp `PF_EXITING` 防死机（6.6.118+） | `build.py step05d`（改 `KERNEL_VERSION(6,11,0)`） | ReSukiSU `policy/app_profile.c` 已自带 `>= 6.6.118` 版本分支 | ➖ |

## 2. 安全修复

| 功能 | 老项目实现 | 新项目实现 | 状态 |
| --- | --- | --- | --- |
| CVE-2026-43499 / CVE-2026-53163（rtmutex `remove_waiter()`） | `third_party/security_patch/apply_cve_2026_43499.sh`（补丁链 + scoped_guard 回补） | 基线已含修复：`remove_waiter()` 使用 `waiter_task` + `!waiter_task` 守卫 + `scoped_guard`，`include/linux/cleanup.h` 已有 `scoped_guard` | ➖ |
| extract-cert PKCS11/OpenSSL3 | `third_party/kernel_patches` / `patches/09-android/extract-cert-fix.patch` | `patches/0001`（vermagic/CRC 绕过 + extract-cert OpenSSL3 修复） | ➖ |
| vermagic / 符号 CRC 绕过（vendor 模块可加载） | 无（老项目依赖基线 KMI 冻结） | `patches/0001` | ✅ 新项目独有 |

## 3. IO / 存储

| 功能 | 老项目实现 | 新项目实现 | 状态 |
| --- | --- | --- | --- |
| ADIOS IO 调度器 + 强制默认 | `patches/04-block-io/14-adios.patch` + `build.py step06b`（defconfig）+ `build.py step07`/`build.yml` 的 `elevator.c` 拦截 | `third_party/adios/14-adios.patch` + `stage_adios()`（应用补丁 + `elevator_get_default()` 注入 + `CONFIG_MQ_IOSCHED_ADIOS=y` / `CONFIG_MQ_IOSCHED_DEFAULT_ADIOS=y`） | ✅ 2026-09-22 迁移 |
| └ ADIOS **运行时禁止切换调度器**（"防 init.qti 切 cpq"） | 老项目仅 `fastbuild.yml` 有（锚点是 5.x 风格，6.6 命中不了）；`build.py` 896 行注明「elevator_switch: 拦截已禁用（2026-08-18，管理器 IO 调度器切换功能需要自由切换）」 | `inject_adios_lock()`：在 6.6 的 `elevator_change()` 内注入拦截；`--adios-lock=cpq`（默认）/`all`/`off`，工作流输入 `adios_lock` | ✅ 2026-09-22 迁移（默认只拦 cpq） |
| SSG IO 调度器（三星） | `patches/04-block-io/15-ssg.patch` + `CONFIG_MQ_IOSCHED_SSG=y` | — | ❌ |
| UFS fastdiscard | `patches/04-block-io/07-ufs-fastdiscard.patch` | — | ❌ |
| zstd 1.5.7（压缩级别可调） | `patches/04-block-io/zstd-1.5.7.patch` | — | ❌ |
| `nr_requests` 默认 256 | `build.py step07`（`blk-mq.h` `BLKDEV_DEFAULT_RQ` 128→256） | — | ❌ |
| zram 内建 + LZ4/LZ4K/LZ4KD 算法栈（默认 lz4kd） | `patches.py apply_zram_lz4kd()` + `third_party/zram-stack/` + `build.py step06b` | 新内核 `CONFIG_ZRAM=m` 且只出 `Image`（不打包模块）→ 实际无 zram | ❌（体感最明显） |

## 4. 网络

| 功能 | 老项目实现 | 新项目实现 | 状态 |
| --- | --- | --- | --- |
| BBRv3（17 算法全开 + 默认 bbr3） | `patches/05-net/06-bbrv3.patch` + defconfig | 仅上游 `CONFIG_TCP_CONG_BBR=y` | ❌ |
| ipset 全家桶（代理分流/防火墙） | `patches.py apply_ipset()`（`CONFIG_IP_SET*` + `NETFILTER_XT_SET`） | — | ❌ |
| KSU 网络隔离 | 老项目无 | `CONFIG_KSU_NETISOLATE=y`（ReSukiSU 自带） | ✅ 新项目独有 |

## 5. 内存 / 性能 / 温控

| 功能 | 老项目实现 | 新项目实现 | 状态 |
| --- | --- | --- | --- |
| mTHP 多尺寸大页 | `patches/03-mm/08-mthp.patch` | — | ❌ |
| MGLRU 导出 + 强制全开（FORCE3，拒绝被关） | `patches/03-mm/16-lru-gen-export.patch` + `build.py step07`（`vmscan.c` caps=3 / 拒绝关闭） | `CONFIG_LRU_GEN=y` + `CONFIG_LRU_GEN_ENABLED=y`（上游已开），缺强制注入 | 部分 ❌ |
| UKSM 内存去重 | `patches/03-mm/uksm`（老项目 `features.uksm: false`，与 ART GC 冲突） | — | ⛔（老项目亦禁用） |
| 性能参数调优（mq-deadline 超时/compact/oom） | `patches/06-tune/performance-tune.patch` | — | ❌ |
| VM 默认值（watermark=30/swappiness=100）+ `tesla_vm_opt` | `patches/06-tune/vm-defaults.patch` + `third_party/vm-opt/tesla_vm_opt.c`（`build.py step07` 注入 mm/） | — | ❌ |
| 温控偏移（游戏防降频，默认 3°C） | `patches/08-thermal/thermal-offset.patch` | — | ❌ |
| cpuidle/cpufreq 优化 | `patches/07-drivers/09-cpuidle.patch` | — | ❌ |
| Unicode 零宽字符绕过 | `patches/09-android/unicode_bypass_fix_6.1+.patch`（`patches.py apply_unicode_bypass`） | `third_party/unicode_bypass/unicode_bypass_fix_6.1+.patch` + `stage_unicode_bypass()`（改 `fs/unicode` 归一化数据表 + 校验 `utf8data[64080]`） | ✅ 2026-09-22 迁移 |
| BBG 防格机 | `third_party/kernel_patches/common/bbg`（老项目 `features.bbg: false`） | — | ⛔（老项目亦关闭） |

## 6. OEM / vendor 兼容（按机型，非通用功能）

| 功能 | 老项目实现 | 新项目实现 | 状态 |
| --- | --- | --- | --- |
| 三星 KDP（`kdp_*` 符号 + `min_kdp` 驱动） | `build.py step05b` + `third_party/kernel_patches/samsung/min_kdp/` | — | ❌（当前机型不需要；换机再补） |
| 小米 `device_find_any_child` / ABI 符号表（galaxy/xiaomi/oplus） | `build.py step05b` + `_merge_abi_union()` | — | ❌（同上） |
| 固件搜索路径（`/vendor/firmware_mnt/image` 等） | `build.py step07` | — | ❌（设备相关；新内核已在 SM8750/HyperOS 实测开机） |

## 7. 构建 / 打包体系（不同实现，非功能缺失）

| 老项目 | 新项目 | 状态 |
| --- | --- | --- |
| `testkey_rsa2048.pem` 签名密钥、mkbootimg 工具链（`build.py step01/step03`） | plain make 不需要；刷机由 AnyKernel3 处理 vbmeta | ⛔ |
| protected exports / `kmi_symbol_list_strict_mode` / `MODULES_ORDER` / `BUILD_SYSTEM_DLKM=0` / `modules.bzl` protected modules | kleaf/KMI 概念，plain make 不存在 | ⛔ |
| ABI 并集、LTS 合并（`build.py step04.6`）、ACK tag 自动升级（`step04.5`） | 精确 commit 锁定基线（`data/android15/6.6.json`），无这些步骤 | ⛔ |
| `setlocalversion` 去 `-dirty` | `LOCALVERSION=` + `LOCALVERSION_AUTO=n`（`patches/0002`）已保证版本串干净 | ✅ |
| 构建时间戳（`init/Makefile` 注入） | `KBUILD_BUILD_TIMESTAMP`（`build_time` 输入） | ✅ |
| 自定义内核名（`android15-8-gHASH-abBID`） | `custom_suffix` 输入 → `LOCALVERSION` | ✅ |
| `fastbuild.yml`（make + ccache-ECS 快速构建） | 未迁移（主流程走 Actions；工具链有 Actions 缓存） | ❌（可选） |
| 两个基线 6.6.77 / 6.6.118 | 单基线 6.6.158 | 差异（非缺失） |

## 8. 老仓库中未被 CI 使用的资产（不需要迁移）

`susfs_fix_patches/`、`wild/*`、`mksu`、`sultan`、`pershoot`、`droidspaces`、`ntsync`、
`vendor_modules`、`oneplus/hmbird`、`oneplus/module_overlay`、`ccache-ecs`、
`ksu-modules/boot-tune.sh`，以及 `susfs4ksu` 的用户态工具（`ksu_susfs`、`ksu_module_susfs`）——
老 CI 也从未构建它们。

## 9. 如何补一个未迁移功能（维护步骤）

1. **放资产**：补丁放 `third_party/<feature>/`（老项目路径记到 `third_party/MIGRATED-FROM.md`）。
2. **加 stage**：在 `scripts/ci-integrate.sh` 复制一个 `stage_xxx()`：`apply_patch_file` 应用 +
   `verify_marker` 校验关键落点；在“执行”区按顺序调用；加 `--no-xxx` 开关与帮助文本。
3. **defconfig**：在 `stage_defconfig()` 用 `enable_config` / `disable_config` 写入开关
   （关闭时必须显式写 `# CONFIG_X is not set`，对抗 `default y`）。
4. **构建校验**：必要时在 `.github/workflows/build.yml` 的“生成 defconfig”步骤加
   “配置 ⇔ 补丁”一致性检查，把失败提前。
5. **文档**：更新本表状态、`README.md` 的文件清单、`scripts/README-ci.md` 的 stage 列表。
6. **本地验证**（无需 Linux 编译）：用假内核树 + 真实 `git apply`/`patch` 跑
   `bash scripts/ci-integrate.sh --gki-root <fake> --workspace <repo>`，覆盖
   “全新应用 / 幂等重跑 / `--no-xxx`”三条路径。

## 10. 已知基线相关注意事项

- 老项目补丁多数针对 **6.6.77 / 6.6.118 / 6.6.142** 生成，迁到 6.6.158 必须逐个验证；
  已验证可干净应用：`adios`、`unicode_bypass`、`fusebpf`、`nomount`、SUSFS 上游补丁。
- 新内核为**单片且不打包模块**：`=m` 的功能（如 `CONFIG_ZRAM=m`）实际不可用，
  迁移这类功能时要同时把配置改成 `=y`（或在 AK3 包内附带模块）。
- 换基线（改 `data/android15/6.6.json` 的 `baseline_commit`）时，`patches/` 与
  `third_party/*` 补丁都需要重新验证。

## 11. ADIOS 被切成 cpq 的真实原因（真机排查记录，2026-09-22）

**现象**：澎湃OS4（Android 17，机型 24122RKC7C / sun）每次重启后 `sda`（userdata）的调度器都是
`cpq`；澎湃OS3（Android 16）正常。内核本身没问题（`adios` 已内建，`sdb~sdf` 都是 `[adios]`）。

**根因**：ROM 主动切的，且是 persist 属性门控、每次开机都执行：

```
/vendor/etc/init/hw/init.qti.kernel.rc
on boot && property:persist.sys.stability.smartfocusio.v1=on
    write /sys/block/${dev.mnt.rootdisk.data}/queue/scheduler cpq     # ← 就是这里 (rootdisk.data = sda)
    mkdir /dev/blkio/{vip,hipri,lowpri,limit} ...
    write /dev/blkio/vip/blkio.cpq.level 0 ...
on property:persist.sys.stability.smartfocusio.v1=off
    write /sys/block/${dev.mnt.rootdisk.data}/queue/scheduler mq-deadline
```

- `persist.sys.stability.smartfocusio.v1 = on`（实测；`v3=on` 还让 `/proc/mikblockd_enable=1`）→ persist 属性，**每次开机触发**；
- 全系统只有这一个 rc 写调度器；`cpq` 是厂商模块（`cpq 36864 1`，被 `xr_qi`/`vip_sched`/`perf_actuator` 依赖），dmesg `[0.548920] io scheduler cpq registered`；
- 调度器有"两段"：队列建立时的默认值（`elevator_init_mq()` → `elevator_get_default()`，我们控制）与运行时切换（`elv_iosched_store()` → `elevator_change()`，需要拦截）。6.6 内核**没有** `elevator_set_default()` 之类接口，所以"默认被改成 cpq"只能是这种 sysfs 写入。

**处理**：`--adios-lock=cpq`（默认）在 `elevator_change()` 中拒绝切到 `cpq`（`pr_info_once` 打日志后 `return 0`），
其余调度器仍可自由切换；工作流输入 `adios_lock` 可选 `cpq`/`all`/`off`。

**刷机后验证**：

```bash
cat /sys/block/sda/queue/scheduler          # 期望 [adios]
dmesg | grep -i 'ADIOS locked'              # 期望 elevator: blocked scheduler switch to cpq (ADIOS locked)
```

**代价**：小米 smartfocusio 的调度器侧（cpq + `/dev/blkio/*/blkio.cpq.level`）不再生效（相关写入变成空转）；
如需保留 cpq，把 `adios_lock` 设为 `off` 即可。
