# GitHub Actions 构建说明（BakaSU + SUSFS + ADIOS + Unicode 绕过）

本目录里的 `ci-integrate.sh` 与 `.github/workflows/` 一起，把 **BakaSU（KernelSU，
自带 NoMount）+ SUSFS + ADIOS IO 调度器 + Unicode 零宽字符绕过** 集成到本内核
（GKI 2.0 / android15-6.6，基线 `6.6.158`）上。
工作流结构迁移自老内核项目 `ReSukiSU-Ultra-Kernel`：

| 老项目 | 本项目 | 作用 |
| --- | --- | --- |
| `kernel-android15-6-6.yml` | `.github/workflows/kernel-android15-6-6.yml` | 入口：读版本矩阵 → 调构建 → 拉管理器 APK → 合并发布 |
| `build.yml` | `.github/workflows/build.yml` | 可复用构建流程（拉源码/补丁/集成/编译/打包） |
| `get-manager.yml` | `.github/workflows/get-manager.yml` | 拉取 BakaSU 管理器 APK |
| — | `data/android15/6.6.json` | 版本矩阵（含 ACK 基线 commit） |
| `patches.py` + `build.py` 的集成步骤 | `scripts/ci-integrate.sh` | KSU/fusebpf/SUSFS/ADIOS/Unicode 集成（可在本地直接跑） |
| `third_party/AnyKernel3`、`fusebpf`、`adios`、`unicode_bypass` | 同路径 | 打包模板与各功能补丁资产 |

迁移进度与「还缺什么、怎么补」见 [`docs/feature-diff.md`](../docs/feature-diff.md)；
目前仍未迁移的主要是 BBRv3 / ipset / zram-lz4kd / mTHP / 各类性能温控调优 / OEM vendor 兼容。

## 触发与输入

`Actions → GKI 2.0 内核构建 - Android 15 (6.6) → Run workflow`

| 输入 | 默认 | 说明 |
| --- | --- | --- |
| `ksu_branch` | `main` | KernelSU 分支/标签（仓库固定为 `https://github.com/WGecy/BakaSU`） |
| `susfs_pin` | `93114563fd6b...` | SUSFS **固定 commit**（gitlab `simonpunk/susfs4ksu`）。分支名不再接受：上游 `gki-android15-6.6` 是移动目标，跟随分支头曾把构建打挂（见下文「SUSFS 版本钉死」） |
| `adios_lock` | `off` | ADIOS 运行时切换拦截（不影响默认调度器，adios 恒为默认）：`off`=不拦截（默认，允许 init.qti 等把调度器切走）/ `cpq`=只拒绝切到 cpq（澎湃OS4 的 init.qti 会写 cpq）/ `all`=只允许 adios |
| `custom_suffix` | 空 | 自定义内核后缀，插在 `-android15-8` 与 `-4k` 之间，如 `-test-01` → `6.6.158-android15-8-test-01-4k`；留空时取默认值 `-WGecy` → `6.6.158-android15-8-WGecy-4k` |
| `build_time` | `N` | `N`/留空 = 当前 UTC，否则写入 `KBUILD_BUILD_TIMESTAMP` |

产物（发布到 `kernel-latest` Release，同时作为 Actions artifact 上传）：

- `android15-6.6.158-2026-09-AnyKernel3.zip`（AnyKernel3 刷机包）
- `Image-6.6.158`（裸 Image，配合 `scripts/pack-boot.sh` 可自行重打包 boot.img）
- `build-info.txt`（基线 commit / KSU 与 SUSFS commit / NoMount 内建状态与 sha256 / 构建编号）
- `BakaSU-universal.apk`（管理器，来自 get-manager 任务）

### 管理器 APK 从哪来（get-manager.yml）

管理器取自 `WGecy/BakaSU`，两条路按顺序尝试：

1. **GitHub Release**：`/repos/WGecy/BakaSU/releases?per_page=1` 取最新（含 prerelease，
   不用 `/releases/latest`），资产优先匹配 `/BakaSU-universal.apk`，再退
   `*-universal-release.apk`，最后任意 `.apk`。
