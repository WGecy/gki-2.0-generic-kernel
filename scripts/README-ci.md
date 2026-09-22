# GitHub Actions 构建说明（ReSukiSU-Ultra + SUSFS + NoMount + ADIOS + Unicode 绕过）

本目录里的 `ci-integrate.sh` 与 `.github/workflows/` 一起，把 **ReSukiSU-Ultra（KernelSU）
+ SUSFS + NoMount + ADIOS IO 调度器 + Unicode 零宽字符绕过** 集成到本内核
（GKI 2.0 / android15-6.6，基线 `6.6.158`）上。
工作流结构迁移自老内核项目 `ReSukiSU-Ultra-Kernel`：

| 老项目 | 本项目 | 作用 |
| --- | --- | --- |
| `kernel-android15-6-6.yml` | `.github/workflows/kernel-android15-6-6.yml` | 入口：读版本矩阵 → 调构建 → 拉管理器 APK → 合并发布 |
| `build.yml` | `.github/workflows/build.yml` | 可复用构建流程（拉源码/补丁/集成/编译/打包） |
| `get-manager.yml` | `.github/workflows/get-manager.yml` | 拉取 ReSukiSU-Ultra 管理器 APK |
| — | `data/android15/6.6.json` | 版本矩阵（含 ACK 基线 commit） |
| `patches.py` + `build.py` 的集成步骤 | `scripts/ci-integrate.sh` | KSU/fusebpf/SUSFS/NoMount/ADIOS/Unicode 集成（可在本地直接跑） |
| `third_party/AnyKernel3`、`nomount`、`fusebpf`、`adios`、`unicode_bypass` | 同路径 | 打包模板与各功能补丁资产 |

迁移进度与「还缺什么、怎么补」见 [`docs/feature-diff.md`](../docs/feature-diff.md)；
目前仍未迁移的主要是 BBRv3 / ipset / zram-lz4kd / mTHP / 各类性能温控调优 / OEM vendor 兼容。

## 触发与输入

`Actions → GKI 2.0 内核构建 - Android 15 (6.6) → Run workflow`

| 输入 | 默认 | 说明 |
| --- | --- | --- |
| `version` | `all` | 版本过滤，选项 `all` / `6.6.158`（对应 `data/android15/6.6.json` 的 `sub_level`） |
| `ksu_repo` | `https://github.com/WGecy/ReSukiSU-Ultra` | KernelSU 仓库 |
| `ksu_branch` | `main` | KernelSU 分支/标签 |
| `susfs_branch` | `gki-android15-6.6` | SUSFS 分支（gitlab `simonpunk/susfs4ksu`） |
| `adios_lock` | `cpq` | ADIOS 调度器锁定：`cpq`=只拒绝切到 cpq（澎湃OS4 的 init.qti 会写 cpq）/ `all`=只允许 adios / `off`=不拦 |
| `custom_suffix` | 空 | 追加到版本串，如 `-test-01` → `6.6.158-test-01`；留空即项目默认 `6.6.158` |
| `build_time` | `N` | `N`/留空 = 当前 UTC，否则写入 `KBUILD_BUILD_TIMESTAMP` |

产物（发布到 `kernel-latest` Release，同时作为 Actions artifact 上传）：

- `android15-6.6.158-2026-09-AnyKernel3.zip`（AnyKernel3 刷机包）
- `Image-6.6.158`（裸 Image，配合 `scripts/pack-boot.sh` 可自行重打包 boot.img）
- `build-info.txt`（基线 commit / KSU 与 SUSFS commit / NoMount sha256 / 构建编号）
- `ReSukiSU-Ultra-universal.apk`（管理器，来自 get-manager 任务）

## 构建流程（build.yml）

1. **环境**：free-disk-space 清盘；`apt` 装 `build-essential bc bison flex libelf-dev
   libssl-dev zlib1g-dev python3 zip unzip cpio rsync patch jq`。
2. **拉基线**：`git init` + `git fetch --depth 1 origin <baseline_commit>`（失败则用
   快照日期附近的 `android15-6.6` 浅历史兜底），随后校验 `HEAD == baseline_commit`。
3. **打补丁**：`git am patches/*.patch`（83 个；基线换 commit 必须重新生成补丁）。
4. **工具链**：`prebuilts/clang/host/linux-x86` 稀疏拉取 `clang-r510928`；
   `kernel/prebuilts/build-tools` 稀疏拉取 `linux-x86/{bin,lib64}`（pahole/lz4/dtc）；
   写入 `PATH`/`LD_LIBRARY_PATH`/`CLANG_AUTOFDO_PROFILE`（AutoFDO profile 必须绝对路径）。
