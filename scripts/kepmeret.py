#!/usr/bin/env python3
# ANSWERS: Mekkora egy kep PIXELBEN, kulso eszkoz nelkul -- jpg es webp fejlecbol.
#
# MIERT LETEZIK (merve 2026-09-09, barracuda): a `file`, az `identify` es az
# `exiftool` egyike sincs a gepen (exit 127). A kep-koltoztetes egyetlen olyan
# ellenorzese, ami ATELI az ujrakodolast (jpg -> webp), a PIXEL-MERET -- a
# bajtszam es a lenyomat nem, mert a konverzio mindkettot megvaltoztatja.
#
# Csak a fajl ELEJET olvassa (alapertelmezes 65536 bajt), tehat a 3438 par
# ellenorzese nagysagrendileg 7 megabajt, nem 100.
import struct, sys, urllib.request

def jpeg(b):
    i = 2
    while i < len(b) - 9:
        if b[i] != 0xFF:
            i += 1; continue
        m = b[i+1]
        if m in (0xC0,0xC1,0xC2,0xC3,0xC5,0xC6,0xC7,0xC9,0xCA,0xCB,0xCD,0xCE,0xCF):
            h, w = struct.unpack('>HH', b[i+5:i+9]); return w, h
        if m in (0xD8,0xD9) or 0xD0 <= m <= 0xD7:
            i += 2; continue
        if i + 4 > len(b): return None
        i += 2 + struct.unpack('>H', b[i+2:i+4])[0]
    return None

def webp(b):
    if b[:4] != b'RIFF' or b[8:12] != b'WEBP': return None
    c = b[12:16]
    if c == b'VP8X':
        return int.from_bytes(b[24:27],'little')+1, int.from_bytes(b[27:30],'little')+1
    if c == b'VP8 ':
        w, h = struct.unpack('<HH', b[26:30]); return w & 0x3FFF, h & 0x3FFF
    if c == b'VP8L':
        n = int.from_bytes(b[21:25],'little')
        return (n & 0x3FFF)+1, ((n >> 14) & 0x3FFF)+1
    return None

def meret(url, bajt=65536):
    r = urllib.request.Request(url, headers={'Range': 'bytes=0-%d' % (bajt-1)})
    with urllib.request.urlopen(r, timeout=20) as f:
        b = f.read()
    return jpeg(b) or webp(b), len(b)

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('hasznalat: python3 kepmeret.py <url> [url2 ...]', file=sys.stderr); raise SystemExit(2)
    for u in sys.argv[1:]:
        try:
            m, n = meret(u)
            print('%s\t%s\t%d bajt olvasva' % (u, ('%dx%d' % m) if m else 'ISMERETLEN', n))
        except Exception as e:
            print('%s\tHIBA\t%s' % (u, e))
