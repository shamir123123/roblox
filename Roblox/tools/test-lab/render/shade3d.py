#!/usr/bin/env python3
"""Flat-shaded perspective render of a render/dump3d.luau dump (terrain grid + faces), with a
real depth buffer (pure Python + PIL, no numpy): shows exactly where ground pokes through a
road or a wall stands clear of the ground.
usage: shade3d.py dump3d.json out.png cx cy cz dist yawDeg pitchDeg [w h]
The camera looks at (cx, cy, cz) from `dist` studs away; yaw 0 looks along +Z, pitch is the
angle down from horizontal."""
import json, math, sys
from array import array
from PIL import Image

d = json.load(open(sys.argv[1]))
out = sys.argv[2]
cx, cy, cz = float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
dist = float(sys.argv[6]); yaw = math.radians(float(sys.argv[7])); pitch = math.radians(float(sys.argv[8]))
W = int(sys.argv[9]) if len(sys.argv) > 9 else 1000
H = int(sys.argv[10]) if len(sys.argv) > 10 else 640

fwd = (math.sin(yaw) * math.cos(pitch), -math.sin(pitch), math.cos(yaw) * math.cos(pitch))
cam = (cx - fwd[0] * dist, cy - fwd[1] * dist, cz - fwd[2] * dist)
def norm(v):
    l = math.sqrt(v[0]**2 + v[1]**2 + v[2]**2) or 1
    return (v[0]/l, v[1]/l, v[2]/l)
def cross(a, b): return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])
def dot(a, b): return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]
right = norm(cross((0, 1, 0), fwd)); up = cross(fwd, right)
F = W * 0.9
LIGHT = norm((0.4, 1.0, 0.3))
zbuf = array('f', [1e30]) * (W * H)
img = bytearray([150, 185, 215] * (W * H))

def proj(p):
    v = (p[0]-cam[0], p[1]-cam[1], p[2]-cam[2])
    z = dot(v, fwd)
    if z < 1: return None
    return (W/2 + F * dot(v, right) / z, H/2 - F * dot(v, up) / z, z)

def tri(a, b, c, col):
    # screen-space barycentric fill, 1/z interpolated (perspective-correct depth)
    minx = max(0, int(min(a[0], b[0], c[0]))); maxx = min(W-1, int(max(a[0], b[0], c[0])) + 1)
    miny = max(0, int(min(a[1], b[1], c[1]))); maxy = min(H-1, int(max(a[1], b[1], c[1])) + 1)
    if minx > maxx or miny > maxy: return
    area = (b[0]-a[0])*(c[1]-a[1]) - (b[1]-a[1])*(c[0]-a[0])
    if abs(area) < 1e-9: return
    ia, ib, ic = 1/a[2], 1/b[2], 1/c[2]
    r, g, bl = col
    for y in range(miny, maxy + 1):
        py = y + 0.5
        row = y * W
        for x in range(minx, maxx + 1):
            px = x + 0.5
            w0 = ((b[0]-px)*(c[1]-py) - (b[1]-py)*(c[0]-px)) / area
            if w0 < -1e-6: continue
            w1 = ((c[0]-px)*(a[1]-py) - (c[1]-py)*(a[0]-px)) / area
            if w1 < -1e-6: continue
            w2 = 1 - w0 - w1
            if w2 < -1e-6: continue
            z = 1 / (w0*ia + w1*ib + w2*ic)
            k = row + x
            if z < zbuf[k]:
                zbuf[k] = z
                j = k * 3
                img[j] = r; img[j+1] = g; img[j+2] = bl

MAXE = 6.0  # studs: longer triangles are split, so a face reaching behind the camera still draws
def d2(a, b): return (a[0]-b[0])**2 + (a[1]-b[1])**2 + (a[2]-b[2])**2
def emit(a, b, c, col, depth=0):
    e = [d2(a, b), d2(b, c), d2(c, a)]
    m = max(e)
    if m > MAXE * MAXE and depth < 12:
        if e[0] == m:
            ab = tuple((a[k]+b[k])/2 for k in range(3)); emit(a, ab, c, col, depth+1); emit(ab, b, c, col, depth+1)
        elif e[1] == m:
            bc = tuple((b[k]+c[k])/2 for k in range(3)); emit(a, b, bc, col, depth+1); emit(a, bc, c, col, depth+1)
        else:
            ca = tuple((c[k]+a[k])/2 for k in range(3)); emit(a, b, ca, col, depth+1); emit(ca, b, c, col, depth+1)
        return
    pa, pb, pc = proj(a), proj(b), proj(c)
    if pa is None or pb is None or pc is None: return
    if max(pa[0], pb[0], pc[0]) < 0 or min(pa[0], pb[0], pc[0]) > W: return
    if max(pa[1], pb[1], pc[1]) < 0 or min(pa[1], pb[1], pc[1]) > H: return
    tri(pa, pb, pc, col)

def poly(pts, c):
    n = norm(cross((pts[1][0]-pts[0][0], pts[1][1]-pts[0][1], pts[1][2]-pts[0][2]),
                   (pts[2][0]-pts[0][0], pts[2][1]-pts[0][1], pts[2][2]-pts[0][2])))
    shade = 0.45 + 0.55 * abs(dot(n, LIGHT))
    col = tuple(int(min(255, ch * shade)) for ch in c)
    for i in range(1, len(pts) - 1):
        emit(pts[0], pts[i], pts[i+1], col)

t = d['terrain']; n = t['n']; st = t['step']; h = t['h']
for j in range(n):
    for i in range(n):
        x0 = t['x0'] + i * st; z0 = t['z0'] + j * st
        a = (x0, h[j*(n+1)+i], z0); b = (x0+st, h[j*(n+1)+i+1], z0)
        c = (x0+st, h[(j+1)*(n+1)+i+1], z0+st); e = (x0, h[(j+1)*(n+1)+i], z0+st)
        poly([a, b, c], (96, 150, 72)); poly([a, c, e], (96, 150, 72))
for f in d['faces']:
    p = f['p']
    pts = [(p[k], p[k+1], p[k+2]) for k in range(0, len(p), 3)]
    if len(pts) >= 3: poly(pts, f['c'])
Image.frombytes('RGB', (W, H), bytes(img)).save(out)
print(f"-> {out}")
