#!/usr/bin/env bash
# ============================================================================
#  GKI 2.0 内核集成脚本 —— ReSukiSU-Ultra + SUSFS + NoMount + ADIOS + Unicode 绕过
# ----------------------------------------------------------------------------
#  在 "$GKI_ROOT/common" (ACK 基线 + patches/*.patch 已 git am 到位的内核树) 之上:
#    1. 集成 ReSukiSU-Ultra (KernelSU): drivers/kernelsu 符号链接 + Makefile/Kconfig
#    2. 应用 KSU 的 fusebpf 内核侧补丁 (KSU_FUSEBPF_FIX 默认 y, 缺了会链接失败)
#    3. 应用 SUSFS (gitlab simonpunk 上游 50_add_susfs_in_gki-<android>-<kernel>.patch)
#    4. 应用 NoMount (third_party/nomount: hook 补丁 + nomount.c/h 源码)
#    5. 应用 ADIOS IO 调度器 (third_party/adios) + 强制默认 + 运行时拦截 cpq (elevator.c)
#    6. 应用 Unicode 零宽字符绕过 (third_party/unicode_bypass)
#    7. 写入 KSU / SUSFS / NoMount / ADIOS 的 defconfig 配置项
#  脚本幂等: 重复执行只更新 KernelSU/SUSFS 源码, 已应用的补丁自动跳过。
#
#  用法:
#    bash scripts/ci-integrate.sh --gki-root "$HOME/gki-kernel"
#
#  选项:
#    --gki-root DIR        GKI_ROOT (内含 common/), 默认 $GKI_ROOT 或 $HOME/gki-kernel
#    --workspace DIR       本仓库根目录 (含 third_party/), 默认脚本所在目录的上一级
#    --ksu-repo URL        KernelSU 仓库, 默认 https://github.com/WGecy/ReSukiSU-Ultra
#    --ksu-branch BR       KernelSU 分支/标签, 默认 main
#    --susfs-repo URL      SUSFS 仓库, 默认 https://gitlab.com/simonpunk/susfs4ksu.git
#    --susfs-branch BR     SUSFS 分支, 默认 gki-android15-6.6
#    --android-version V   默认 android15 (决定 SUSFS 补丁文件名)
#    --kernel-version V    默认 6.6
#    --no-fusebpf          跳过 KSU fusebpf 补丁 (同时关闭 CONFIG_KSU_FUSEBPF_FIX)
#    --no-susfs            跳过 SUSFS
#    --no-nomount          跳过 NoMount
#    --no-adios            跳过 ADIOS IO 调度器
#    --adios-lock MODE     ADIOS 运行时切换拦截: off|cpq|all (默认 cpq)
#                          cpq = 只拒绝切到 cpq (澎湃OS4 的 init.qti 会写 cpq)
#                          all = 任何非 adios 的切换请求都拒绝
#                          off = 不拦截 (允许 init/服务自由切换)
#    --no-unicode          跳过 Unicode 零宽字符绕过
#    --allow-rej           允许存在 .rej (默认: 出现 .rej 即失败)
#    -h | --help           显示帮助
#
#  退出码: 0 成功 / 非 0 失败 (失败原因见 [FAIL] 行)
# ============================================================================
set -euo pipefail

GKI_ROOT="${GKI_ROOT:-$HOME/gki-kernel}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd -- "$SCRIPT_DIR/.." && pwd)"

KSU_REPO="https://github.com/WGecy/ReSukiSU-Ultra"
KSU_BRANCH="main"
SUSFS_REPO="https://gitlab.com/simonpunk/susfs4ksu.git"
SUSFS_BRANCH="gki-android15-6.6"
ANDROID_VERSION="android15"
KERNEL_VERSION="6.6"
ENABLE_FUSEBPF=1
ENABLE_SUSFS=1
ENABLE_NOMOUNT=1
ENABLE_ADIOS=1
ADIOS_LOCK="cpq"
ENABLE_UNICODE=1
ALLOW_REJ=0

