#!/usr/bin/env python3
"""Voyager 视觉模型的几何分析与语义归并脚本。"""

import argparse
import json
import math
import sys
import tempfile
import zipfile
from pathlib import Path

import bpy
from mathutils import Vector


COMPONENT_IDS = (
    "Bus",
    "HighGainAntenna",
    "RTGBoom",
    "RTG_1",
    "RTG_2",
    "RTG_3",
    "MagnetometerBoom",
    "ScienceBoom",
    "ScanPlatform",
    "Thrusters",
    "Instrument_CRS",
    "Instrument_LECP",
    "Instrument_PLS",
    "Instrument_MAG",
    "Instrument_PWS",
)

REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCE_GLB = REPO_ROOT / "assets/source/Voyager.glb"
PRINTABLE_ZIP = REPO_ROOT / "assets/source/Voyager_printable.zip"
GENERATED_DIR = REPO_ROOT / "assets/generated"
ANALYSIS_JSON = GENERATED_DIR / "parts_analysis.json"
ANALYSIS_MD = GENERATED_DIR / "parts_analysis.md"
MAPPING_JSON = REPO_ROOT / "tools/model/mapping.json"
OUTPUT_GLB = GENERATED_DIR / "Voyager2_rigged.glb"
EXCLUDED_REFERENCE_PARTS = {"pins", "stand"}


def rounded(value, digits=6):
    """统一压缩浮点噪声，保证报告容易比较。"""
    if abs(value) < 10 ** (-digits):
        return 0.0
    return round(value, digits)


def vector_list(vector):
    return [rounded(value) for value in vector]


def clear_scene():
    """清空 Blender 默认场景和上一次导入的对象。"""
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.meshes, bpy.data.curves, bpy.data.materials):
        for datablock in list(datablocks):
            if datablock.users == 0:
                datablocks.remove(datablock)


def import_glb():
    if not SOURCE_GLB.is_file():
        raise FileNotFoundError(f"找不到源模型：{SOURCE_GLB}")
    clear_scene()
    bpy.ops.import_scene.gltf(filepath=str(SOURCE_GLB))
    mesh_objects = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
    if not mesh_objects:
        raise RuntimeError("Voyager.glb 导入后没有 Mesh 对象")
    return mesh_objects


def separate_loose_parts(mesh_objects):
    """逐对象按几何连通性拆开，并产生稳定的体积排序名称。"""
    for obj in list(mesh_objects):
        bpy.ops.object.select_all(action="DESELECT")
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_all(action="SELECT")
        bpy.ops.mesh.separate(type="LOOSE")
        bpy.ops.object.mode_set(mode="OBJECT")

    parts = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
    measured = [(obj, measure_object(obj)) for obj in parts]
    measured.sort(
        key=lambda item: (
            -item[1]["bbox_volume"],
            item[1]["centroid"],
            -item[1]["vertex_count"],
            -item[1]["face_count"],
        )
    )
    for index, (obj, _) in enumerate(measured):
        obj.name = f"part_{index:04d}"
        obj.data.name = f"part_{index:04d}_mesh"
    return [obj for obj, _ in measured]


def world_vertices(obj):
    matrix = obj.matrix_world
    return [matrix @ vertex.co for vertex in obj.data.vertices]


def bounds_from_points(points):
    if not points:
        zero = Vector((0.0, 0.0, 0.0))
        return zero, zero
    minimum = Vector((math.inf, math.inf, math.inf))
    maximum = Vector((-math.inf, -math.inf, -math.inf))
    for point in points:
        for axis in range(3):
            minimum[axis] = min(minimum[axis], point[axis])
            maximum[axis] = max(maximum[axis], point[axis])
    return minimum, maximum


def triangle_area(a, b, c):
    return ((b - a).cross(c - a)).length * 0.5