2. **Actions 制品**（该仓库当前还没有任何 Release，实际走的是这条）：查
   `build-manager.yml` 最近 10 次成功运行，取其中未过期的 `Manager-release` 制品
   （repack-manager 重签名后的成品），解压后优先取 universal 那个 apk。

两条路都失败时只打 `::warning::` 并跳过，不阻塞内核构建。

> **需要配置 secret**：制品属于 `WGecy/BakaSU`，本仓库的 `GITHUB_TOKEN` 只能读本仓库，
> 跨仓库读 Actions 制品会 403。要在本仓库（`Settings → Secrets and variables → Actions`）
> 添加 `KSU_REPO_TOKEN`：一个有 `WGecy/BakaSU` 读权限的 PAT（经典 PAT 勾 `repo` 即可；
> fine-grained PAT 需给该仓库 `Actions: Read` + `Contents: Read`）。未配置时工作流会退回
> `GITHUB_TOKEN`，此时路线 2 必然拿不到 APK，只会产出内核、没有管理器。

## 构建流程（build.yml）

1. **环境**：free-disk-space 清盘；`apt` 装 `build-essential bc bison flex libelf-dev
   libssl-dev zlib1g-dev python3 zip unzip cpio rsync patch jq`。
2. **拉基线**：`git init` + `git fetch --depth 1 origin <baseline_commit>`（失败则用
   快照日期附近的 `android15-6.6` 浅历史兜底），随后校验 `HEAD == baseline_commit`。
3. **打补丁**：`git am patches/*.patch`（84 个；基线换 commit 必须重新生成补丁）。
4. **工具链**：`apt` 装 `clang-19 lld-19 llvm-19`（Ubuntu 24.04 的 19.1.1；三个包把无版本号的
   `clang`/`ld.lld`/`llvm-*` 都装在 `/usr/lib/llvm-19/bin`，所以 make 仍用 `LLVM=1`，与
   `scripts/env.sh` 同一套做法）；`kernel/prebuilts/build-tools` 稀疏拉取 `linux-x86/{bin,lib64}`
   （pahole/lz4/dtc，走 Actions 缓存）；硬校验 10 个工具齐全后写入
   `PATH`/`LD_LIBRARY_PATH`/`CLANG_AUTOFDO_PROFILE`（AutoFDO profile 必须绝对路径）。
5. **集成**：`bash scripts/ci-integrate.sh --gki-root "$GKI_ROOT" --workspace "$GITHUB_WORKSPACE" ...`
6. **配置 + 编译**：`make O=out ARCH=arm64 LLVM=1 LOCALVERSION=
   KCFLAGS=-D__ANDROID_COMMON_KERNEL__ gki_defconfig`（defconfig 阶段清空 LOCALVERSION）
   然后 `make ... LOCALVERSION=<后缀>-4k -j$(nproc) Image`（`<后缀>` 缺省为 `-WGecy`）
   （单片内核 + LTO thin + AutoFDO，与 `scripts/build.sh` 一致）。
7. **校验**：`kernel.release` / Image 版本串 / `vmlinux` 中 `kernelsu_init`、
   `susfs is initialized` 两项内建标记；NoMount 由 BakaSU 的 `kernel/nomount/` 随
   `kernelsu.o` 一起编入，判据两条（任一命中即通过）：`vmlinux` 里的 `ksu_nomount_init`
   符号，或 `strings` 到的 `NoMount: Loaded successfully`（`nm_info` 的
   `KERN_INFO "NoMount: "` 前缀在编译期拼进字面量）。注意 BakaSU 版把入口改名成
   `ksu_nomount_init` 并删掉了 `MODULE_*` 与 `module_init`，所以老的
   `nomount_init` 符号名与 `.modinfo` 描述串两条判据都不再成立。
   配置阶段另外校验 `CONFIG_KSU=y` 时 `drivers/kernelsu/nomount/{nomount.c,nomount.h,nomount_api.h}`
   齐全、`drivers/kernelsu/Kbuild` 含 `nomount/nomount.o`、且内核树里**没有** `fs/nomount/`
   （有则说明还有老脚本在复制第二份，会 `-EEXIST`）。
