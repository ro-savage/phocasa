#!/usr/bin/env python3
"""segs.py <jpeg>... : lists a JPEG's marker segments up to SOS (APP1/Exif, APP1/XMP, APP2/MPF, ...) with sizes.
A rating write should add or change only APP1/XMP (and APP13/IPTC); the Exif segment must stay the same size."""
import sys
for p in sys.argv[1:]:
    d = open(p, 'rb').read(); i = 2; out = []
    while i + 4 <= len(d) and d[i] == 0xFF:
        m = d[i + 1]
        if m == 0xDA:
            break
        L = (d[i + 2] << 8) | d[i + 3]; pay = d[i + 4:i + 2 + L]
        name = {0xE0: 'APP0', 0xE1: 'APP1', 0xE2: 'APP2', 0xED: 'APP13', 0xFE: 'COM'}.get(m, f'FF{m:02X}')
        tag = 'Exif' if pay.startswith(b'Exif') else 'XMP' if pay.startswith(b'http://ns.adobe.com/xap') else 'MPF' if pay.startswith(b'MPF') else ''
        out.append(f'{name}{"/" + tag if tag else ""}:{L + 2}'); i += 2 + L
    print(p.split('/')[-1], len(d), ' '.join(out))
