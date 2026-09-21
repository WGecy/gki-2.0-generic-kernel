#!/bin/bash
# 用 stock boot.img 的布局重打包：只替换内核区、更新 kernel_size、清掉失效的 AVB(vbmeta+footer)
# 用法: ./pack-boot.sh <stock-boot.img> <Image> <输出.img>
set -euo pipefail
STOCK=${1:?用法: pack-boot.sh <stock-boot.img> <Image> <out.img>}
IMAGE=${2:?}
OUT=${3:?}

python3 - "$STOCK" "$IMAGE" "$OUT" <<'PY'
import struct, hashlib, sys

stock, image, out = sys.argv[1:4]
img = open(image, 'rb').read()
d = bytearray(open(stock, 'rb').read())

assert d[:8] == b"ANDROID!", "不是 Android boot image"
hv, = struct.unpack_from("<I", d, 40)
assert hv == 4, f"只支持 header v4，实际 {hv}"
orig_ks, = struct.unpack_from("<I", d, 8)
hdr_before = bytes(d[:4096])

# 1) 替换内核区
struct.pack_into("<I", d, 8, len(img))
d[4096:4096 + len(img)] = img
for i in range(4096 + len(img), 4096 + orig_ks):
    d[i] = 0

# 2) 移除因内核变化而失效的 AVB 数据（vbmeta + footer），保留分区尺寸
footer = d.rfind(b"AVBf")
avb_note = "无 AVB footer"
if footer != -1:
    f = bytes(d[footer:footer + 64])
    vb_off, vb_size = struct.unpack_from(">QQ", f, 20)
    start = min(vb_off, footer)
    # 新内核可能比原内核大、已覆盖旧 vbmeta 区域：只能从内核末尾之后开始清零
    start = max(start, 4096 + len(img))
    avb_note = f"清零 vbmeta[{vb_off}:{vb_off+vb_size}] 与 footer@{footer}（自 {start} 起）"
    for i in range(start, len(d)):
        d[i] = 0

open(out, "wb").write(bytes(d))

# 3) 自检
e = open(out, 'rb').read()
ks, = struct.unpack_from("<I", e, 8)
ok_kernel = hashlib.sha256(e[4096:4096+ks]).hexdigest() == hashlib.sha256(img).hexdigest()
diff = [i for i in range(4096) if hdr_before[i] != e[i]]
print(f"输出            : {out}")
print(f"大小            : {len(e)}")
print(f"kernel_size     : {ks}  (新 Image {len(img)})")
print(f"内核区校验       : {'OK' if ok_kernel else '不一致!!'}")
print(f"头部改动字节     : {diff}  (只应落在 8..11)")
print(f"AVB             : {avb_note}")
assert ok_kernel and all(8 <= i <= 11 for i in diff)
PY