log()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --gki-root)        GKI_ROOT="${2:?}"; shift 2 ;;
    --workspace)       WORKSPACE="${2:?}"; shift 2 ;;
    --ksu-repo)        KSU_REPO="${2:?}"; shift 2 ;;
    --ksu-branch)      KSU_BRANCH="${2:?}"; shift 2 ;;
    --susfs-repo)      SUSFS_REPO="${2:?}"; shift 2 ;;
    --susfs-branch)    SUSFS_BRANCH="${2:?}"; shift 2 ;;
    --android-version) ANDROID_VERSION="${2:?}"; shift 2 ;;
    --kernel-version)  KERNEL_VERSION="${2:?}"; shift 2 ;;
    --no-fusebpf)      ENABLE_FUSEBPF=0; shift ;;
    --no-susfs)        ENABLE_SUSFS=0; shift ;;
    --no-nomount)      ENABLE_NOMOUNT=0; shift ;;
    --no-adios)        ENABLE_ADIOS=0; shift ;;
    --adios-lock)      ADIOS_LOCK="${2:?}"; shift 2 ;;
    --adios-lock=*)    ADIOS_LOCK="${1#*=}"; shift ;;
    --no-adios-lock)   ADIOS_LOCK="off"; shift ;;
    --no-unicode)      ENABLE_UNICODE=0; shift ;;
    --allow-rej)       ALLOW_REJ=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 die "未知参数: $1 (用 --help 查看用法)" ;;
  esac
done

COMMON="$GKI_ROOT/common"
[ -d "$COMMON" ] || die "内核树不存在: $COMMON (先克隆基线并 git am patches/*.patch)"

log "GKI_ROOT   : $GKI_ROOT"
log "工作区     : $WORKSPACE"
log "KernelSU   : $KSU_REPO @ $KSU_BRANCH"
[ "$ENABLE_FUSEBPF" = 1 ] && log "fusebpf    : KSU kernel-patches (KSU_FUSEBPF_FIX 依赖)"
[ "$ENABLE_SUSFS" = 1 ]   && log "SUSFS      : $SUSFS_REPO @ $SUSFS_BRANCH"
[ "$ENABLE_NOMOUNT" = 1 ] && log "NoMount    : $WORKSPACE/third_party/nomount"

# ============================================================================
#  通用小工具
# ============================================================================
ensure_line() {   # ensure_line FILE LINE
  local file="$1" line="$2"
  [ -f "$file" ] || die "文件不存在: $file"
  grep -qF -- "$line" "$file" && return 0
  printf '\n%s\n' "$line" >> "$file"
  ok "已追加到 ${file#"$COMMON"/}: $line"
}