5. **集成**：`bash scripts/ci-integrate.sh --gki-root "$GKI_ROOT" --workspace "$GITHUB_WORKSPACE" ...`
6. **配置 + 编译**：`make O=out ARCH=arm64 LLVM=1 LOCALVERSION=<suffix>
   KCFLAGS=-D__ANDROID_COMMON_KERNEL__ gki_defconfig` 然后 `... -j$(nproc) Image`
   （单片内核 + LTO thin + AutoFDO，与 `scripts/build.sh` 一致）。
7. **校验**：`kernel.release` / Image 版本串 / `vmlinux` 中 `kernelsu_init`、
   `susfs is initialized`、`nm_rules` 三项内建标记。
8. **打包**：AnyKernel3 目录内放入 `Image` 后 zip。

## ci-integrate.sh 做了什么

在 `$GKI_ROOT/common`（已 `git am` 补丁的内核树）上按顺序执行：

1. **KernelSU（ReSukiSU-Ultra）**
   - `git clone --depth 1 -b <branch> <repo> $GKI_ROOT/KernelSU`
   - `common/drivers/kernelsu` → `KernelSU/kernel` 软链接（已验证该仓库存在 `kernel/Kbuild`，
     kbuild 优先读它，因此可以按 `CONFIG_KSU=y` 内建，而不是 LKM 用的 `kernel/Makefile`）
   - `drivers/Makefile` 追加 `obj-$(CONFIG_KSU) += kernelsu/`；`drivers/Kconfig` source 其 Kconfig
2. **fusebpf（KSU 内核侧补丁，必需）**
   - 优先用 KSU 仓库自带的 `kernel-patches/fusebpf/*.patch`，缺失时回退到
     `third_party/fusebpf/`（与 KSU 仓库副本逐字节一致）
   - 两个补丁给内核 `fs/fuse/{backing.c,dir.c,fuse_i.h}` 加上
     `fuse_bpf_lookup_revalidate_enabled` / `fuse_bpf_lookup_revalidate_set`
   - **为什么必需**：ReSukiSU 的 `CONFIG_KSU_FUSEBPF_FIX` 是 `default y`，其
     `fusebpf_feature_get/set/fix_set` 与 `ksu_handle_susfs_cmd` 直接引用上面两个符号；
     漏掉补丁/配置不匹配时不会在编译期报错，而是在 **链接 vmlinux 时报 undefined symbol**
     （2026-09-22 run 35693420939 的失败原因）。所以脚本会校验符号，工作流也会在
     defconfig 之后做「`KSU_FUSEBPF_FIX=y` ⇔ 内核侧符号存在」的一致性检查
   - 如确实不想用：`--no-fusebpf`（脚本会显式写 `# CONFIG_KSU_FUSEBPF_FIX is not set`）
3. **SUSFS**（gitlab 上游，自动跟随最新）
   - 克隆 `susfs4ksu` 对应分支，复制 `50_add_susfs_in_gki-android15-6.6.patch` 与
     `kernel_patches/{fs,include/linux}/*`（`susfs.c`、`susfs.h`、`susfs_def.h`）
   - `git apply` → 失败退回 `patch -p1 -F3 -N --batch`（NoMount 与 SUSFS 都要往
     `fs/Makefile` 同一处插一行，模糊匹配是必要的）
   - 6.6 上下文修复（`fs/proc/base.c` 的 `dma-buf.h` 锚点、`susfs_def.h` 补齐）
   - **硬校验**：`fs/exec.c` 的 `ksu_handle_execveat`、`fs/stat.c` 的 `ksu_handle_stat`
     （sucompat 依赖，缺失即失败）
4. **NoMount**（本仓库 `third_party/nomount`，老项目同名资产迁移而来）
   - 应用 `nomount-6.6.patch`（namei/d_path/readdir/stat/statfs/task_mmu/Kconfig/Makefile）
   - 复制 `nomount.c` → `fs/nomount.c`、`nomount.h` → `fs/nomount.h` + `include/linux/nomount.h`
   - 兜底修复 `fs/Makefile` 的 `obj-$(CONFIG_NOMOUNT) += nomount.o` 与 `fs/Kconfig`
     的 `config NOMOUNT`，然后逐项校验所有 hook 落点