def measure_object(obj):
    """计算一个 Mesh 在世界坐标中的客观几何特征。"""
    mesh = obj.data
    points = world_vertices(obj)
    minimum, maximum = bounds_from_points(points)
    size = maximum - minimum
    centroid = sum(points, Vector()) / len(points) if points else Vector()
    bbox_volume = size.x * size.y * size.z
    max_size = max(size) if points else 0.0
    min_size = min(size) if points else 0.0
    longest_axis_index = max(range(3), key=lambda axis: size[axis]) if points else 0

    mesh.calc_loop_triangles()
    matrix = obj.matrix_world
    surface_area = 0.0
    for triangle in mesh.loop_triangles:
        a, b, c = (matrix @ mesh.vertices[index].co for index in triangle.vertices)
        surface_area += triangle_area(a, b, c)

    used_material_indices = sorted({polygon.material_index for polygon in mesh.polygons})
    used_materials = []
    for material_index in used_material_indices:
        if material_index < len(obj.material_slots):
            material = obj.material_slots[material_index].material
            if material:
                used_materials.append(material.name)

    return {
        "name": obj.name,
        "bbox_min": vector_list(minimum),
        "bbox_max": vector_list(maximum),
        "size": vector_list(size),
        "centroid": vector_list(centroid),
        "vertex_count": len(mesh.vertices),
        "face_count": len(mesh.polygons),
        "surface_area": rounded(surface_area),
        "bbox_volume": rounded(bbox_volume),
        "longest_axis": "XYZ"[longest_axis_index],
        "flatness": rounded(min_size / max_size) if max_size else 0.0,
        "materials": used_materials,
    }


def measure_overall(objects):
    points = []
    for obj in objects:
        points.extend(world_vertices(obj))
    minimum, maximum = bounds_from_points(points)
    size = maximum - minimum
    center = (minimum + maximum) * 0.5
    return {
        "bbox_min": vector_list(minimum),
        "bbox_max": vector_list(maximum),
        "size": vector_list(size),
        "center": vector_list(center),
    }


def import_stl(filepath):
    """兼容 Blender 4.x/5.x 与旧版 STL 导入操作符。"""
    before = set(bpy.context.scene.objects)
    if hasattr(bpy.ops.wm, "stl_import"):
        bpy.ops.wm.stl_import(filepath=str(filepath))
    else:
        bpy.ops.import_mesh.stl(filepath=str(filepath))
    return [
        obj
        for obj in bpy.context.scene.objects
        if obj not in before and obj.type == "MESH"
    ]


def analyze_printable_reference():
    if not PRINTABLE_ZIP.is_file():
        raise FileNotFoundError(f"找不到打印参考模型：{PRINTABLE_ZIP}")

    clear_scene()
    references = []
    imported_objects = []
    with tempfile.TemporaryDirectory(prefix="voyager_printable_") as temp_dir:
        with zipfile.ZipFile(PRINTABLE_ZIP) as archive:
            archive.extractall(temp_dir)
        stl_files = sorted(Path(temp_dir).rglob("*.stl"))
        for stl_file in stl_files:
            if stl_file.stem.lower() in EXCLUDED_REFERENCE_PARTS:
                continue
            objects = import_stl(stl_file)
            if not objects:
                raise RuntimeError(f"STL 导入后没有 Mesh 对象：{stl_file.name}")
            if len(objects) > 1:
                raise RuntimeError(f"STL 意外导入为多个 Mesh：{stl_file.name}")
            obj = objects[0]
            obj.name = stl_file.stem
            measurement = measure_object(obj)
            measurement["name"] = stl_file.stem
            references.append(measurement)
            imported_objects.append(obj)

    references.sort(key=lambda item: item["name"])
    return references, measure_overall(imported_objects)


def comparison_hint(glb_overall, reference_overall):
    scale_ratio = []
    for glb_size, reference_size in zip(glb_overall["size"], reference_overall["size"]):
        scale_ratio.append(rounded(glb_size / reference_size) if reference_size else None)
    center_offset = [
        rounded(glb_center - reference_center)
        for glb_center, reference_center in zip(
            glb_overall["center"], reference_overall["center"]
        )
    ]
    return {
        "glb_size_divided_by_reference_size_per_axis": scale_ratio,
        "glb_center_minus_reference_center": center_offset,
        "note": "仅供人工对照；两个模型可能尺度与朝向不同，未执行自动对齐。",
    }


def markdown_vector(values):
    return "(" + ", ".join(f"{value:.6g}" for value in values) + ")"