8. **打包**：AnyKernel3 目录内放入 `Image` 后 zip。

## ci-integrate.sh 做了什么

在 `$GKI_ROOT/common`（已 `git am` 补丁的内核树）上按顺序执行：

1. **KernelSU（BakaSU）**
   - `git clone --depth 1 -b <branch> <repo> $GKI_ROOT/KernelSU`
   - `common/drivers/kernelsu` → `KernelSU/kernel` 软链接（已验证该仓库存在 `kernel/Kbuild`，
     kbuild 优先读它，因此可以按 `CONFIG_KSU=y` 内建，而不是 LKM 用的 `kernel/Makefile`）
   - `drivers/Makefile` 追加 `obj-$(CONFIG_KSU) += kernelsu/`；`drivers/Kconfig` source 其 Kconfig
2. **fusebpf（内核侧补丁，必需，v3 上游式实现）**
   - 用本仓库 `third_party/fusebpf/`（唯一来源；KSU 仓库的 `kernel-patches/fusebpf/` 已随运行时开关一起删除）
   - `fusebpf-lookup-revalidate.patch`（v3）：`fs/fuse/backing.c` 新增
     `fuse_lookup_revalidate_{initialize,backing,finalize}`，`fs/fuse/dir.c` 的
     `fuse_dentry_revalidate()` 在父目录是 backing inode 且带 BPF 程序时改走
     `fuse_bpf_backing()` 并尊重 BPF 结果（`FUSE_ACTION_KEEP/REMOVE/REPLACE`），
     `fs/fuse/fuse_i.h` 新增 `struct fuse_lookup_revalidate_io`；同时更新 fuse selftest
     （`tools/testing/selftests/filesystems/fuse/`）
   - `fusebpf-no-eexist.patch`：mknod/mkdir/link/symlink 四条 backing 路径把 `-EEXIST`
     归一化成 `-ENOENT`（v3 起不再用运行时开关判断）
   - **KSU 侧已同步删除整套开关**（ReSukiSU-Ultra 2026-10-02 起，BakaSU 沿用）：`CONFIG_KSU_FUSEBPF_FIX`、
     `fusebpf_fix` sysfs 参数、`CMD_FUSEBPF_SET` 超调用、ksud 的 `fusebpf enable/disable`
     子命令、`FeatureId::Fusebpf` 与管理器里的 `settings_fusebpf_fix` 字符串都不再存在
     （feature id 6 仅在 `uapi/feature.h` 保留占位，避免编号漂移）
   - **顺序要求**：内核侧 v3 与 KSU 侧必须配套 —— 脚本会扫 clone 到的 KSU 源码，若它仍
     `extern` 引用 `fuse_bpf_lookup_revalidate_{enabled,set}`，会**在应用补丁前直接失败**，
     而不是等到链接 vmlinux 时才报 undefined symbol（历史教训: 2026-09-22 run 35693420939）
   - 如确实不想用：`--no-fusebpf`（只跳过 `third_party/fusebpf` 的两个补丁，已无配置项要关）
3. **SUSFS**（gitlab 上游，**版本钉死**）
   - 只认 `SUSFS_PIN`（默认 `93114563fd6b08092b9ce8c0309738c921ac8bd1`，= `gki-android15-6.6`
     分支上最后一次成功编译内核时用的 commit），`git fetch <SHA>` + `checkout --detach`，
     检出后还会硬校验 `rev-parse HEAD == SUSFS_PIN`，浅取/离线兜底都换不掉版本
   - 复制 `50_add_susfs_in_gki-android15-6.6.patch` 与
     `kernel_patches/{fs,include/linux}/*`（`susfs.c`、`susfs.h`、`susfs_def.h`）
   - `git apply` → 失败退回 `patch -p1 -F3 -N --batch`（多个补丁会往同一批公共文件
     —— 如 `fs/Makefile`、`block/Makefile` —— 里插行，模糊匹配是必要的）
   - 6.6 上下文修复（`fs/proc/base.c` 的 `dma-buf.h` 锚点、`susfs_def.h` 补齐）
   - **硬校验**：`fs/exec.c` 的 `ksu_handle_execveat`、`fs/stat.c` 的 `ksu_handle_stat`
     （sucompat 依赖，缺失即失败）
