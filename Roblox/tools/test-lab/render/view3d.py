#!/usr/bin/env python3
"""Angled 3D render of a lab dump (render/dump.luau) + its terrain tiles (<dump>.terrain.json).
usage: view3d.py dump.json out.png cx cz [dist yawDeg pitchDeg width height]
Terrain is drawn as a smooth heightfield through the painted tile tops (what Roblox smooth
terrain approximates); parts are boxes/wedges; road specs are thin slabs at their top height."""
import json, math, sys
import bpy, bmesh

dump, out = sys.argv[1], sys.argv[2]
cx, cz = float(sys.argv[3]), float(sys.argv[4])
dist = float(sys.argv[5]) if len(sys.argv) > 5 else 120
yaw = math.radians(float(sys.argv[6]) if len(sys.argv) > 6 else 35)
pitch = math.radians(float(sys.argv[7]) if len(sys.argv) > 7 else 32)
W = int(sys.argv[8]) if len(sys.argv) > 8 else 1280
H = int(sys.argv[9]) if len(sys.argv) > 9 else 800

bpy.ops.wm.read_factory_settings(use_empty=True)
parts = json.load(open(dump))
tiles = json.load(open(dump.replace('.json', '.terrain.json')))

# Roblox (x, y, z) -> Blender (x, -z, y): Blender is Z-up, right-handed.
def B(x, y, z):
    return (x, -z, y)

verts, faces, cols = [], [], []
def face(vs, c):
    base = len(verts)
    verts.extend(vs)
    faces.append(tuple(range(base, base + len(vs))))
    cols.append(c)

# --- terrain heightfield through tile centres -----------------------------------------
hts = {}
for tx, tz, y in tiles:
    hts[(round(tx), round(tz))] = y
xs = sorted({k[0] for k in hts}); zs = sorted({k[1] for k in hts})
R = dist * 1.6
for x in xs:
    if abs(x + 2 - cx) > R: continue
    for z in zs:
        if abs(z + 2 - cz) > R: continue
        a, b, c, d = (x, z), (x + 4, z), (x + 4, z + 4), (x, z + 4)
        if not all(k in hts for k in (a, b, c, d)): continue
        ys = [hts[k] for k in (a, b, c, d)]
        g = 0.36 + 0.02 * ((x // 4 + z // 4) % 2)
        face([B(a[0] + 2, ys[0], a[1] + 2), B(d[0] + 2, ys[3], d[1] + 2), B(c[0] + 2, ys[2], c[1] + 2), B(b[0] + 2, ys[1], b[1] + 2)], (0.22, g, 0.16))

# --- parts --------------------------------------------------------------------------
def world(cf, lx, ly, lz):
    x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf
    return B(x + r00*lx + r01*ly + r02*lz, y + r10*lx + r11*ly + r12*lz, z + r20*lx + r21*ly + r22*lz)

BOX = [(0,1,3,2),(4,6,7,5),(0,4,5,1),(2,3,7,6),(0,2,6,4),(1,5,7,3)]
for p in parts:
    c = p.get('c') or [255, 140, 0]
    col = tuple(min(1, (v / 255) ** 2.2) for v in c)
    if p['k'] == 'poly':
        f = p['pts']; y = p['y']
        pts = [(f[i], f[i+1]) for i in range(0, len(f), 2)]
        if abs(pts[0][0] - cx) > R or abs(pts[0][1] - cz) > R: continue
        face([B(px, y, pz) for px, pz in pts][::-1], col)
        continue
    if p.get('t', 0) >= 0.95: continue
    cf = p['cf']
    if abs(cf[0] - cx) > R or abs(cf[2] - cz) > R: continue
    sx, sy, sz = [v / 2 for v in p['s']]
    if str(p.get('p', '')).endswith('Tree'):
        # tree MeshParts carry their whole mesh's bounds: draw a slim trunk and a crown
        if 'Trunk' in p['n']:
            sx, sz = 0.8, 0.8; col = (0.2, 0.12, 0.06)
        else:
            sx, sy, sz = sx * 0.55, sy * 0.6, sz * 0.55; col = (0.08, 0.25, 0.07)
    if p['shape'] == 'Wedge':
        v = [world(cf, *l) for l in [(-sx,-sy,-sz),(sx,-sy,-sz),(-sx,-sy,sz),(sx,-sy,sz),(-sx,sy,sz),(sx,sy,sz)]]
        for fi in [(0,2,3,1),(2,4,5,3),(0,1,5,4),(0,4,2),(1,3,5)]:
            face([v[i] for i in fi], col)
        continue
    v = [world(cf, a, b, cc) for a in (-sx, sx) for b in (-sy, sy) for cc in (-sz, sz)]
    for fi in BOX:
        face([v[i] for i in fi], col)

me = bpy.data.meshes.new("scene")
me.from_pydata(verts, [], faces)
me.update()
attr = me.color_attributes.new("Col", 'FLOAT_COLOR', 'CORNER')
k = 0
for fi, poly in enumerate(me.polygons):
    for li in poly.loop_indices:
        attr.data[li].color = (*cols[fi], 1)
ob = bpy.data.objects.new("scene", me)
bpy.context.scene.collection.objects.link(ob)

# --- camera + look ------------------------------------------------------------------
gy = float(sys.argv[10]) if len(sys.argv) > 10 else hts.get((round((cx // 4) * 4), round((cz // 4) * 4)), 10)
tgt = B(cx, gy, cz)
cam_d = bpy.data.cameras.new("cam"); cam_d.lens = 35; cam_d.clip_end = 5000
cam = bpy.data.objects.new("cam", cam_d); bpy.context.scene.collection.objects.link(cam)
cam.location = (tgt[0] + dist * math.cos(pitch) * math.sin(yaw), tgt[1] - dist * math.cos(pitch) * math.cos(yaw), tgt[2] + dist * math.sin(pitch))
d = (tgt[0] - cam.location[0], tgt[1] - cam.location[1], tgt[2] - cam.location[2])
cam.rotation_euler = (math.atan2(math.hypot(d[0], d[1]), -d[2]), 0, math.atan2(d[1], d[0]) - math.pi / 2)
sc = bpy.context.scene
sc.camera = cam
sc.render.engine = 'CYCLES'
sc.cycles.device = 'CPU'; sc.cycles.samples = 24; sc.cycles.use_denoising = True
sc.cycles.max_bounces = 3
mat = bpy.data.materials.new("vc"); mat.use_nodes = True
nt = mat.node_tree; bsdf = nt.nodes["Principled BSDF"]
ca = nt.nodes.new("ShaderNodeVertexColor"); ca.layer_name = "Col"
nt.links.new(ca.outputs["Color"], bsdf.inputs["Base Color"])
bsdf.inputs["Roughness"].default_value = 0.9
me.materials.append(mat)
sun_d = bpy.data.lights.new("sun", 'SUN'); sun_d.energy = 3.2; sun_d.angle = math.radians(3)
sun = bpy.data.objects.new("sun", sun_d); bpy.context.scene.collection.objects.link(sun)
sun.rotation_euler = (math.radians(40), math.radians(15), math.radians(30))
world = bpy.data.worlds.new("W"); sc.world = world; world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.55, 0.65, 0.8, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 0.9
sc.view_settings.view_transform = 'Standard'
sc.render.resolution_x, sc.render.resolution_y = W, H
sc.render.filepath = out
sc.display_settings.display_device = 'sRGB'
bpy.ops.render.render(write_still=True)
print("wrote", out)
