"""把 NASA 官方 Voyager 视觉 glTF 拆成带语义层级的组件树。

背景：NASA 的 Voyager.glb 只有 4 个节点，且是按贴图切分的，里面完全没有
RTG / 天线 / 桁架这些语义对象。按松散块分离会得到 3213 个连通块，其中 1831 块
体积不到总量的 0.001%，所以「零件 → 组件」一一映射不可行。

本脚本改用空间规则归类：模型是真实尺度（碟直径 3.79 单位 ≈ 真机 3.7 m，
即 1 单位 ≈ 1 米），因此可以直接用真实航天器的几何布局来判定归属。

坐标系（Blender 导入 glTF 后，Y-up 已转为 Z-up）：
    +Z  碟面法向（高增益天线指向）
    +Y  科学桁架 → 扫描平台与光学仪器
    -Y  RTG 桁架（Z≈-0.5..1）
    -Y 且 +Z 抬升  磁强计桁架（13 m 格构，末端 (0,-12.66,8.85)）
    ±X  两根 PRA/PWS 鞭状天线（brass 材质）

用法：
    blender --background --factory-startup --python tools/model/assign.py -- \
        --mode validate --outdir assets/generated
    blender --background --factory-startup --python tools/model/assign.py -- \
        --mode export --outdir assets/generated
"""

import argparse
import json
import math
import os
import sys

import bpy
import mathutils

SOURCE_GLB = "assets/source/Voyager.glb"

# 必须与 internal/domain/domain.go 的 AllComponents 逐字一致。
# 这是 Blender 导出 / Godot 场景树 / 后端组件状态三方的契约。
COMPONENTS = [
    "Bus", "HighGainAntenna",
    "RTGBoom", "RTG_1", "RTG_2", "RTG_3",
    "MagnetometerBoom", "ScienceBoom", "ScanPlatform", "Thrusters",
    "Instrument_CRS", "Instrument_LECP", "Instrument_PLS",
    "Instrument_MAG", "Instrument_PWS",
]

# 该视觉模型**不区分**的组件 -> 实际承载它们几何的节点。
#
# 后端仍然需要这些 ComponentID 可寻址（每台仪器有独立的遥测/状态），但模型里
# 没有对应的独立几何。与其编造三个假节点，不如把事实记录下来：Godot 侧点选
# 这三个 ID 中的任何一个，都高亮 ScienceBoom，并在 UI 上注明模型未区分。
UNRESOLVED = {
    "Instrument_CRS": "ScienceBoom",
    "Instrument_LECP": "ScienceBoom",
    "Instrument_PLS": "ScienceBoom",
}

# 实际会被导出为独立节点的组件。
RESOLVED = [c for c in COMPONENTS if c not in UNRESOLVED]

# 层级：子组件 -> 父组件。未列出的直接挂在 Voyager2 根下。
PARENTS = {
    "RTG_1": "RTGBoom", "RTG_2": "RTGBoom", "RTG_3": "RTGBoom",
    "Instrument_MAG": "MagnetometerBoom",
    "Instrument_CRS": "ScienceBoom",
    "Instrument_LECP": "ScienceBoom",
    "Instrument_PLS": "ScienceBoom",
    "Instrument_PWS": "Bus",
    "ScanPlatform": "ScienceBoom",
}

# 校验渲染用的配色（RGB）。
COLORS = {
    "Bus": (0.85, 0.85, 0.85), "HighGainAntenna": (1.0, 1.0, 1.0),
    "RTGBoom": (0.35, 0.20, 0.05), "RTG_1": (1.0, 0.25, 0.15),
    "RTG_2": (1.0, 0.55, 0.10), "RTG_3": (1.0, 0.85, 0.10),
    "MagnetometerBoom": (0.10, 0.45, 1.0), "ScienceBoom": (0.15, 0.85, 0.35),
    "ScanPlatform": (0.05, 0.95, 0.85), "Thrusters": (1.0, 0.10, 0.85),
    "Instrument_CRS": (0.60, 0.20, 1.0), "Instrument_LECP": (0.35, 0.10, 0.75),
    "Instrument_PLS": (0.80, 0.55, 1.0), "Instrument_MAG": (0.55, 0.90, 1.0),
    "Instrument_PWS": (0.95, 0.80, 0.35), "_EXCLUDED": (0.25, 0.25, 0.25),
}