4. **NoMount：不单独集成**（BakaSU 内核自带）
   - BakaSU 的 `kernel/` 里有 `kernel/nomount/{nomount.c,nomount.h,nomount_api.h}`，
     `kernel/Kbuild` 在 `CONFIG_KSU=y` 且内核版本落在 4.9 - 6.12 时把 `nomount/nomount.o`
     编进 `kernelsu-objs`，没进这个范围会给一条 `NoMount: kernel X.Y is outside ...` 注记
   - 第 1 步建的 `drivers/kernelsu` 是**整目录软链接**，所以内建 KSU 一进来 NoMount 就已经
     在 `vmlinux` 里了，不需要再往 `fs/nomount/` 复制一份
   - 曾经的本仓库 `third_party/nomount/`（上游 v2.2.0 四件套）+ `stage_nomount()` 已移除：
     两份都会 `register_key_type(&nm_key_type)`，先注册的赢，后一个拿到 `-EEXIST`，
     dmesg 出现 `KernelSU: failed to init nomount: -17`，管理器里 nomount 状态恒为不可用
   - 要关掉它：给内核传 `CONFIG_KSU_DISABLE_NOMOUNT=y`（`kernel/Kconfig` 的
     `config KSU_DISABLE_NOMOUNT`），不是 `--no-nomount`
   - 用户态协议：`add_key("nomount", "trigger", &ptr, 8, -1)` + 4096 字节单页 payload
     （协议 v22，`kernel/nomount/nomount.h` 的 `NOMOUNT_BASE_VERSION`），**内核侧与
     ksud / 管理器必须同版本**，否则 `add_key` 返回 `-ECANCELED` 且 `payload.status` 永远是错
5. **ADIOS IO 调度器**（本仓库 `third_party/adios`，迁移自老项目 `features.adios`）
   - 应用 `14-adios.patch`：新增 `block/adios.c`，并注册 `block/Kconfig.iosched`
     （`MQ_IOSCHED_ADIOS` / `MQ_IOSCHED_DEFAULT_ADIOS`）与 `block/Makefile`
   - **默认调度器恒为 adios**（与 `adios_lock` 无关）：`inject_adios_default()` 把
     `block/elevator.c` 里 `elevator_get_default()` 硬编码的 `mq-deadline` 兜底包成
     `#ifdef CONFIG_MQ_IOSCHED_DEFAULT_ADIOS → return elevator_find_get(q, "adios")`
     （`GKI-ADIOS-DEFAULT-BEGIN/END` 标记；幂等，锚点找不到会明确失败），
     defconfig 同时打开 `CONFIG_MQ_IOSCHED_ADIOS=y` 与 `CONFIG_MQ_IOSCHED_DEFAULT_ADIOS=y`
   - **运行时切换拦截**由 `--adios-lock` 决定（`inject_adios_lock()`，`GKI-ADIOS-LOCK-BEGIN/END`）：
     `off`（默认）= 不注入，允许 init/服务自由切换；`cpq` = 只拒绝切成 `cpq`；
     `all` = 只允许 adios。换模式时旧块会被剥掉（`off` 即彻底移除），可反复切换。
     真机排查结论：澎湃OS4（Android 17）的 `/vendor/etc/init/hw/init.qti.kernel.rc` 在
     `on boot && property:persist.sys.stability.smartfocusio.v1=on` 时**每次开机**写
     `write /sys/block/${dev.mnt.rootdisk.data}/queue/scheduler cpq`（rootdisk.data=sda/userdata），
     所以只注入"默认值"挡不住 —— 要保住 adios 得把 `adios_lock` 设为 `cpq` 或 `all`
   - `--no-adios` 会显式关掉两项 config 并跳过补丁（此时 `elevator.c` 保持上游原样）
   - 刷机后验证：三种模式下 `cat /sys/block/sda/queue/scheduler` 开机后都应为 `[adios]`；
     `cpq`/`all` 下 `dmesg | grep 'ADIOS locked'` 会出现 `elevator: blocked scheduler switch to cpq`