5. **ADIOS IO 调度器**（本仓库 `third_party/adios`，迁移自老项目 `features.adios`）
   - 应用 `14-adios.patch`：新增 `block/adios.c`，并注册 `block/Kconfig.iosched`
     （`MQ_IOSCHED_ADIOS` / `MQ_IOSCHED_DEFAULT_ADIOS`）与 `block/Makefile`
   - 注入 `block/elevator.c` 的 `elevator_get_default()`：把硬编码的 `mq-deadline`
     兜底包成 `#ifdef CONFIG_MQ_IOSCHED_DEFAULT_ADIOS → return elevator_find_get(q, "adios")`
     （幂等：已注入则跳过；锚点找不到会明确失败）
   - **运行时切换拦截**（`--adios-lock`，默认 `cpq`）：在 `elevator_change()` 里拒绝把调度器切成 `cpq`。
     真机排查结论：澎湃OS4（Android 17）的 `/vendor/etc/init/hw/init.qti.kernel.rc` 在
     `on boot && property:persist.sys.stability.smartfocusio.v1=on` 时**每次开机**写
     `write /sys/block/${dev.mnt.rootdisk.data}/queue/scheduler cpq`（rootdisk.data=sda/userdata），
     所以只注入"默认值"挡不住；`all` = 只允许 adios，`off` = 不拦（恢复原行为）
   - defconfig：`CONFIG_MQ_IOSCHED_ADIOS=y` + `CONFIG_MQ_IOSCHED_DEFAULT_ADIOS=y`
     （后者 `depends on MQ_IOSCHED_ADIOS=y`，必须都是 y）；`--no-adios` 会显式关掉这两项
   - 刷机后验证：`cat /sys/block/sda/queue/scheduler` 期望 `[adios]`；
     `dmesg | grep 'ADIOS locked'` 期望出现 `elevator: blocked scheduler switch to cpq`
6. **Unicode 零宽字符绕过**（本仓库 `third_party/unicode_bypass`，迁移自 `features.unicode_bypass`）
   - 应用 `unicode_bypass_fix_6.1+.patch`：改 `fs/unicode/mkutf8data.c`（移除 `ignore_init`）
     与 `fs/unicode/utf8data.c_shipped`（归一化数据表 64256 → 64080 字节），
     使文件名归一化不再忽略零宽字符
   - 硬校验：`mkutf8data.c` 不再含 `ignore_init`，且 shipped 表为 `utf8data[64080]`
   - defconfig：确保 `CONFIG_UNICODE=y`；`--no-unicode` 可跳过
7. **defconfig**：`CONFIG_KSU=y`、`CONFIG_KSU_NETISOLATE=y`、`CONFIG_NOMOUNT=y`、
   `CONFIG_KSU_FUSEBPF_FIX=y`、`CONFIG_KSU_SUSFS*` 10 项、`CONFIG_MQ_IOSCHED_ADIOS=y`、
   `CONFIG_MQ_IOSCHED_DEFAULT_ADIOS=y`、`CONFIG_UNICODE=y`
   （已启用跳过 / `# ... is not set` 原位替换 / 不存在则追加）
8. **构建信息**：`$GKI_ROOT/ci-build-info.env`（KSU/SUSFS commit、fusebpf/NoMount/ADIOS/
   Unicode 状态、NoMount sha256），供 release notes 使用。

脚本幂等：重复执行只更新 KernelSU/SUSFS 源码，已应用的补丁自动跳过（`Reversed`）。
结束时若存在 `.rej` 会打印并失败（确认无碍可加 `--allow-rej`）；补丁调用带
`--no-backup-if-mismatch`，不会在树里留下 `.orig` 备份。

配置侧的两个前提（当前基线已满足，SUSFS 补丁自身会处理）：

- `CONFIG_KALLSYMS_ALL=y`（基线 gki_defconfig 已开）——KernelSU 需要 `write_op`、
  `sel_handle_status_ops`、`security_dump_masked_av` 等符号可见；
- KernelSU 钩子方式走 ReSukiSU Kconfig choice 的默认值 `KSU_TRACEPOINT_HOOK`
  （GKI2 的 syscall tracepoint 方案），SUSFS 那批 `CONFIG_KSU_SUSFS` 钩子由
  `CONFIG_KSU_SUSFS=y` 打开。

## 本地复现（Linux）

