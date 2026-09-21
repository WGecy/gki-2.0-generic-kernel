# GKI_ROOT GKI 6.6.118 构建环境
#   clang   : 官方 prebuilts/clang/host/linux-x86 @ main-kernel-build-2024 (clang-r510928)
#   bison/flex/m4/pkg-config : 本地解包的 Debian 包（无 root）
#   pahole/lz4              : 官方 kernel/prebuilts/build-tools
#   libelf/zlib 头文件       : 本地解包的 libelf-dev / zlib1g-dev
export GKI_ROOT=${HOME}/gki-kernel
export PATH=${GKI_ROOT}/hosttools/bin:${GKI_ROOT}/clang-prebuilt/clang-r510928/bin:${GKI_ROOT}/hosttools/root/usr/bin:${GKI_ROOT}/kbt/linux-x86/bin:${PATH:-/usr/local/bin:/usr/bin:/bin}
export LD_LIBRARY_PATH=${GKI_ROOT}/kbt/linux-x86/lib64:${GKI_ROOT}/hosttools/root/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}
export LIBRARY_PATH=${GKI_ROOT}/hosttools/root/usr/lib/x86_64-linux-gnu${LIBRARY_PATH:+:${LIBRARY_PATH}}
export M4=${GKI_ROOT}/hosttools/root/usr/bin/m4
export BISON_PKGDATADIR=${GKI_ROOT}/hosttools/root/usr/share/bison
export PKG_CONFIG_PATH=${GKI_ROOT}/hosttools/pkgconfig
export ARCH=arm64
export LLVM=1
