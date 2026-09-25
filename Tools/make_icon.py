"""It draws the app icon: a crescent moon with a soft glow on a night sky. Pure Python, no library."""
import math, struct, sys, zlib

N = 1024
SS = 2  # 2x2 supersampling for smooth edges.
STARS = [(770, 250, 15), (850, 470, 9), (230, 210, 10), (680, 820, 8), (300, 800, 6)]

def mix(a, b, t): return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))

def sky(x, y):
    top, bottom = (10, 16, 44), (33, 43, 96)
    c = mix(top, bottom, y / N)
    d = math.hypot(x - 470, y - 520)                       # The glow around the moon.
    g = max(0.0, 1 - d / 520) ** 2.2 * 0.55
    return mix(c, (120, 110, 150), g)

def pixel(x, y):
    # The crescent: a disc minus a shifted disc.
    d1 = math.hypot(x - 470, y - 530)
    d2 = math.hypot(x - 590, y - 430)
    if d1 < 300 and d2 > 265:
        t = (y - 230) / 600                                   # A warm vertical gradient.
        return mix((255, 236, 180), (240, 196, 110), max(0, min(1, t)))
    for sx, sy, r in STARS:                                   # Four-point stars.
        dx, dy = abs(x - sx), abs(y - sy)
        if (dx * dy < r * r * 0.35 and max(dx, dy) < r * 2.2) or math.hypot(dx, dy) < r * 0.55:
            return (255, 245, 215)
    return sky(x, y)

def render(path):
    rows = []
    for y in range(N):
        row = bytearray([0])
        for x in range(N):
            acc = [0.0, 0.0, 0.0]
            for sy in range(SS):
                for sx in range(SS):
                    c = pixel(x + (sx + 0.5) / SS, y + (sy + 0.5) / SS)
                    acc[0] += c[0]; acc[1] += c[1]; acc[2] += c[2]
            row += bytes(int(v / (SS * SS)) for v in acc)
        rows.append(bytes(row))
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', N, N, 8, 2, 0, 0, 0)) \
        + chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + chunk(b'IEND', b'')
    open(path, 'wb').write(png)

if __name__ == '__main__':
    for p in sys.argv[1:]: render(p)