def write_markdown(report):
    lines = [
        "# Voyager GLB 松散块量化报告",
        "",
        f"共分离出 **{len(report['parts'])}** 个几何独立块。下表按包围盒体积从大到小排序。",
        "",
        "体积采用世界坐标轴对齐包围盒体积；质心采用世界坐标下所有顶点的算术平均值。报告不包含任何组件命名猜测。",
        "",
        "| 排名 | 零件名 | 尺寸 (X, Y, Z) | 质心 (X, Y, Z) | 顶点 | 面 | 表面积 | 包围盒体积 | 最长轴 | 扁平度 | 材质 |",
        "| ---: | --- | --- | --- | ---: | ---: | ---: | ---: | :---: | ---: | --- |",
    ]
    for rank, part in enumerate(report["parts"], start=1):
        materials = ", ".join(part["materials"]) or "—"
        lines.append(
            f"| {rank} | `{part['name']}` | {markdown_vector(part['size'])} | "
            f"{markdown_vector(part['centroid'])} | {part['vertex_count']} | "
            f"{part['face_count']} | {part['surface_area']:.6g} | "
            f"{part['bbox_volume']:.6g} | {part['longest_axis']} | "
            f"{part['flatness']:.6g} | {materials} |"
        )

    lines.extend(
        [
            "",
            "## 打印版空间参考",
            "",
            "`pins.stl` 和 `stand.stl` 已排除；它们是打印榫钉和底座，不属于真实航天器。",
            "",
            "| 参考件 | 尺寸 (X, Y, Z) | 质心 (X, Y, Z) | 包围盒体积 |",
            "| --- | --- | --- | ---: |",
        ]
    )
    for reference in report["reference"]["parts"]:
        lines.append(
            f"| `{reference['name']}` | {markdown_vector(reference['size'])} | "
            f"{markdown_vector(reference['centroid'])} | {reference['bbox_volume']:.6g} |"
        )

    comparison = report["comparison_hint"]
    lines.extend(
        [
            "",
            "## 整体对照提示",
            "",
            f"- GLB 整体尺寸：{markdown_vector(report['glb']['overall']['size'])}",
            f"- 打印版整体尺寸：{markdown_vector(report['reference']['overall']['size'])}",
            "- GLB / 打印版逐轴尺寸比例："
            f"{markdown_vector(comparison['glb_size_divided_by_reference_size_per_axis'])}",
            "- GLB 中心减打印版中心："
            f"{markdown_vector(comparison['glb_center_minus_reference_center'])}",
            f"- {comparison['note']}",
            "",
        ]
    )
    ANALYSIS_MD.write_text("\n".join(lines), encoding="utf-8")


def run_analyze():
    glb_objects = import_glb()
    parts = separate_loose_parts(glb_objects)
    measured_parts = [measure_object(obj) for obj in parts]
    measured_parts.sort(key=lambda item: item["bbox_volume"], reverse=True)
    glb_overall = measure_overall(parts)
    references, reference_overall = analyze_printable_reference()

    report = {
        "schema_version": 1,
        "measurement_space": "world",
        "volume_method": "axis_aligned_bounding_box",
        "glb": {"source": str(SOURCE_GLB.relative_to(REPO_ROOT)), "overall": glb_overall},
        "parts": measured_parts,
        "reference": {
            "source": str(PRINTABLE_ZIP.relative_to(REPO_ROOT)),
            "excluded": ["pins.stl", "stand.stl"],
            "overall": reference_overall,
            "parts": references,
        },
        "comparison_hint": comparison_hint(glb_overall, reference_overall),
    }
    GENERATED_DIR.mkdir(parents=True, exist_ok=True)
    ANALYSIS_JSON.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    write_markdown(report)
    print(f"分析完成：{len(measured_parts)} 个松散块")
    print(f"JSON：{ANALYSIS_JSON}")
    print(f"Markdown：{ANALYSIS_MD}")


def load_mapping():
    if not MAPPING_JSON.is_file():
        raise FileNotFoundError(f"找不到映射文件：{MAPPING_JSON}")
    data = json.loads(MAPPING_JSON.read_text(encoding="utf-8"))
    raw_mappings = data.get("parts")
    if not isinstance(raw_mappings, dict):
        raise ValueError("mapping.json 的 parts 必须是对象")

    mappings = {}
    parents = {}
    for part_key, value in raw_mappings.items():
        if part_key.startswith("_"):
            continue
        if isinstance(value, str):
            component = value
            parent = None
        elif isinstance(value, dict):
            component = value.get("component")
            parent = value.get("parent")
        else:
            raise ValueError(f"零件 {part_key!r} 的映射必须是字符串或对象")
        if not isinstance(component, str) or not component:
            raise ValueError(f"零件 {part_key!r} 缺少有效的 component")
        mappings[part_key] = component
        if parent is not None:
            if not isinstance(parent, str) or not parent:
                raise ValueError(f"零件 {part_key!r} 的 parent 无效")
            previous = parents.get(component)
            if previous is not None and previous != parent:
                raise ValueError(
                    f"组件 {component} 出现冲突 parent：{previous!r} 与 {parent!r}"
                )
            parents[component] = parent
    return mappings, parents


