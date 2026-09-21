#!/bin/bash
# 校验产物 Image 的 vermagic 是否与设备 stock boot.img 完全一致（驱动能否加载的唯一硬条件）
set -euo pipefail
GKI_ROOT=${HOME}/gki-kernel
NEW=${1:-$GKI_ROOT/common/out/arch/arm64/boot/Image}
STOCK=${2:-/home/tees//path/to/stock_boot.img}

pick_version() { strings -a "$1" | grep -m1 "Linux version" || true; }
pick_vermagic() { strings -a "$1" | grep -m1 -E '^6\.6\.[0-9]+.*modversions aarch64' || true; }

echo "== 新 Image: $NEW"
pick_version "$NEW"
NEW_VM=$(pick_vermagic "$NEW"); echo "vermagic: $NEW_VM"

# stock boot.img 里的内核区（header v4, kernel 从 4096 开始）
TMP=$(mktemp)
python3 - "$STOCK" "$TMP" <<'EOF'
import struct, sys
d = open(sys.argv[1], 'rb').read()
ks, = struct.unpack_from('<I', d, 8)
open(sys.argv[2], 'wb').write(d[4096:4096+ks])
EOF
echo "== stock: $STOCK"
pick_version "$TMP"
STOCK_VM=$(pick_vermagic "$TMP"); echo "vermagic: $STOCK_VM"
rm -f "$TMP"

echo
if [ "$NEW_VM" = "$STOCK_VM" ]; then
  echo "✅ vermagic 完全一致 —— stock vendor 驱动可加载"
else
  echo "❌ vermagic 不一致："; diff <(echo "$STOCK_VM") <(echo "$NEW_VM") || true
  exit 1
fi
