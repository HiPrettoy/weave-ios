"""生成 1024x1024 App 图标（纯标准库，不依赖 PIL）。
配色与 App 主色一致：深墨绿渐变 + 白色知识图谱节点。
"""
import zlib, struct, math, os

SIZE = 1024
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "Assets", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png")

C1 = (26, 84, 74)     # 深墨绿
C2 = (58, 150, 124)   # 亮墨绿

NODES = [
    (0.500, 0.455, 0.052),
    (0.335, 0.300, 0.036),
    (0.678, 0.312, 0.033),
    (0.742, 0.606, 0.035),
    (0.300, 0.640, 0.031),
    (0.512, 0.742, 0.028),
]
EDGES = [(0, 1), (0, 2), (0, 3), (0, 4), (0, 5), (1, 4), (2, 3), (3, 5), (4, 5), (2, 5)]

def seg_dist(px, py, ax, ay, bx, by):
    vx, vy = bx - ax, by - ay
    wx, wy = px - ax, py - ay
    seg = vx * vx + vy * vy
    t = 0.0 if seg == 0 else max(0.0, min(1.0, (wx * vx + wy * vy) / seg))
    dx, dy = px - (ax + vx * t), py - (ay + vy * t)
    return math.hypot(dx, dy)

def clamp01(x):
    return 0.0 if x < 0 else (1.0 if x > 1 else x)

rows = []
for y in range(SIZE):
    row = bytearray()
    row.append(0)  # filter type 0
    for x in range(SIZE):
        t = (x + y) / (2.0 * (SIZE - 1))
        r = C1[0] + (C2[0] - C1[0]) * t
        g = C1[1] + (C2[1] - C1[1]) * t
        b = C1[2] + (C2[2] - C1[2]) * t

        alpha = 0.0
        for i, j in EDGES:
            ax, ay = NODES[i][0] * SIZE, NODES[i][1] * SIZE
            bx, by = NODES[j][0] * SIZE, NODES[j][1] * SIZE
            d = seg_dist(x, y, ax, ay, bx, by)
            if d < 9.0:
                alpha = max(alpha, clamp01((7.0 - d) / 2.0) * 0.55)

        for nx, ny, nr in NODES:
            d = math.hypot(x - nx * SIZE, y - ny * SIZE)
            radius = nr * SIZE
            if d < radius + 2.0:
                alpha = max(alpha, clamp01((radius - d) / 2.0))

        if alpha > 0:
            r = r + (255 - r) * alpha
            g = g + (255 - g) * alpha
            b = b + (255 - b) * alpha

        row += bytes((int(r + 0.5), int(g + 0.5), int(b + 0.5)))
    rows.append(bytes(row))

raw = b"".join(rows)

def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw, 9))
       + chunk(b"IEND", b""))

with open(OUT, "wb") as f:
    f.write(png)
print("written", os.path.abspath(OUT), len(png), "bytes")