def validate_mapping(mappings, available_parts):
    mapped_components = set(mappings.values())
    expected_components = set(COMPONENT_IDS)
    missing = sorted(expected_components - mapped_components)
    unexpected = sorted(mapped_components - expected_components)
    if missing or unexpected:
        differences = ["mapping.json 的 ComponentID 与 AllComponents 不一致："]
        if missing:
            differences.append("  缺失：" + ", ".join(missing))
        if unexpected:
            differences.append("  未知：" + ", ".join(unexpected))
        raise ValueError("\n".join(differences))

    normalized = {}
    available_names = {obj.name for obj in available_parts}
    for part_key, component in mappings.items():
        normalized_key = part_key
        if part_key.isdigit():
            normalized_key = f"part_{int(part_key):04d}"
        if normalized_key not in available_names:
            raise ValueError(f"映射引用了不存在的松散块：{part_key!r}")
        normalized[normalized_key] = component

    unmapped = sorted(available_names - set(normalized))
    if unmapped:
        raise ValueError("以下松散块尚未映射：" + ", ".join(unmapped))
    return normalized


def join_component_objects(component, objects):
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    active = objects[0]
    bpy.context.view_layer.objects.active = active
    if len(objects) > 1:
        bpy.ops.object.join()
    active.name = component
    active.data.name = f"{component}_mesh"
    return active


def set_parent_keep_world(child, parent):
    world_matrix = child.matrix_world.copy()
    child.parent = parent
    child.matrix_world = world_matrix


def print_tree(obj, depth=0):
    object_type = "Empty" if obj.type == "EMPTY" else obj.type
    print(f"{'  ' * depth}- {obj.name} [{object_type}]")
    for child in sorted(obj.children, key=lambda item: item.name):
        print_tree(child, depth + 1)


def run_apply():
    mappings, configured_parents = load_mapping()
    glb_objects = import_glb()
    parts = separate_loose_parts(glb_objects)
    mappings = validate_mapping(mappings, parts)

    grouped = {component: [] for component in COMPONENT_IDS}
    by_name = {obj.name: obj for obj in parts}
    for part_name, component in mappings.items():
        grouped[component].append(by_name[part_name])

    component_objects = {
        component: join_component_objects(component, grouped[component])
        for component in COMPONENT_IDS
    }

    root = bpy.data.objects.new("Voyager2", None)
    bpy.context.scene.collection.objects.link(root)
    for component_obj in component_objects.values():
        set_parent_keep_world(component_obj, root)

    for rtg_name in ("RTG_1", "RTG_2", "RTG_3"):
        set_parent_keep_world(component_objects[rtg_name], component_objects["RTGBoom"])

    instrument_names = {
        "Instrument_CRS",
        "Instrument_LECP",
        "Instrument_PLS",
        "Instrument_MAG",
        "Instrument_PWS",
    }
    for component, parent_name in configured_parents.items():
        if component not in instrument_names:
            raise ValueError(f"只有 Instrument_* 允许配置 parent，实际为：{component}")
        if parent_name not in {"ScanPlatform", "ScienceBoom"}:
            raise ValueError(
                f"{component} 的 parent 必须是 ScanPlatform 或 ScienceBoom，实际为：{parent_name}"
            )
        set_parent_keep_world(component_objects[component], component_objects[parent_name])

    bpy.ops.object.select_all(action="DESELECT")
    root.select_set(True)
    for component_obj in component_objects.values():
        component_obj.select_set(True)
    bpy.context.view_layer.objects.active = root
    GENERATED_DIR.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=str(OUTPUT_GLB),
        export_format="GLB",
        use_selection=True,
        export_materials="EXPORT",
        export_image_format="AUTO",
        export_yup=True,
        export_apply=True,
    )
    print(f"导出完成：{OUTPUT_GLB}")
    print("导出节点树：")
    print_tree(root)


def parse_args():
    parser = argparse.ArgumentParser(description="Voyager 模型拆分与语义归并")
    parser.add_argument("command", choices=("analyze", "apply"))
    arguments = sys.argv
    if "--" in arguments:
        arguments = arguments[arguments.index("--") + 1 :]
    else:
        arguments = []
    return parser.parse_args(arguments)


def main():
    args = parse_args()
    if args.command == "analyze":
        run_analyze()
    else:
        run_apply()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"错误：{error}", file=sys.stderr)
        raise SystemExit(1) from error
