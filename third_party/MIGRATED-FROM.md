# 迁移来源 (老项目 ReSukiSU-Ultra-Kernel)
- adios/14-adios.patch                 <- patches/04-block-io/14-adios.patch  (patches.py: apply_adios, config.yaml features.adios)
- unicode_bypass/unicode_bypass_fix_6.1+.patch <- patches/09-android/unicode_bypass_fix_6.1+.patch (patches.py: apply_unicode_bypass, features.unicode_bypass)

# 2026-10-02 新增/更新的补丁 (不来自老项目)
- fusebpf/fusebpf-lookup-revalidate.patch 是 **v3 上游式**实现:
  `fs/fuse/backing.c` 的 `fuse_lookup_revalidate_{initialize,backing,finalize}` +
  `fs/fuse/fuse_i.h` 的 `struct fuse_lookup_revalidate_io` + `fs/fuse/dir.c` 的挂载点 +
  fuse selftest。它取代了老项目/KSU 仓库 `kernel-patches/fusebpf` 里的 v1 开关式实现
  (v1 只有"直接拿 `fuse_entry->backing_path` 取属性" + 一个运行时可关闭的全局开关)。
- fusebpf/fusebpf-no-eexist.patch 同步更新: 4 处 backing 路径 (mknod/mkdir/link/symlink)
  的 `-EEXIST` → `-ENOENT`, 不再依赖 v1 的运行时开关。
- unicode_bypass/unicode_bypass_fix_6.1+.patch 是同内容的重新生成版 (补 `index` 行、
  hunk 上下文带函数名), 语义不变。

v3 让 fusebpf 修复无条件生效, 旧符号 `fuse_bpf_lookup_revalidate_{enabled,set}` 消失;
ReSukiSU-Ultra 侧已同步删除这两个 extern 与整套运行时开关 (CONFIG_KSU_FUSEBPF_FIX /
fusebpf_fix sysfs / CMD_FUSEBPF_SET / ksud fusebpf 子命令) 以及它自带的
kernel-patches/fusebpf/ 副本, 因此内核侧不再需要兼容垫片; ci-integrate.sh 会在 KSU
仍引用旧符号时直接失败。

集成方式见 scripts/ci-integrate.sh 的 stage_adios() / stage_unicode_bypass() / stage_fusebpf()。
