"""It draws a synthetic night-vision frame of a cot, 1280x720, for the demo mode and the screenshots.
It is not a photo. The repository is public, so no real picture of the nursery goes into it."""
import math, random, struct, sys, zlib
W, H = 1280, 720
random.seed(7)

def lum(x, y):
    # A wall with a soft infrared light from the upper left, and a vignette.
    v = 0.22 + 0.25 * math.exp(-((x - 380) ** 2 + (y - 160) ** 2) / (2 * 420 ** 2))
    # The mattress and a blanket.
    if 250 < x < 1030 and 430 < y < 560:
        v = 0.55 - (y - 430) / 800
        if 520 < x < 900 and 420 < y < 520:   # The blanket, with folds.
            v = 0.66 + 0.05 * math.sin((x - 520) / 18) - (y - 420) / 900
        if 380 < x < 500 and 440 < y < 500:   # A small pillow.
            v = max(v, 0.72 - ((x - 440) ** 2 / 3600 + (y - 470) ** 2 / 900) * 0.3)
    # The rail and the bars of the cot.
    if 230 < x < 1050 and (395 < y < 412 or 590 < y < 606):
        v = 0.78
    if 230 < x < 1050 and 395 < y < 606 and (x - 230) % 58 < 9:
        v = 0.74
    if (215 < x < 245 or 1035 < x < 1065) and 330 < y < 700:
        v = 0.8
    d = math.hypot((x - W / 2) / W, (y - H / 2) / H)
    v *= 1 - 0.9 * d ** 2
    return max(0, min(1, v + random.gauss(0, 0.018)))   # The sensor noise of night vision.

rows = []
for y in range(H):
    row = bytearray([0])
    for x in range(W):
        g = int(255 * lum(x, y))
        row += bytes((g, g, g))
    rows.append(bytes(row))
def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + chunk(b'IEND', b'')
open(sys.argv[1], 'wb').write(png)
