#!/usr/bin/env python3
import math, os, struct, zlib

SIZES = [16, 32, 128, 256, 512]
OUT = os.path.dirname(__file__)

def png(path, size):
    scale = 1
    n = size * scale
    rows = []
    for y in range(n):
        row = bytearray([0])
        for x in range(n):
            # Uniform light base, including the interior of the magnifying glass.
            px, py = x / scale, y / scale
            r = min(px, size - 1 - px, py, size - 1 - py)
            inside = r >= max(1.0, size * 0.08)
            rr = gg = bb = 245
            # Transparent canvas; only the blue magnifying glass is opaque.
            alpha = 0
            # Blue magnifying glass ring and handle.
            cx, cy = size * 0.43, size * 0.42
            radius = size * 0.22
            d = math.hypot(px - cx, py - cy)
            ring = abs(d - radius) <= size * 0.075
            handle = (px - size * 0.61) * 0.707 + (py - size * 0.61) * 0.707
            across = abs((px - size * 0.61) * 0.707 - (py - size * 0.61) * 0.707)
            handle_on = -size * 0.02 <= handle <= size * 0.30 and across <= size * 0.065
            if ring or handle_on:
                rr, gg, bb = 42, 108, 235
                alpha = 255
            row.extend((rr, gg, bb, alpha))
        rows.append(bytes(row))
    raw = b''.join(rows)
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    data = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', n, n, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
    with open(path, 'wb') as f: f.write(data)

for size in SIZES:
    png(os.path.join(OUT, f'icon_{size}x{size}.png'), size)
    png(os.path.join(OUT, f'icon_{size}x{size}@2x.png'), size * 2)