insert_before_last_endmenu() {  # insert_before_last_endmenu FILE (stdin: 待插入内容)
  local file="$1" tmp
  tmp="$(mktemp)"
  awk -v extra="$(cat)" '
    { lines[NR] = $0 }
    END {
      last = 0
      for (i = 1; i <= NR; i++) if (lines[i] ~ /^endmenu/) last = i
      for (i = 1; i <= NR; i++) {
        if (i == last) { printf "%s\n", extra; print "" }
        print lines[i]
      }
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

enable_config() {  # enable_config DEFCONFIG CONFIG=y
  local file="$1" cfg="$2" name
  name="${cfg%%=*}"
  if grep -qx -- "$cfg" "$file"; then
    return 0
  elif grep -qE "^${name}=[ym]$" "$file" || grep -qx "# ${name} is not set" "$file"; then
    sed -i -E "s|^${name}=[ym]$|${cfg}|; s|^# ${name} is not set$|${cfg}|" "$file"
    ok "已启用(原位修改): $cfg"
  else
    printf '%s\n' "$cfg" >> "$file"
    ok "已启用(追加): $cfg"
  fi
}

disable_config() {  # disable_config DEFCONFIG CONFIG (显式关闭, 对抗 Kconfig 的 default y)
  local file="$1" name="${2%%=*}"
  if grep -qx "# ${name} is not set" "$file"; then
    return 0
  elif grep -qE "^${name}=[ym]$" "$file"; then
    sed -i -E "s|^${name}=[ym]$|# ${name} is not set|" "$file"
    ok "已关闭(原位修改): $name"
  else
    printf '# %s is not set\n' "$name" >> "$file"
    ok "已关闭(追加): $name"
  fi
}

verify_marker() {  # verify_marker FILE MARKER DESC
  grep -qF -- "$2" "$COMMON/$1" || die "校验失败: $3 —— $1 中缺少 \"$2\""
  ok "校验通过: $3"
}

drop_new_rej() {  # drop_new_rej SNAPSHOT_FILE —— 只删本次 patch 新产生的 .rej (Reversed 跳过属正常)
  local snap="$1" cur
  cur="$(mktemp)"
  find "$COMMON" -name '*.rej' 2>/dev/null | sort > "$cur"
  comm -13 "$snap" "$cur" 2>/dev/null | while IFS= read -r r; do
    [ -n "$r" ] && rm -f -- "$r"
  done
  rm -f "$cur" "$snap"
}

apply_patch_file() {  # apply_patch_file FILE DESC  (返回非 0 表示有 hunk 未应用)
  local pfile="$1" desc="$2" out snap ignored
  [ -f "$pfile" ] || die "补丁不存在: $pfile"

  snap="$(mktemp)"
  find "$COMMON" -name '*.rej' 2>/dev/null | sort > "$snap"

  if git -C "$COMMON" apply --check "$pfile" 2>/dev/null; then
    git -C "$COMMON" apply "$pfile"
    rm -f "$snap"
    ok "$desc: git apply 成功"
    return 0
  fi
  if git -C "$COMMON" apply --check -R "$pfile" 2>/dev/null; then
    rm -f "$snap"
    warn "$desc: 已应用, 跳过"
    return 0
  fi

  if out="$(patch -d "$COMMON" -p1 -F3 -N --batch --no-backup-if-mismatch < "$pfile" 2>&1)"; then
    printf '%s\n' "$out"
    rm -f "$snap"
    ok "$desc: patch -p1 -F3 应用成功 (存在模糊匹配, 见上方 offset 提示)"
    return 0
  fi

  if printf '%s' "$out" | grep -q 'Reversed' && ! printf '%s' "$out" | grep -q 'FAILED'; then
    # -N 语义: 已是目标状态的 hunk 被跳过(Reversed), 缺失的 hunk 已按上面日志补齐 → 视为成功
    ignored="$(printf '%s\n' "$out" | grep -c 'hunk ignored' || true)"
    drop_new_rej "$snap"
    ok "$desc: 补丁已处于目标状态 (Reversed 跳过 ${ignored} 条 hunk 提示, 未产生真实冲突)"
    return 0
  fi

  printf '%s\n' "$out"
  rm -f "$snap"
  warn "$desc: 部分 hunk 未应用 (见上方 FAILED, .rej 已保留)"
  return 1
}

# ============================================================================
#  1. ReSukiSU-Ultra (KernelSU) 集成
# ============================================================================
stage_ksu() {
  log "=========== [1/7] 集成 ReSukiSU-Ultra (KernelSU) ==========="
  local ksu_dir="$GKI_ROOT/KernelSU"
  local drivers="$COMMON/drivers"

  if [ -d "$ksu_dir/.git" ]; then
    # 更新失败 (网络抖动) 时退用本地已有副本, 不要因为拉取失败整体挂掉
    if git -C "$ksu_dir" fetch --depth 1 origin "$KSU_BRANCH" 2>&1 | tail -2; then
      git -C "$ksu_dir" checkout -q -B "$KSU_BRANCH" FETCH_HEAD
    else
      warn "KernelSU 更新失败 (网络?), 使用本地已有版本"
    fi
  else
    rm -rf "$ksu_dir"
    git clone --depth 1 -b "$KSU_BRANCH" "$KSU_REPO" "$ksu_dir"
  fi
  KSU_COMMIT="$(git -C "$ksu_dir" rev-parse --short HEAD)"
  log "KernelSU commit: $KSU_COMMIT"

  # 内建集成依赖 kernel/Kbuild (kbuild 优先读 Kbuild, 而非 LKM 用的 kernel/Makefile)
  [ -f "$ksu_dir/kernel/Kbuild" ] || die "KernelSU/kernel/Kbuild 不存在, 该版本不支持内建集成 (CONFIG_KSU=y)"

  # 符号链接 + Makefile / Kconfig
  # 注意: 残留的旧链接/目录会让 ln 把新链接建到目录里面 (幂等重跑时必现), 先清掉
  if [ -L "$drivers/kernelsu" ] || [ -e "$drivers/kernelsu" ]; then
    rm -rf -- "$drivers/kernelsu"
  fi
  ln -s "$(realpath --relative-to="$drivers" "$ksu_dir/kernel")" "$drivers/kernelsu"
  [ -e "$drivers/kernelsu/Kbuild" ] || die "drivers/kernelsu 软链接无效"
  ensure_line "$drivers/Makefile" 'obj-$(CONFIG_KSU) += kernelsu/'
  if ! grep -qF 'drivers/kernelsu/Kconfig' "$drivers/Kconfig"; then
    printf 'source "drivers/kernelsu/Kconfig"\n' | insert_before_last_endmenu "$drivers/Kconfig"
    ok "drivers/Kconfig: 已 source drivers/kernelsu/Kconfig"
  fi
  ok "KernelSU 内建集成完成 (drivers/kernelsu -> $ksu_dir/kernel)"
}

# ============================================================================
#  2. KSU fusebpf 内核侧补丁 (CONFIG_KSU_FUSEBPF_FIX 默认 y, 缺了链接会失败)
# ============================================================================
stage_fusebpf() {
  log "=========== [2/7] 应用 KSU fusebpf 内核侧补丁 ==========="
  # 老项目 apply_fusebpf(): 优先用 KSU 仓库自带的 kernel-patches/fusebpf, 本地 third_party 兜底
  local ksu_src="$GKI_ROOT/KernelSU/kernel-patches/fusebpf"
  local local_src="$WORKSPACE/third_party/fusebpf"
  local src="$ksu_src"
  [ -d "$ksu_src" ] || src="$local_src"
  log "补丁来源: $src"

  local name
  for name in fusebpf-lookup-revalidate.patch fusebpf-no-eexist.patch; do
    [ -f "$src/$name" ] || die "fusebpf 补丁缺失: $src/$name"
    apply_patch_file "$src/$name" "fusebpf: $name" || true
  done

  # 校验内核侧符号: KSU 的 fusebpf_fix_* / ksu_handle_susfs_cmd 直接引用它们
  verify_marker fs/fuse/backing.c 'fuse_bpf_lookup_revalidate_enabled' 'fusebpf 运行时开关变量'
  verify_marker fs/fuse/backing.c 'fuse_bpf_lookup_revalidate_set' 'fusebpf 开关设置函数'
  ok "fusebpf 集成完成"
}

# ============================================================================
#  3. SUSFS (gitlab simonpunk 上游)
# ============================================================================
stage_susfs() {
  log "=========== [3/7] 应用 SUSFS 补丁 ==========="
  local susfs_dir="$GKI_ROOT/susfs4ksu"
  local patch_name="50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch"

  if [ -d "$susfs_dir/.git" ]; then
    # 同 stage_ksu: 拉取失败时退用本地已有副本
    if git -C "$susfs_dir" fetch --depth 1 origin "$SUSFS_BRANCH" 2>&1 | tail -2; then
      git -C "$susfs_dir" checkout -q -B "$SUSFS_BRANCH" FETCH_HEAD
    else
      warn "SUSFS 更新失败 (网络?), 使用本地已有版本"
    fi
  else
    rm -rf "$susfs_dir"
    git clone --depth 1 -b "$SUSFS_BRANCH" "$SUSFS_REPO" "$susfs_dir"
  fi
  SUSFS_COMMIT="$(git -C "$susfs_dir" rev-parse --short HEAD)"
  log "SUSFS commit: $SUSFS_COMMIT ($SUSFS_BRANCH)"

  local patch="$susfs_dir/kernel_patches/$patch_name"
  [ -f "$patch" ] || die "SUSFS 补丁缺失: $patch"

  # 上游 50_add_susfs 补丁不含 susfs.c / 头文件, 需要先拷进内核树
  mkdir -p "$COMMON/fs" "$COMMON/include/linux"
  cp -f "$patch" "$COMMON/$patch_name"
  cp -f "$susfs_dir"/kernel_patches/fs/* "$COMMON/fs/"
  cp -f "$susfs_dir"/kernel_patches/include/linux/* "$COMMON/include/linux/"
  [ -f "$COMMON/fs/susfs.c" ] || die "SUSFS 源码缺失: $COMMON/fs/susfs.c"
  ok "SUSFS 源码/头文件已就位 (fs/susfs.c + include/linux/susfs*.h)"

  # 6.6 上下文修复: 补丁的 include hunk 以 <linux/dma-buf.h> 为锚点
  local base_c="$COMMON/fs/proc/base.c"
  if [ -f "$base_c" ] && ! grep -qF '#include <linux/dma-buf.h>' "$base_c"; then
    sed -i '/#include <linux\/cpufreq_times.h>/a #include <linux/dma-buf.h>' "$base_c"
    ok "fs/proc/base.c: 已补 #include <linux/dma-buf.h> (SUSFS 锚点)"
  fi

  apply_patch_file "$COMMON/$patch_name" "SUSFS 主补丁" || true

  # 6.6 上下文修复 (hunk 失配时补齐 susfs_def.h): 与老项目 build.yml 等价
  if grep -qE 'SUSFS_IS_INODE_SUS_MAP|susfs_is_current_proc_umounted|SUSFS_IS_INODE_OPEN_REDIRECT' "$base_c" \
     && ! grep -qF 'susfs_def.h' "$base_c"; then
    sed -i '/#include <linux\/dma-buf.h>/a #if defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n#include <linux/susfs_def.h>\n#endif' "$base_c"
    ok "fs/proc/base.c: 已补 susfs_def.h"
  fi
  local mem_c="$COMMON/mm/memory.c"
  if [ -f "$mem_c" ] && grep -qF 'SUSFS_IS_INODE_SUS_MAP' "$mem_c" && ! grep -qF 'susfs_def.h' "$mem_c"; then
    if grep -qF '#include <linux/zswap.h>' "$mem_c"; then
      sed -i '/#include <linux\/zswap.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n#include <linux\/susfs_def.h>\n#endif' "$mem_c"
    else
      sed -i '/#include <linux\/sched\/sysctl.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n#include <linux\/susfs_def.h>\n#endif' "$mem_c"
    fi
    ok "mm/memory.c: 已补 susfs_def.h"
  fi

  # 关键校验: sucompat 依赖 exec/stat 两个 hook (缺失则 su 不可用)
  verify_marker fs/exec.c 'ksu_handle_execveat' 'SUSFS exec hook (sucompat)'
  verify_marker fs/stat.c 'ksu_handle_stat' 'SUSFS stat hook (sucompat)'

  # 其余 hook 缺失只告警 (上游改名/裁剪时不至于直接失败)
  local f marker
  for pair in "fs/open.c:ksu_handle_faccessat" "kernel/sys.c:ksu_handle_setresuid" \
              "kernel/reboot.c:ksu_handle_sys_reboot" "fs/read_write.c:ksu_handle_sys_read" \
              "drivers/input/input.c:ksu_handle_input_handle_event"; do
    f="${pair%%:*}"; marker="${pair##*:}"
    grep -qF -- "$marker" "$COMMON/$f" || warn "SUSFS hook 缺失(非致命): $marker ($f)"
  done
  ok "SUSFS 集成完成"
}

# ============================================================================
#  3. NoMount (third_party/nomount)
# ============================================================================
stage_nomount() {
  log "=========== [4/7] 应用 NoMount 补丁 ==========="
  local src="$WORKSPACE/third_party/nomount"
  local patch="$src/nomount-6.6.patch"
  [ -d "$src" ] || die "NoMount 资产缺失: $src"
  [ -f "$patch" ] || die "NoMount hook 补丁缺失: $patch"

  apply_patch_file "$patch" "NoMount hook 补丁" || true

  # 补丁不含源码: nomount.c 用 #include "nomount.h" (相对路径), 头文件另放 include/linux
  cp -f "$src/nomount.c" "$COMMON/fs/nomount.c"
  cp -f "$src/nomount.h" "$COMMON/fs/nomount.h"
  cp -f "$src/nomount.h" "$COMMON/include/linux/nomount.h"
  ok "NoMount 源码已就位 (fs/nomount.c + fs/nomount.h + include/linux/nomount.h)"

  # 兜底修复: SUSFS 与 NoMount 都要往 fs/Makefile 同一处插一行, 模糊匹配可能漏掉
  local mk="$COMMON/fs/Makefile"
  if ! grep -qF 'obj-$(CONFIG_NOMOUNT) += nomount.o' "$mk"; then
    warn "fs/Makefile 未包含 NOMOUNT 目标, 手工补齐"
    printf '\nobj-$(CONFIG_NOMOUNT) += nomount.o\n' >> "$mk"
  fi
  local fs_kconfig="$COMMON/fs/Kconfig"
  if ! grep -qF 'config NOMOUNT' "$fs_kconfig"; then
    warn "fs/Kconfig 未包含 config NOMOUNT, 手工补齐"
    insert_before_last_endmenu "$fs_kconfig" <<'EOF'
config NOMOUNT
	bool "NoMount Path Redirection Subsystem"
	default y
	help
	  NoMount allows path redirection and virtual file injection
	  without mounting filesystems. Useful for systemless modifications.
EOF
  fi

  verify_marker fs/namei.c 'nomount_handle_getname' 'NoMount getname hook'
  verify_marker fs/namei.c 'nomount_handle_permission' 'NoMount permission hook'
  verify_marker fs/d_path.c 'nomount_handle_dpath' 'NoMount d_path hook'
  verify_marker fs/stat.c 'nomount_handle_getattr' 'NoMount getattr hook'
  verify_marker fs/readdir.c 'nomount_handle_iterate_dir' 'NoMount readdir hook'
  verify_marker fs/proc/task_mmu.c 'nomount_spoof_mmap_metadata' 'NoMount mmap 元数据伪装'
  verify_marker fs/statfs.c 'nomount_spoof_statfs' 'NoMount statfs 伪装'
  verify_marker fs/Makefile 'obj-$(CONFIG_NOMOUNT) += nomount.o' 'NoMount 编译目标'
  verify_marker fs/Kconfig 'config NOMOUNT' 'NoMount Kconfig'
  ok "NoMount 集成完成"
}

# ============================================================================
#  5. ADIOS IO 调度器 (third_party/adios, 迁移自老项目 features.adios)
# ============================================================================
inject_adios_default() {
  # elevator_get_default() 里 mq-deadline 是硬编码兜底; 老项目用同样的 #ifdef 注入改成 adios
  local ev="$COMMON/block/elevator.c"
  [ -f "$ev" ] || die "block/elevator.c 不存在"
  if grep -qF 'CONFIG_MQ_IOSCHED_DEFAULT_ADIOS' "$ev"; then
    ok "block/elevator.c: ADIOS 默认调度器注入已存在 (幂等)"
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  if ! awk '
    /^static struct elevator_type \*elevator_get_default\(struct request_queue \*q\)/ { in_func = 1 }
    in_func && !done && /^[[:space:]]*return elevator_find_get\(q, "mq-deadline"\);/ {
      print "#ifdef CONFIG_MQ_IOSCHED_DEFAULT_ADIOS"
      print "\treturn elevator_find_get(q, \"adios\");"
      print "#else"
      print $0
      print "#endif"
      done = 1
      next
    }
    in_func && /^}/ { in_func = 0 }
    { print }
    END { if (!done) exit 42 }
  ' "$ev" > "$tmp"; then
    rm -f "$tmp"
    die "block/elevator.c: 未找到 elevator_get_default() 的 mq-deadline 锚点 (内核结构变化?)"
  fi
  mv "$tmp" "$ev"
  ok "block/elevator.c: 默认调度器 → adios (CONFIG_MQ_IOSCHED_DEFAULT_ADIOS)"
}

inject_adios_lock() {  # inject_adios_lock MODE(off|cpq|all)
  # 运行时切换拦截: 厂商 init/服务会写 /sys/block/<userdata>/queue/scheduler。
  # 实证 (澎湃OS4 / Android 17, 机型 sun): /vendor/etc/init/hw/init.qti.kernel.rc 里
  #   on boot && property:persist.sys.stability.smartfocusio.v1=on
  #       write /sys/block/${dev.mnt.rootdisk.data}/queue/scheduler cpq
  # persist 属性 → 每次开机都把 userdata 从 adios 切成 cpq。这里在内核侧拒绝该请求。
  local mode="$1"
  local ev="$COMMON/block/elevator.c"
  [ -f "$ev" ] || die "block/elevator.c 不存在"

  # 先校验参数: 非法值不允许改动内核树 (否则会先剥离再报错, 留下半成品)
  local cond=""
  case "$mode" in
    off) : ;;
    cpq) cond='!strcmp(elevator_name, "cpq")' ;;
    all) cond='strcmp(elevator_name, "adios")' ;;
    *)   die "未知 --adios-lock 模式: $mode (可选 off|cpq|all)" ;;
  esac

  # 剥掉上一次注入的块 (支持换模式, 以及 --adios-lock=off 时彻底移除)
  local tmp
  tmp="$(mktemp)"
  awk '
    /GKI-ADIOS-LOCK-BEGIN/ { skip = 1; next }
    /GKI-ADIOS-LOCK-END/   { skip = 0; next }
    skip { next }
    { print }
  ' "$ev" > "$tmp"
  mv "$tmp" "$ev"

  if [ "$mode" = "off" ]; then
    ok "block/elevator.c: ADIOS 锁定未启用 (--adios-lock=off, 允许运行时切换)"
    return 0
  fi

  tmp="$(mktemp)"
  if ! awk -v cond="$cond" '
    /^static int elevator_change\(struct request_queue \*q, const char \*elevator_name\)/ { in_fn = 1 }
    in_fn && /if \(!blk_queue_registered\(q\)\)/ { pending = 1 }
    pending && /^[[:space:]]*return -ENOENT;/ {
      print
      print "\t/* GKI-ADIOS-LOCK-BEGIN: keep ADIOS on userdata (vendor init may write cpq on boot) */"
      print ""
      print "#ifdef CONFIG_MQ_IOSCHED_DEFAULT_ADIOS"
      print "\tif (" cond ") {"
      print "\t\tpr_info_once(\"elevator: blocked scheduler switch to %s (ADIOS locked)\\n\", elevator_name);"
      print "\t\treturn 0;"
      print "\t}"
      print "#endif"
      print "\t/* GKI-ADIOS-LOCK-END */"
      done = 1; pending = 0; in_fn = 0; next
    }
    { print }
    END { if (!done) exit 42 }
  ' "$ev" > "$tmp"; then
    rm -f "$tmp"
    die "block/elevator.c: 未找到 elevator_change() 的 blk_queue_registered 锚点 (内核结构变化?)"
  fi
  mv "$tmp" "$ev"
  ok "block/elevator.c: ADIOS 锁定已注入 (模式=$mode)"
}

stage_adios() {
  log "=========== [5/7] 应用 ADIOS IO 调度器 ==========="
  local src="$WORKSPACE/third_party/adios"
  local patch="$src/14-adios.patch"
  [ -f "$patch" ] || die "ADIOS 补丁缺失: $patch"

  apply_patch_file "$patch" "ADIOS 补丁 (block/adios.c + Kconfig + Makefile)" || true

  verify_marker block/adios.c 'adios' 'ADIOS 调度器源码'
  verify_marker block/Kconfig.iosched 'config MQ_IOSCHED_ADIOS' 'ADIOS Kconfig'
  verify_marker block/Kconfig.iosched 'config MQ_IOSCHED_DEFAULT_ADIOS' 'ADIOS 默认调度器 Kconfig'
  verify_marker block/Makefile 'adios.o' 'ADIOS 编译目标'

  inject_adios_default
  inject_adios_lock "$ADIOS_LOCK"
  if [ "$ADIOS_LOCK" != "off" ]; then
    verify_marker block/elevator.c 'GKI-ADIOS-LOCK-END' 'ADIOS 运行时切换拦截 (锁定)'
  fi
  ok "ADIOS 集成完成 (默认调度器 + 锁定模式=$ADIOS_LOCK)"
}

# ============================================================================
#  6. Unicode 零宽字符绕过 (third_party/unicode_bypass, 迁移自老项目 features.unicode_bypass)
# ============================================================================
stage_unicode_bypass() {
  log "========== [6/7] 应用 Unicode 零宽字符绕过 ==========="
  local src="$WORKSPACE/third_party/unicode_bypass"
  local patch="$src/unicode_bypass_fix_6.1+.patch"
  [ -f "$patch" ] || die "Unicode 绕过补丁缺失: $patch"

  # 该补丁只改 UTF-8 归一化数据 (mkutf8data.c / utf8data.c_shipped): 去掉零宽字符 ignore 类,
  # 使文件名归一化不再忽略零宽字符 → 无法用零宽字符绕过 (SUSFS 隐藏/检测更可靠)
  apply_patch_file "$patch" "Unicode 零宽字符绕过补丁" || true

  # 校验: mkutf8data.c 的 ignore_init 被移除, shipped 数据表按补丁缩小 (64256 → 64080)
  if grep -qF 'ignore_init' "$COMMON/fs/unicode/mkutf8data.c"; then
    die "校验失败: fs/unicode/mkutf8data.c 仍含 ignore_init (Unicode 绕过补丁未应用)"
  fi
  grep -qF 'utf8data[64080]' "$COMMON/fs/unicode/utf8data.c_shipped" \
    || die "校验失败: fs/unicode/utf8data.c_shipped 数据表未按补丁变化 (期望 utf8data[64080])"
  ok "Unicode 绕过集成完成 (归一化不再忽略零宽字符)"
}

# ============================================================================
#  7. defconfig 配置项
# ============================================================================
stage_defconfig() {
  log "=========== [7/7] 写入 defconfig (KSU / fusebpf / SUSFS / NoMount / ADIOS / Unicode) ==========="
  local defconfig="$COMMON/arch/arm64/configs/gki_defconfig"
  [ -f "$defconfig" ] || die "defconfig 不存在: $defconfig"

  # KernelSU: 内建 (y) — 钩子方式由 ReSukiSU Kconfig 的 choice 默认值决定
  # (GKI2 走 tracepoint syscall redirect, 无需手工 hook 源码补丁)
  enable_config "$defconfig" 'CONFIG_KSU=y'
  enable_config "$defconfig" 'CONFIG_KSU_NETISOLATE=y'
  enable_config "$defconfig" 'CONFIG_NOMOUNT=y'

  # fusebpf: 该选项默认 y 且引用内核侧 fuse_bpf_lookup_revalidate_* 符号,
  # 必须与上面的 fusebpf 补丁保持一致 (--no-fusebpf 时必须显式关闭, 否则链接失败)
  if [ "$ENABLE_FUSEBPF" = 1 ]; then
    enable_config "$defconfig" 'CONFIG_KSU_FUSEBPF_FIX=y'
  else
    disable_config "$defconfig" 'CONFIG_KSU_FUSEBPF_FIX'
  fi

  if [ "$ENABLE_SUSFS" = 1 ]; then
    local c
    for c in CONFIG_KSU_SUSFS=y \
             CONFIG_KSU_SUSFS_SUS_PATH=y \
             CONFIG_KSU_SUSFS_SUS_MOUNT=y \
             CONFIG_KSU_SUSFS_SUS_KSTAT=y \
             CONFIG_KSU_SUSFS_SPOOF_UNAME=y \
             CONFIG_KSU_SUSFS_ENABLE_LOG=y \
             CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y \
             CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y \
             CONFIG_KSU_SUSFS_OPEN_REDIRECT=y \
             CONFIG_KSU_SUSFS_SUS_MAP=y; do
      enable_config "$defconfig" "$c"
    done
  fi

  # ADIOS IO 调度器: 必须 =y 才能满足 MQ_IOSCHED_DEFAULT_ADIOS 的 depends on ...=y
  if [ "$ENABLE_ADIOS" = 1 ]; then
    enable_config "$defconfig" 'CONFIG_MQ_IOSCHED_ADIOS=y'
    enable_config "$defconfig" 'CONFIG_MQ_IOSCHED_DEFAULT_ADIOS=y'
  else
    disable_config "$defconfig" 'CONFIG_MQ_IOSCHED_DEFAULT_ADIOS'
    disable_config "$defconfig" 'CONFIG_MQ_IOSCHED_ADIOS'
  fi

  # Unicode 绕过: 该补丁改的是内核自带的归一化数据表, 需要 CONFIG_UNICODE=y 才会生效
  if [ "$ENABLE_UNICODE" = 1 ]; then
    enable_config "$defconfig" 'CONFIG_UNICODE=y'
  fi

  # 构建信息 (供工作流生成 release notes)
  {
    echo "KSU_REPO=$KSU_REPO"
    echo "KSU_BRANCH=$KSU_BRANCH"
    echo "KSU_COMMIT=${KSU_COMMIT:-unknown}"
    echo "FUSEBPF=$([ "$ENABLE_FUSEBPF" = 1 ] && echo enabled || echo disabled)"
    echo "SUSFS_REPO=$SUSFS_REPO"
    echo "SUSFS_BRANCH=$SUSFS_BRANCH"
    echo "SUSFS_COMMIT=${SUSFS_COMMIT:-disabled}"
    echo "NOMOUNT=$([ "$ENABLE_NOMOUNT" = 1 ] && echo enabled || echo disabled)"
    echo "NOMOUNT_SHA256=$(sha256sum "$WORKSPACE/third_party/nomount/nomount.c" | cut -d' ' -f1)"
    echo "ADIOS=$([ "$ENABLE_ADIOS" = 1 ] && echo enabled || echo disabled)"
    echo "ADIOS_LOCK=$([ "$ENABLE_ADIOS" = 1 ] && echo "$ADIOS_LOCK" || echo n/a)"
    echo "UNICODE_BYPASS=$([ "$ENABLE_UNICODE" = 1 ] && echo enabled || echo disabled)"
  } > "$GKI_ROOT/ci-build-info.env"
  ok "构建信息已写入: $GKI_ROOT/ci-build-info.env"
}

# ============================================================================
#  执行
# ============================================================================
KSU_COMMIT=""
SUSFS_COMMIT=""

stage_ksu
[ "$ENABLE_FUSEBPF" = 1 ] && stage_fusebpf
[ "$ENABLE_SUSFS" = 1 ]   && stage_susfs
[ "$ENABLE_NOMOUNT" = 1 ] && stage_nomount
[ "$ENABLE_ADIOS" = 1 ]   && stage_adios
[ "$ENABLE_UNICODE" = 1 ] && stage_unicode_bypass
stage_defconfig

REJ_LIST="$(find "$COMMON" -name '*.rej' | sort || true)"
if [ -n "$REJ_LIST" ]; then
  warn "存在未应用成功的补丁片段 (.rej):"
  # 用 here-string 读取 (管道会把 while 放进子 shell, die 后无法中断主流程)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '  --- %s ---\n' "$f"
    sed -n '1,20p' "$f" | sed 's/^/    /'
  done <<< "$REJ_LIST"
  [ "$ALLOW_REJ" = 1 ] || die "补丁未完整应用 (如确认无碍可用 --allow-rej 跳过)"
  warn "--allow-rej: 继续"
fi

log "================ 集成摘要 ================"
log "KernelSU : $KSU_REPO @ $KSU_BRANCH ($KSU_COMMIT)"
[ "$ENABLE_FUSEBPF" = 1 ] && log "fusebpf  : KSU kernel-patches (已应用, KSU_FUSEBPF_FIX=y)"
[ "$ENABLE_SUSFS" = 1 ]   && log "SUSFS    : $SUSFS_REPO @ $SUSFS_BRANCH ($SUSFS_COMMIT)"
[ "$ENABLE_NOMOUNT" = 1 ] && log "NoMount  : third_party/nomount (hook 补丁 + 源码)"
[ "$ENABLE_ADIOS" = 1 ]   && log "ADIOS    : third_party/adios (调度器 + 默认调度器注入 + 锁定=$ADIOS_LOCK)"
[ "$ENABLE_UNICODE" = 1 ] && log "Unicode  : third_party/unicode_bypass (零宽字符绕过)"
log "内核树改动: $(git -C "$COMMON" status --porcelain | wc -l) 个文件"
log "========================================="
ok "ReSukiSU-Ultra + SUSFS + NoMount + ADIOS + Unicode 绕过 集成完成"