6. **Unicode 零宽字符绕过**（本仓库 `third_party/unicode_bypass`，迁移自 `features.unicode_bypass`）
   - 应用 `unicode_bypass_fix_6.1+.patch`（2026-10-02 重新生成的版本：补上 `index` 行、
     hunk 上下文带函数名，便于 `git apply --check` / 三方合并）：改 `fs/unicode/mkutf8data.c`
     （移除 `ignore_init`）与 `fs/unicode/utf8data.c_shipped`（归一化数据表 64256 → 64080 字节），
     使文件名归一化不再忽略零宽字符
   - 硬校验：`mkutf8data.c` 不再含 `ignore_init`，且 shipped 表为 `utf8data[64080]`
   - defconfig：确保 `CONFIG_UNICODE=y`；`--no-unicode` 可跳过
7. **defconfig**：`CONFIG_KSU=y`、
   `CONFIG_KSU_SUSFS*` 10 项、`CONFIG_MQ_IOSCHED_ADIOS=y`、
   `CONFIG_MQ_IOSCHED_DEFAULT_ADIOS=y`、`CONFIG_UNICODE=y`
   （已启用跳过 / `# ... is not set` 原位替换 / 不存在则追加）；
   fusebpf 已无配置项（内核侧补丁本身即开关）。
   注意**不写** `CONFIG_KSU_NETISOLATE`：`WGecy/BakaSU` 的 `kernel/` 里没有 netisolate
   子模块（那是 BakaSU-Ultra 独有的），Kconfig 也没有该符号，写进去只会被
   `make gki_defconfig` 静默丢弃
8. **构建信息**：`$GKI_ROOT/ci-build-info.env`（KSU/SUSFS commit、fusebpf/ADIOS/
   Unicode 状态；NoMount 记录 `NOMOUNT=builtin|missing`、从
   `drivers/kernelsu/nomount/nomount.h` 抽出的 `NOMOUNT_VERSION` 与 `nomount.c` 的 sha256），
   供 release notes 与排障使用。

脚本幂等：重复执行只更新 KernelSU/SUSFS 源码，已应用的补丁自动跳过（`Reversed`）。
结束时若存在 `.rej` 会打印并失败（确认无碍可加 `--allow-rej`）；补丁调用带
`--no-backup-if-mismatch`，不会在树里留下 `.orig` 备份。

配置侧的两个前提（当前基线已满足，SUSFS 补丁自身会处理）：

- `CONFIG_KALLSYMS_ALL=y`（基线 gki_defconfig 已开）——KernelSU 需要 `write_op`、
  `sel_handle_status_ops`、`security_dump_masked_av` 等符号可见；
- KernelSU 钩子方式走 BakaSU Kconfig choice 的默认值 `KSU_TRACEPOINT_HOOK`
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

# 2) 集成 BakaSU(含内置 NoMount) + SUSFS + ADIOS + Unicode
bash scripts/ci-integrate.sh --gki-root "$GKI_ROOT" --workspace "$PWD"

# 3) 编译 (与 scripts/build.sh 相同的工具链/参数)
. scripts/env.sh
cd "$GKI_ROOT/common"
make O=out ARCH=arm64 LLVM=1 LOCALVERSION= \
     KCFLAGS=-D__ANDROID_COMMON_KERNEL__ \
     HOSTCFLAGS="-I$GKI_ROOT/hosttools/root/usr/include" gki_defconfig