# 磁强计桁架轴线：从桁架根部到实测末端。
BOOM_ROOT = mathutils.Vector((0.0, -2.30, 0.55))
BOOM_TIP = mathutils.Vector((0.0, -12.66, 8.85))


def dist_to_segment(p, a, b):
    """点到线段的最短距离。"""
    ab = b - a
    t = max(0.0, min(1.0, (p - a).dot(ab) / ab.length_squared))
    return (p - (a + ab * t)).length


def classify(centroid, size, materials):
    """按空间规则判定组件归属，返回 (ComponentID, 置信度说明)。"""
    x, y, z = centroid
    r_xy = math.hypot(x, y)
    p = mathutils.Vector(centroid)

    # 原点处的 1x1x1 clear 立方体是 glTF 里的辅助盒，不是航天器几何。
    if "clear" in materials:
        return "_EXCLUDED", "glTF 辅助包围盒，非航天器部件"

    # brass 只用在两根 PRA/PWS 鞭状天线上，材质即身份，最可靠。
    if "brass" in materials:
        return "Instrument_PWS", "高：brass 材质专用于 PRA/PWS 鞭状天线"

    d_boom = dist_to_segment(p, BOOM_ROOT, BOOM_TIP)
    d_tip = (p - BOOM_TIP).length

    # 桁架末端的磁强计传感器。
    if d_tip < 1.10:
        return "Instrument_MAG", "高：位于 13 m 桁架末端，即磁强计传感器位置"

    # 13 m 格构桁架本体：极细（|X|<0.45）且贴合轴线。
    #
    # 早期版本这里额外要求 (y < -3.0 or z > 2.6)，结果桁架根部那段
    # （约 y=-2.3, z=0.55）两个条件都不满足，掉进下面的 RTG 规则被染成
    # RTGBoom —— 彩色校验图里根部泛棕色就是这个 bug。轴线距离本身已足够
    # 区分：在 y=-4 处桁架轴线已抬升到 z≈1.91，而 RTG 单元都在 z<1.15，
    # 两者最近距离 >0.76，远大于 0.45 的阈值。
    if d_boom < 0.45 and abs(x) < 0.45:
        return "MagnetometerBoom", "高：贴合桁架轴线且 X 向极细，符合格构杆件"

    # 高增益天线：碟面 + 馈源，绕 Z 轴回转、位于碟高度区间。
    if r_xy < 2.05 and 0.52 <= z <= 2.45:
        return "HighGainAntenna", "高：以 Z 轴为回转轴、直径 3.79 m，与真机 3.7 m 碟一致"

    # RTG 组件：-Y 侧、低于碟面、排除桁架。
    if y < -1.95 and -0.90 <= z <= 1.15 and abs(x) < 1.20:
        # 三个 RTG 单元沿 Y 一字排开，按 Y 三等分。
        if y <= -2.55:
            span_lo, span_hi = -4.70, -2.55
            frac = (y - span_lo) / (span_hi - span_lo)
            idx = min(3, max(1, int(frac * 3) + 1))
            return f"RTG_{4 - idx}", "中：三单元沿 Y 一字排开，按实测跨度三等分"
        return "RTGBoom", "中：位于 RTG 侧、三单元与舱体之间，判为支撑桁架"

    # 扫描平台：+Y 最远端的仪器簇。
    if y > 3.05:
        return "ScanPlatform", "高：+Y 最远端仪器簇，即可转扫描平台"

    # 科学桁架及其上的粒子仪器。
    #
    # 实测：把 y∈(1.15,3.15) 区间的 357 块按质心邻近（0.22 m）做单链接聚类，
    # 结果是 350 块聚成**一个**连通体，只剩 4 个零散小块。也就是说 CRS / LECP /
    # PLS 在这个视觉模型里不是独立几何，而是一坨连在一起的桁架仪器组合。
    # 早期版本按 Y/Z/X 硬切成三份是凭空编造的，已删除 —— 见 UNRESOLVED。
    if y > 1.30:
        return "ScienceBoom", "中：+Y 侧桁架及其仪器组合体"

    # 姿控推力器：舱体下方的小型簇。
    if z < -0.75 and r_xy < 1.30:
        return "Thrusters", "中：舱体下方小型簇，符合姿控推力器安装位置"

    # 其余归入主舱体。
    return "Bus", "中：十边形主舱体及其附属结构（兜底归类）"


