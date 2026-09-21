#!/bin/bash
set -euo pipefail
. "$(dirname "$0")/env.sh"
export LOCALVERSION=
cd "$GKI_ROOT/common"
exec make O=out ARCH=arm64 LLVM=1 LOCALVERSION= \
     KCFLAGS=-D__ANDROID_COMMON_KERNEL__ \
     HOSTCFLAGS="-I$GKI_ROOT/hosttools/root/usr/include" \
     -j"$(nproc)" Image