make O=out ARCH=arm64 LLVM=1 LOCALVERSION=-WGecy-4k \
     KCFLAGS=-D__ANDROID_COMMON_KERNEL__ \
     HOSTCFLAGS="-I$GKI_ROOT/hosttools/root/usr/include" \
     CLANG_AUTOFDO_PROFILE="$GKI_ROOT/common/android/gki/aarch64/afdo/kernel.afdo" \
     -j8 Image
```

常用开关：`--no-susfs`、`--no-fusebpf`、`--no-adios`、`--no-unicode`、`--allow-rej`、`--ksu-branch <tag>`、
`--susfs-pin <sha>`、`--android-version android15`、`--kernel-version 6.6`；
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

- **SUSFS 版本已钉死（不再跟随分支头）**：`SUSFS_PIN` 默认
  `93114563fd6b08092b9ce8c0309738c921ac8bd1`（`gki-android15-6.6` 上最后一次成功编译内核的
  commit，2026-10-31 run 41209142211）。为什么必须钉：上游从 `c7f670f` 起引入
  `CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER`，该符号只在 KernelSU 侧 Kconfig 补丁里声明，
  BakaSU 的 `kernel/Kconfig` 没有 → 宏不生效 → `fs/susfs.c` 的
  `susfs_switch_to_ksu_domain` / `susfs_restore_creds` 失去调用者 →
  `-Wunused-function` 撞 `-Werror`，构建在 `fs/susfs.c` 直接失败（run 42211286621）。
  升级 SUSFS 的流程：先在本仓库 `kernel/Kconfig` 补上上游新增配置项（或确认新版本不再需要），
  再改 `SUSFS_PIN`（或工作流输入 `susfs_pin`）跑一次完整构建验证。
- **SUSFS 补丁的 hunk 上下文与 ACK 版本相关**：`50_add_susfs_in_gki-android15-6.6.patch`
  由 simonpunk 维护。脚本已用 `-F3` + 落点校验兜住小幅漂移；若换基线后大改，
  会以“hunk FAILED / 缺少 hook”的形式失败，需要人工跟进。
- **KSU 与 fusebpf 必须配套（已从"靠垫片兜住"改为"提前失败"）**：内核侧是 v3（修复无条件生效，
  无 `fuse_bpf_lookup_revalidate_{enabled,set}`），KSU 侧（ReSukiSU-Ultra 2026-10-02 起，BakaSU 沿用）也已删掉
  这两个 extern 与整套运行时开关、`kernel-patches/fusebpf/`。`stage_fusebpf()` 会扫 clone 到的
  KSU 源码：仍引用旧符号时**在应用补丁前**就报错并提示换分支，因此不会再出现"编译 30 分钟后
  链接失败"。若将来 KSU 又引入新的符号依赖，同步改 `third_party/fusebpf/` 与该检查即可。
- **fusebpf 补丁的落点会随 ACK 漂移**：v3 补丁含 fuse selftest 改动
  （`tools/testing/selftests/filesystems/fuse/`）。换基线后如果 selftest 变化较大，
  `git apply` 会失败并退回 `patch -p1 -F3`，请在日志里确认没出现 `FAILED`/`.rej`；
  确实只差 selftest 时，可从补丁里剔除这两个文件（内核功能不受影响）。
- **BakaSU Kconfig 变动**：新增/删除 `CONFIG_KSU_SUSFS_*` 时，`make gki_defconfig`
  会静默丢弃未声明的项；工作流的 defconfig 步骤会硬校验关键项，CI 会立刻暴露。
- **LTO 构建内存**：GitHub runner 约 4 vCPU / 16 GB，工作流用 `-j$(nproc)`；如遇 OOM，
  可把任务里的 `JOBS` 环境变量调小（`-j4` → `-j2`）。
- **首次构建耗时**：需要拉 ACK 源码（约 1–2 GB）+ build-tools，并编译单片 LTO 内核，
  首次约 60–100 分钟；工具链有 Actions 缓存，后续构建会快一些。