def loose_split():
    """导入 glb 并按松散块分离，返回 mesh 对象列表。"""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=SOURCE_GLB)
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    bpy.ops.object.select_all(action="DESELECT")
    for o in meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.separate(type="LOOSE")
    bpy.ops.object.mode_set(mode="OBJECT")
    return [o for o in bpy.data.objects if o.type == "MESH"]


def world_bbox(o):
    pts = [o.matrix_world @ mathutils.Vector(c) for c in o.bound_box]
    mn = [min(p[k] for p in pts) for k in range(3)]
    mx = [max(p[k] for p in pts) for k in range(3)]
    return mn, mx


def used_materials(o):
    """返回该块的面**实际引用**的材质名集合。

    注意：bpy.ops.mesh.separate(type='LOOSE') 会让每个分离出的对象继承母网格
    的完整材质槽列表。原始 tex_01 网格的槽是 ['tex_01', 'brass']，所以直接读
    o.data.materials 会让 3133 个碎块全都「带着」brass，把整台航天器误判成
    鞭状天线。必须按 polygon.material_index 取实际用到的槽。
    """
    slots = [m.name if m else "" for m in o.data.materials]
    if not slots:
        return set()
    used = set()
    for poly in o.data.polygons:
        idx = poly.material_index
        if 0 <= idx < len(slots) and slots[idx]:
            used.add(slots[idx])
    return used


def assign_all(parts):
    """对每个块判定归属，返回 {ComponentID: [obj]} 与统计。"""
    groups = {c: [] for c in COMPONENTS}
    groups["_EXCLUDED"] = []
    reasons = {}
    stats = {}
    for o in parts:
        mn, mx = world_bbox(o)
        centroid = tuple((mn[k] + mx[k]) / 2 for k in range(3))
        size = tuple(mx[k] - mn[k] for k in range(3))
        mats = used_materials(o)
        comp, why = classify(centroid, size, mats)
        groups[comp].append(o)
        reasons[comp] = why
    for c, objs in groups.items():
        verts = sum(len(o.data.vertices) for o in objs)
        stats[c] = {
            "parts": len(objs),
            "vertices": verts,
            "confidence_note": reasons.get(c, "未命中任何规则"),
        }
    return groups, stats


def paint_and_render(groups, outdir):
    """按组件着色并渲染四个正交视图，用于人工核对归类是否正确。"""
    for comp, objs in groups.items():
        if not objs:
            continue
        mat = bpy.data.materials.new(f"VAL_{comp}")
        mat.use_nodes = True
        bsdf = mat.node_tree.nodes["Principled BSDF"]
        r, g, b = COLORS.get(comp, (1, 0, 1))
        bsdf.inputs["Base Color"].default_value = (r, g, b, 1)
        bsdf.inputs["Roughness"].default_value = 0.55
        for o in objs:
            o.data.materials.clear()
            o.data.materials.append(mat)

    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = 12
    sc.render.resolution_x = 1000
    sc.render.resolution_y = 1000
    world = bpy.data.worlds.new("W")
    sc.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.04, 0.04, 0.05, 1)
    for pos in [(12, -12, 12), (-12, 10, 8), (0, 0, -14)]:
        light = bpy.data.lights.new("L", "SUN")
        light.energy = 4
        ob = bpy.data.objects.new("L", light)
        sc.collection.objects.link(ob)
        ob.location = pos
        ob.rotation_euler = (-mathutils.Vector(pos)).to_track_quat("Z", "Y").to_euler()

    cam_data = bpy.data.cameras.new("C")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = 19
    cam = bpy.data.objects.new("C", cam_data)
    sc.collection.objects.link(cam)
    sc.camera = cam
    target = mathutils.Vector((0, -4.25, 3.48))
    for name, pos in {
        "side": (40, -4.25, 3.48),
        "top": (0, -4.25, 40),
        "iso": (22, -26, 20),
    }.items():
        cam.location = pos
        cam.rotation_euler = (target - mathutils.Vector(pos)).to_track_quat("-Z", "Y").to_euler()
        sc.render.filepath = os.path.join(outdir, f"validate_{name}.png")
        bpy.ops.render.render(write_still=True)
        print("RENDERED", name)


