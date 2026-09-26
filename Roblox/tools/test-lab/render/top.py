#!/usr/bin/env python3
"""Top-down orthographic render of a part dump (render/dump.luau).
usage: top.py dump.json out.png [cx cz halfsize px_per_stud]"""
import json, math, sys
from PIL import Image, ImageDraw

def hull(pts):
    pts = sorted(set(pts))
    if len(pts) <= 2: return pts
    def cross(o, a, b): return (a[0]-o[0])*(b[1]-o[1]) - (a[1]-o[1])*(b[0]-o[0])
    lo, up = [], []
    for p in pts:
        while len(lo) >= 2 and cross(lo[-2], lo[-1], p) <= 0: lo.pop()
        lo.append(p)
    for p in reversed(pts):
        while len(up) >= 2 and cross(up[-2], up[-1], p) <= 0: up.pop()
        up.append(p)
    return lo[:-1] + up[:-1]

def world(cf, lx, ly, lz):
    x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf
    return (x + r00*lx + r01*ly + r02*lz, y + r10*lx + r11*ly + r12*lz, z + r20*lx + r21*ly + r22*lz)

def verts(p):
    sx, sy, sz = [v/2 for v in p['s']]
    cf = p['cf']; sh = p['shape']
    if sh == 'Wedge':
        loc = [(-sx,-sy,-sz),(sx,-sy,-sz),(-sx,-sy,sz),(sx,-sy,sz),(-sx,sy,sz),(sx,sy,sz)]
    elif sh == 'CornerWedge':
        loc = [(-sx,-sy,-sz),(sx,-sy,-sz),(-sx,-sy,sz),(sx,-sy,sz),(sx,sy,-sz)]
    elif sh == 'Cylinder':
        loc = []
        for i in range(32):
            a = 2*math.pi*i/32
            for ex in (-sx, sx):
                loc.append((ex, sy*math.cos(a), sz*math.sin(a)))
    elif sh == 'Ball':
        loc = [(sx*math.cos(2*math.pi*i/32), sy, sz*math.sin(2*math.pi*i/32)) for i in range(32)]
    else:
        loc = [(a,b,c) for a in (-sx,sx) for b in (-sy,sy) for c in (-sz,sz)]
    return [world(cf, *l) for l in loc]

def main():
    parts = json.load(open(sys.argv[1]))
    out = sys.argv[2]
    cx = float(sys.argv[3]) if len(sys.argv) > 3 else 0
    cz = float(sys.argv[4]) if len(sys.argv) > 4 else 0
    half = float(sys.argv[5]) if len(sys.argv) > 5 else 150
    ppu = float(sys.argv[6]) if len(sys.argv) > 6 else 4
    W = int(2*half*ppu)
    img = Image.new('RGB', (W, W), (40, 44, 40))
    dr = ImageDraw.Draw(img, 'RGBA')
    items = []
    for p in parts:
        if p.get('k') == 'poly':
            f = p['pts']
            top = p['y']
            poly = [(round((f[i]-cx+half)*ppu, 2), round((f[i+1]-cz+half)*ppu, 2)) for i in range(0, len(f), 2)]
        else:
            vs = verts(p)
            top = max(v[1] for v in vs)
            poly = hull([(round((v[0]-cx+half)*ppu, 2), round((v[2]-cz+half)*ppu, 2)) for v in vs])
        if len(poly) < 3: continue
        xs = [q[0] for q in poly]; ys = [q[1] for q in poly]
        if max(xs) < 0 or min(xs) > W or max(ys) < 0 or min(ys) > W: continue
        items.append((top, p, poly))
    items.sort(key=lambda t: t[0])
    for top, p, poly in items:
        a = int(255*(1-p['t']))
        dr.polygon(poly, fill=tuple(p['c']) + (a,))
    import os
    lanes_file = sys.argv[1].replace('.json', '.lanes.json')
    if os.path.exists(lanes_file) and os.environ.get('LANES', '1') == '1':
        for ln in json.load(open(lanes_file)):
            f = ln['pts']
            pts = [((f[i]-cx+half)*ppu, (f[i+1]-cz+half)*ppu) for i in range(0, len(f), 2)]
            if len(pts) >= 2:
                dr.line(pts, fill=(0, 200, 255, 200) if ln.get('ring') else ((120, 255, 120, 220) if ln.get('conn') else (255, 60, 200, 200)), width=1)
                # arrow head dot at the lane end
                x, y = pts[-1]
                dr.ellipse((x-2, y-2, x+2, y+2), fill=(255, 255, 0, 255))
    tracks_file = sys.argv[1].replace('.json', '.tracks.json')
    if os.path.exists(tracks_file):
        for t in json.load(open(tracks_file)):
            x, y = (t[0]-cx+half)*ppu, (t[1]-cz+half)*ppu
            dr.point((x, y), fill=(255, 140, 0, 255))
    img.save(out)
    print(f"{len(items)} parts drawn -> {out}")

main()