在能编译本内核的 Linux 环境里，可以用同一套脚本先把集成跑到内核树上：

```bash
# 1) 准备内核树: 基线 + 83 个补丁 (与 CI 相同)
export GKI_ROOT=$HOME/gki-kernel
git clone https://android.googlesource.com/kernel/common "$GKI_ROOT/common"
git -C "$GKI_ROOT/common" checkout 448c303366032107c46d39006c8127a5ca967a26
git -C "$GKI_ROOT/common" am "$PWD"/patches/*.patch

# 2) 集成 ReSukiSU-Ultra + SUSFS + NoMount
bash scripts/ci-integrate.sh --gki-root "$GKI_ROOT" --workspace "$PWD"

# 3) 编译 (与 scripts/build.sh 相同的工具链/参数)
. scripts/env.sh
cd "$GKI_ROOT/common"
make O=out ARCH=arm64 LLVM=1 LOCALVERSION= \
     KCFLAGS=-D__ANDROID_COMMON_KERNEL__ \
     HOSTCFLAGS="-I$GKI_ROOT/hosttools/root/usr/include" gki_defconfig
make O=out ARCH=arm64 LLVM=1 LOCALVERSION= \
     KCFLAGS=-D__ANDROID_COMMON_KERNEL__ \
     HOSTCFLAGS="-I$GKI_ROOT/hosttools/root/usr/include" \
     CLANG_AUTOFDO_PROFILE="$GKI_ROOT/common/android/gki/aarch64/afdo/kernel.afdo" \
     -j8 Image
```

常用开关：`--no-susfs`、`--no-nomount`、`--allow-rej`、`--ksu-branch <tag>`、
`--susfs-branch <branch>`、`--android-version android15`、`--kernel-version 6.6`；
`bash scripts/ci-integrate.sh --help` 可看全部参数。

## 打包模板说明

`third_party/AnyKernel3/` 是从老项目原样迁移的 AnyKernel3 模板（`do.devicecheck=0`，
只做 GKI 6.6 校验后替换 boot 内核）。其中的 `anykernel.sh` 仍保留模板上游的
“Wild Kernels” 提示文案（仅 `kernel.string` 与 `ui_print` 文本，不影响功能）；
要改成自己的品牌，直接编辑 `third_party/AnyKernel3/anykernel.sh` 即可。

## 换基线时要做的事

1. 更新 `data/android15/6.6.json` 的 `baseline_commit` / `snapshot` / `sub_level`；
2. **用新基线重新生成 `patches/`**（`git am` 是按 commit 生成的补丁，换基线必然冲突；
   CI 会在 `baseline_commit` 不一致或 `git am` 失败时明确报错）；
3. 如果 ACK 基线的 `gki_defconfig` 结构变化，`ci-integrate.sh` 的配置注入仍是幂等的，
   但请留意 SUSFS 上游补丁的 hunk 偏移（脚本会打印 `offset/fuzz`，出现 `.rej` 会失败）。

## 已知风险点

- **SUSFS 上游是移动目标**：`50_add_susfs_in_gki-android15-6.6.patch` 由 simonpunk 维护，
  其 hunk 上下文与 ACK 版本相关。脚本已用 `-F3` + 落点校验兜住小幅漂移；若上游大改，
  会以“hunk FAILED / 缺少 hook”的形式失败，需要人工跟进。
- **KSU 与 fusebpf 补丁必须配套**：ReSukiSU 若改掉 `KSU_FUSEBPF_FIX` 依赖的符号名或改为
  可选，需要同步更新 `third_party/fusebpf/`（或直接 `--no-fusebpf`）。这类不匹配只会在
  链接阶段暴露，工作流的 defconfig 检查会把失败提前到 2 分钟内。
- **ReSukiSU-Ultra Kconfig 变动**：新增/删除 `CONFIG_KSU_SUSFS_*` 时，`make gki_defconfig`
  会静默丢弃未声明的项；工作流的 defconfig 步骤会硬校验关键项，CI 会立刻暴露。
- **LTO 构建内存**：GitHub runner 约 4 vCPU / 16 GB，工作流用 `-j$(nproc)`；如遇 OOM，
  可把任务里的 `JOBS` 环境变量调小（`-j4` → `-j2`）。
- **首次构建耗时**：需要拉 ACK 源码 + clang 预编译包（约 1–2 GB），并编译单片 LTO 内核，
  首次约 60–100 分钟；工具链有 Actions 缓存，后续构建会快一些。