def export_tree(groups, outdir):
    """合并每组为一个命名对象、建立层级并导出 glb。"""
    # 删除排除项。
    for o in groups.get("_EXCLUDED", []):
        bpy.data.objects.remove(o, do_unlink=True)

    merged = {}
    for comp in RESOLVED:
        objs = [o for o in groups[comp] if o.name in bpy.data.objects]
        if not objs:
            print(f"WARN 组件为空: {comp}")
            continue
        bpy.ops.object.select_all(action="DESELECT")
        for o in objs:
            o.select_set(True)
        bpy.context.view_layer.objects.active = objs[0]
        if len(objs) > 1:
            bpy.ops.object.join()
        obj = bpy.context.view_layer.objects.active
        obj.name = comp
        obj.data.name = comp
        merged[comp] = obj

    missing = [c for c in RESOLVED if c not in merged]
    if missing:
        raise SystemExit(f"契约校验失败：以下组件没有任何几何：{missing}")

    root = bpy.data.objects.new("Voyager2", None)
    bpy.context.scene.collection.objects.link(root)
    for comp, obj in merged.items():
        parent_name = PARENTS.get(comp)
        obj.parent = merged[parent_name] if parent_name in merged else root
        obj.matrix_parent_inverse = obj.parent.matrix_world.inverted()

    out = os.path.join(outdir, "Voyager2_rigged.glb")
    bpy.ops.export_scene.gltf(
        filepath=out, export_format="GLB",
        export_materials="EXPORT", export_yup=True, use_selection=False,
    )
    print("EXPORTED", out)

    def dump(o, depth=0):
        n = len(o.data.vertices) if o.type == "MESH" else 0
        print("TREE " + "  " * depth + f"- {o.name}" + (f" [{n} verts]" if n else ""))
        for c in o.children:
            dump(c, depth + 1)

    dump(root)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["validate", "export"], required=True)
    ap.add_argument("--outdir", default="assets/generated")
    args = ap.parse_args(argv)
    os.makedirs(args.outdir, exist_ok=True)

    parts = loose_split()
    print(f"LOOSE_PARTS {len(parts)}")
    groups, stats = assign_all(parts)

    print(f"{'组件':<20} {'块数':>6} {'顶点':>7}  置信度")
    for comp in RESOLVED + ["_EXCLUDED"]:
        st = stats[comp]
        print(f"STAT {comp:<20} {st['parts']:>6} {st['vertices']:>7}  {st['confidence_note']}")
    for comp, target in UNRESOLVED.items():
        print(f"ALIAS {comp:<19} -> {target}  （该视觉模型未区分此仪器）")

    with open(os.path.join(args.outdir, "assignment.json"), "w") as f:
        json.dump({"source": SOURCE_GLB, "total_parts": len(parts),
                   "components": stats, "parents": PARENTS,
                   "unresolved_in_model": UNRESOLVED}, f,
                  ensure_ascii=False, indent=1)

    if args.mode == "validate":
        paint_and_render(groups, args.outdir)
    else:
        export_tree(groups, args.outdir)


main()
