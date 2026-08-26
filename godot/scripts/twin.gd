## Voyager 2 数字孪生主控制器。整个场景在代码里构建。
##
## 两种视图，对应两套坐标尺度 —— 这是撤销「自编译 precision=double 引擎」
## 之后的正解：
##
##   SYSTEM  太阳系视图，1 AU = AU_UNITS 个单位。Voyager 现在约 143.8 AU，
##           即约 1438 单位。float32 在这个量级的量化误差约 1826 km，
##           换算到屏幕是 0.0000 像素，看不见。
##   CRAFT   探测器特写，1 单位 = 1 米。此时若仍用世界坐标，1826 km 的误差
##           会变成 13.2 像素的抖动，所以特写一律在探测器局部坐标系里渲染，
##           世界位置只用于计算显示数值。
extends Node3D

const AU_UNITS := 10.0
const PLANET_EXAGGERATION := 620.0
const SUN_RADIUS := 3.2

## 与 planet.gdshader 里的 kind 分支一一对应。
const KIND_ID := {
	"rocky": 0, "venus": 1, "earth": 2, "mars": 3, "gas": 4,
	"ice": 5, "io": 6, "europa": 7, "titan": 8, "triton": 9,
}
const TRAJECTORY_SAMPLES := 2400

enum ViewMode { SYSTEM, CRAFT }

# 太阳系视图里画轨道的天体（内行星在 49 年里会糊成一团，不画）。
const ORBIT_BODIES := ["jupiter", "saturn", "uranus", "neptune"]
const PLANET_COLORS := {
	"mercury": Color(0.62, 0.60, 0.57), "venus": Color(0.90, 0.82, 0.62),
	"earth": Color(0.29, 0.53, 0.79), "mars": Color(0.78, 0.42, 0.28),
	"jupiter": Color(0.80, 0.68, 0.53), "saturn": Color(0.87, 0.79, 0.60),
	"uranus": Color(0.56, 0.79, 0.83), "neptune": Color(0.31, 0.45, 0.78),
	"io": Color(0.85, 0.80, 0.45), "europa": Color(0.80, 0.78, 0.72),
	"ganymede": Color(0.62, 0.58, 0.54), "callisto": Color(0.45, 0.42, 0.40),
	"titan": Color(0.83, 0.66, 0.36), "miranda": Color(0.65, 0.65, 0.68),
	"triton": Color(0.72, 0.75, 0.78),
}

var eph: Ephemeris
var mode: ViewMode = ViewMode.SYSTEM
var jd_now := 0.0
var jd_min := 0.0
var jd_max := 0.0
var playing := false
var play_days_per_sec := 60.0
var fatal_error := ""

# 太阳系视图
var system_root: Node3D
var planet_nodes := {}
var planet_spin := {}
var saturn_rings: MeshInstance3D
var probe_marker: MeshInstance3D
var probe_root: Node3D
var probe_model: Node3D
var corona: MeshInstance3D
var sun_light: DirectionalLight3D
var traveled_mesh: MeshInstance3D
var camera: Camera3D
var cam_yaw := 0.6
var cam_pitch := 0.5
var cam_dist := 2600.0

# 探测器视图
var craft_root: Node3D
var craft_model: Node3D
var component_nodes := {}
var selected_component := ""
var highlight_material: StandardMaterial3D
var original_materials := {}

# UI
var ui: Control
var lbl_date: Label
var lbl_readout: RichTextLabel
var lbl_component: RichTextLabel
var lbl_dsn: Label
var slider: HSlider
var btn_play: Button
var btn_mode: Button
var dsn_request: HTTPRequest
var dsn_active_craft: Array = []

# 右栏：测控几何 / 链路预算 / 轨道
var lbl_tracking: RichTextLabel
var lbl_link: RichTextLabel
var lbl_orbit: RichTextLabel
var spark_dist: Sparkline
var spark_power: Sparkline
var spark_rx: Sparkline

# 金唱片
var record_node: MeshInstance3D
var record_orig_xform: Transform3D
var record_spin_axis := Vector3.RIGHT
var record_center := Vector3.ZERO
var record_angle := 0.0
var record_spinning := false
var lbl_record: RichTextLabel
var record_panel: PanelContainer
var audio: AudioStreamPlayer
var audio_queue: PackedVector2Array = PackedVector2Array()
var audio_cursor := 0

# 太阳系视图里的地球连线（DSN 链路那条线）
var link_line: MeshInstance3D
var craft_focus := Vector3.ZERO
var _drag_travel := 0.0
var _shot_focus_probe := false
var _shot_focus_sun := false
var _shot_focus_body := ""
var _syncing_slider := false


func _ready() -> void:
	eph = Ephemeris.new()
	var err := eph.load_bundle("res://data/metadata.json", "res://data/ephemeris.bin")
	if err != "":
		fatal_error = err
		_build_ui()
		push_error("数据包加载失败: " + err)
		return

	var span := eph.jd_span()
	jd_min = span[0]
	jd_max = span[1]
	jd_now = jd_max

	_build_environment()
	_build_system_view()
	_build_craft_view()
	_build_ui()
	_set_mode(ViewMode.SYSTEM)
	_build_series()
	_refresh()

	if "--shots" in OS.get_cmdline_user_args():
		_run_screenshot_harness.call_deferred()
	if "--dsntest" in OS.get_cmdline_user_args():
		_run_dsn_selftest.call_deferred()
	if "--picktest" in OS.get_cmdline_user_args():
		_run_pick_selftest.call_deferred()
	if "--attitudetest" in OS.get_cmdline_user_args():
		_run_attitude_selftest.call_deferred()
	print("孪生体就绪：%d 天体，%d 组件，时间跨度 %s .. %s" % [
		eph.bodies.size(), eph.components.size(),
		JDTime.format_date_short(jd_min), JDTime.format_date_short(jd_max)])


func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.015, 0.017, 0.028)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.30, 0.32, 0.38)
	env.ambient_light_energy = 0.55
	# 辉光：让日面和日冕真正溢出边缘。HDR 阈值调低一点，否则程序化太阳
	# 的高光进不了 bloom 通道，看起来还是个贴纸。
	env.glow_enabled = true
	env.glow_intensity = 0.95
	# glow_bloom 必须是 0：它给**整幅画面**无条件加辉光，不看阈值。
	# 早先设成 0.28，结果木星被糊成 (251,245,233) 的白球，条带全被冲掉。
	# 只有 glow_hdr_threshold 才是「够亮才发光」的那个开关。
	env.glow_bloom = 0.0
	env.glow_strength = 1.0
	env.glow_hdr_threshold = 1.05
	env.glow_hdr_scale = 2.4
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	for i in 5:
		env.set("glow_levels/%d" % (i + 1), 1.0 if i < 4 else 0.5)
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_white = 3.0
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	camera = Camera3D.new()
	camera.far = 60000.0
	camera.near = 0.05
	add_child(camera)


func _build_system_view() -> void:
	system_root = Node3D.new()
	system_root.name = "SystemView"
	add_child(system_root)

	# 太阳。半径不按真实比例 —— 真实比例下它在这个尺度里只有 0.05 个单位。
	var sun := MeshInstance3D.new()
	var sun_mesh := SphereMesh.new()
	sun_mesh.radius = SUN_RADIUS
	sun_mesh.height = SUN_RADIUS * 2.0
	sun_mesh.radial_segments = 64
	sun_mesh.rings = 32
	sun.mesh = sun_mesh
	var sun_mat := ShaderMaterial.new()
	sun_mat.shader = load("res://shaders/sun_surface.gdshader")
	sun.material_override = sun_mat
	system_root.add_child(sun)

	# 日冕与日珥：一块正对相机的公告板，加法混合叠在日面外围。
	corona = MeshInstance3D.new()
	var cq := QuadMesh.new()
	cq.size = Vector2(SUN_RADIUS * 7.0, SUN_RADIUS * 7.0)
	corona.mesh = cq
	var cmat := ShaderMaterial.new()
	cmat.shader = load("res://shaders/sun_corona.gdshader")
	cmat.set_shader_parameter("disc_radius", SUN_RADIUS / (SUN_RADIUS * 3.5))
	corona.material_override = cmat
	corona.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	system_root.add_child(corona)

	for b in eph.bodies:
		var name_str: String = b["name"]
		if bool(b["is_spacecraft"]):
			continue
		var radius_units := clampf(
			float(b["mean_radius_km"]) / eph.au_km * AU_UNITS * PLANET_EXAGGERATION, 0.5, 8.0)

		# 三层结构：pivot 定位 / tilt 摆自转轴 / mesh 自转。
		# 环必须挂在 tilt 下面，因为环位于行星赤道面内，跟着自转轴一起倾斜。
		var pivot := Node3D.new()
		pivot.name = name_str
		system_root.add_child(pivot)

		var tilt := Node3D.new()
		# 对轨道倾角。天王星 97.8° —— 它基本是躺着转的。
		tilt.rotation_degrees = Vector3(0, 0, float(BodyData.OBLIQUITY.get(name_str, 0.0)))
		pivot.add_child(tilt)

		var node := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = radius_units
		mesh.height = radius_units * 2.0
		mesh.radial_segments = 48
		mesh.rings = 24
		node.mesh = mesh
		var col: Color = PLANET_COLORS.get(name_str, Color(0.7, 0.7, 0.7))
		var mat := ShaderMaterial.new()
		mat.shader = load("res://shaders/planet.gdshader")
		mat.set_shader_parameter("base_color", col)
		mat.set_shader_parameter("kind", KIND_ID.get(String(BodyData.KIND.get(name_str, "rocky")), 0))
		var atmo: Dictionary = BodyData.ATMOSPHERE.get(name_str, {})
		mat.set_shader_parameter("atmo_color", atmo.get("color", Color(0.5, 0.7, 1.0)))
		mat.set_shader_parameter("atmo_power", float(atmo.get("power", 0.0)))
		match name_str:
			"jupiter":
				mat.set_shader_parameter("band_tint", Color(0.62, 0.38, 0.24))
				mat.set_shader_parameter("band_freq", 11.0)
				# 大红斑：一个跨了几百年的反气旋。
				mat.set_shader_parameter("spot_size", 0.30)
				mat.set_shader_parameter("spot_color", Color(0.80, 0.34, 0.20))
			"saturn":
				mat.set_shader_parameter("band_tint", Color(0.72, 0.56, 0.34))
				mat.set_shader_parameter("band_freq", 8.0)
			"uranus":
				mat.set_shader_parameter("band_freq", 4.0)
			"neptune":
				mat.set_shader_parameter("band_freq", 6.0)
				# 大暗斑（1989 年旅行者 2 号拍到的那个，后来消失了）
				mat.set_shader_parameter("spot_size", 0.26)
				mat.set_shader_parameter("spot_lat", -0.42)
				mat.set_shader_parameter("spot_color", Color(0.10, 0.16, 0.42))
		node.material_override = mat
		tilt.add_child(node)

		planet_nodes[name_str] = pivot
		planet_spin[name_str] = node

		if name_str == "saturn":
			tilt.add_child(_build_saturn_rings(radius_units))

		if name_str in ORBIT_BODIES:
			system_root.add_child(_build_path_mesh(name_str, jd_min, jd_max,
				col.lerp(Color(0.35, 0.85, 1.0), 0.55), Color(0.55, 0.35, 1.0), 700,
				0.22, 0.0009, 2.0))

	# 探测器↔地球连线：这就是 DSN 上下行走的那条路径。
	link_line = MeshInstance3D.new()
	link_line.mesh = ImmediateMesh.new()
	link_line.extra_cull_margin = 100000.0
	link_line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	system_root.add_child(link_line)

	# 探测器用真实模型，不用色点。
	#
	# 尺度必须夸张：真机约 13 m，在 1 AU = 10 单位的尺度下是 8.7e-10 个单位,
	# 按真实比例渲染就是不存在。所以随相机距离等比放大，并在面板上注明这是
	# 示意尺寸。这跟行星的处理是一致的。
	probe_root = Node3D.new()
	probe_root.name = "Voyager2Probe"
	system_root.add_child(probe_root)

	# 太阳光。
	#
	# 行星走的是自照明 shader（unshaded），不吃场景灯光；但探测器模型用的是
	# glTF 自带的 StandardMaterial3D，没有光源就是一团黑 —— 删掉 OmniLight
	# 之后正是如此。这里补一盏平行光，每帧把方向对准「从太阳射向探测器」，
	# 于是探测器的受光面朝向太阳，和真实情形一致。
	# 用平行光而不是点光源，就是为了绕开距离衰减：140 AU 外任何点光源都归零。
	sun_light = DirectionalLight3D.new()
	sun_light.light_energy = 1.25
	sun_light.light_color = Color(1.0, 0.96, 0.88)
	sun_light.shadow_enabled = false
	system_root.add_child(sun_light)

	var probe_glb := load("res://assets/Voyager2_rigged.glb")
	if probe_glb != null:
		probe_model = probe_glb.instantiate()
		probe_root.add_child(probe_model)
		# 太阳系视图里探测器很小，关掉阴影省开销。
		for n in _all_meshes(probe_model):
			n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# 模型自带材质在远处会糊成一团，补一圈加法光晕便于定位。
	probe_marker = MeshInstance3D.new()
	var halo := QuadMesh.new()
	halo.size = Vector2(6.0, 6.0)
	probe_marker.mesh = halo
	var hmat := ShaderMaterial.new()
	hmat.shader = load("res://shaders/sun_corona.gdshader")
	hmat.set_shader_parameter("corona_color", Color(1.0, 0.42, 0.16))
	hmat.set_shader_parameter("prom_color", Color(1.0, 0.62, 0.30))
	hmat.set_shader_parameter("corona_falloff", 4.5)
	hmat.set_shader_parameter("prom_strength", 0.0)
	hmat.set_shader_parameter("disc_radius", 0.06)
	probe_marker.material_override = hmat
	probe_marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	probe_root.add_child(probe_marker)


func _all_meshes(node: Node) -> Array:
	var out := []
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		out.append_array(_all_meshes(c))
	return out


## 土星环。真实半径数据见 BodyData。
func _build_saturn_rings(planet_radius: float) -> MeshInstance3D:
	var inner := planet_radius * BodyData.RING_INNER
	var outer := planet_radius * BodyData.RING_OUTER
	var segs := 192

	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	for i in segs + 1:
		var a := TAU * float(i) / float(segs)
		var ca := cos(a)
		var sa := sin(a)
		verts.append(Vector3(ca * inner, 0.0, sa * inner))
		uvs.append(Vector2(0.0, 0.0))
		norms.append(Vector3.UP)
		verts.append(Vector3(ca * outer, 0.0, sa * outer))
		uvs.append(Vector2(1.0, 0.0))
		norms.append(Vector3.UP)
	for i in segs:
		var b := i * 2
		idx.append_array([b, b + 1, b + 2, b + 1, b + 3, b + 2])

	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)

	var mi := MeshInstance3D.new()
	mi.mesh = am
	mi.name = "SaturnRings"
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/rings.gdshader")
	var bands := BodyData.ring_bands()
	for k in bands:
		mat.set_shader_parameter(k, float(bands[k]))
	mat.set_shader_parameter("planet_radius", planet_radius)
	mi.material_override = mat
	saturn_rings = mi
	return mi


## 轨迹带。用面向相机的三角带而不是线段 —— Godot 的线没有宽度。
##
## 每个路径点吐两个顶点（UV.y = ±1），顶点着色器沿「切线 × 视线」把它们
## 撑开成恒定屏幕宽度的带子。NORMAL 存切线。
func _build_ribbon(points: PackedVector3Array, width: float,
		col_a: Color, col_b: Color, alpha: float, pulses: float,
		trail_falloff: float = 0.0) -> MeshInstance3D:
	var n := points.size()
	var mi := MeshInstance3D.new()
	if n < 2:
		mi.mesh = ImmediateMesh.new()
		return mi

	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	for i in n:
		var tangent: Vector3
		if i == 0:
			tangent = points[1] - points[0]
		elif i == n - 1:
			tangent = points[n - 1] - points[n - 2]
		else:
			tangent = points[i + 1] - points[i - 1]
		if tangent.length() < 1e-9:
			tangent = Vector3.FORWARD
		tangent = tangent.normalized()
		var t := float(i) / float(n - 1)
		verts.append(points[i]); uvs.append(Vector2(t, -1.0)); norms.append(tangent)
		verts.append(points[i]); uvs.append(Vector2(t, 1.0)); norms.append(tangent)
	for i in n - 1:
		var b := i * 2
		idx.append_array([b, b + 1, b + 2, b + 1, b + 3, b + 2])

	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mi.mesh = am
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# 轨迹跨越整个太阳系，包围盒算出来会导致远处被剔除，直接关掉剔除。
	mi.extra_cull_margin = 100000.0

	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/path.gdshader")
	mat.set_shader_parameter("color_a", col_a)
	mat.set_shader_parameter("color_b", col_b)
	mat.set_shader_parameter("base_alpha", alpha)
	mat.set_shader_parameter("pulse_count", pulses)
	mat.set_shader_parameter("width_screen", width)
	mat.set_shader_parameter("trail_falloff", trail_falloff)
	mi.material_override = mat
	return mi


func _build_path_mesh(body: String, from_jd: float, to_jd: float,
		col_a: Color, col_b: Color, samples: int,
		alpha: float, width: float, pulses: float) -> MeshInstance3D:
	var pts := PackedVector3Array()
	for i in samples:
		var jd := lerpf(from_jd, to_jd, float(i) / float(samples - 1))
		pts.append(_to_units(eph.state_at(body, jd)["pos"]))
	var mi := _build_ribbon(pts, width, col_a, col_b, alpha, pulses)
	mi.name = body + "_path"
	return mi


## 已飞过的航迹。
##
## 和行星轨道刻意做出区别：更粗、更亮、青→品红的渐变，脉冲更快，
## 而且**末端最亮往回衰减** —— 视觉上拖着一条尾巴，一眼能看出探测器
## 正往哪儿走、走了多久。
func _rebuild_traveled() -> void:
	if traveled_mesh != null and is_instance_valid(traveled_mesh):
		traveled_mesh.queue_free()
	traveled_mesh = null
	if jd_now <= jd_min:
		return
	var n := 700
	var pts := PackedVector3Array()
	for i in n:
		var jd := lerpf(jd_min, jd_now, float(i) / float(n - 1))
		pts.append(_to_units(eph.state_at("voyager2", jd)["pos"]))
	traveled_mesh = _build_ribbon(pts, 0.0021,
		Color(0.10, 0.95, 1.0), Color(1.0, 0.20, 0.72), 0.34, 5.0, 1.7)
	traveled_mesh.name = "TraveledPath"
	system_root.add_child(traveled_mesh)


## 日心公里 -> 太阳系视图单位。除法在 float64 里完成，只有最后才落到 Vector3。
func _to_units(pos: Array) -> Vector3:
	var s := AU_UNITS / eph.au_km
	return Vector3(float(pos[0]) * s, float(pos[2]) * s, -float(pos[1]) * s)


func _build_craft_view() -> void:
	craft_root = Node3D.new()
	craft_root.name = "CraftView"
	add_child(craft_root)

	var glb := load("res://assets/Voyager2_rigged.glb")
	if glb == null:
		push_error("找不到 res://assets/Voyager2_rigged.glb")
		return
	craft_model = glb.instantiate()
	craft_root.add_child(craft_model)

	highlight_material = StandardMaterial3D.new()
	highlight_material.albedo_color = Color(1.0, 0.45, 0.12)
	highlight_material.emission_enabled = true
	highlight_material.emission = Color(1.0, 0.45, 0.12)
	highlight_material.emission_energy_multiplier = 0.8

	_index_components(craft_model)

	if component_nodes.has("GoldenRecord"):
		record_node = component_nodes["GoldenRecord"]
		record_orig_xform = record_node.transform
		var ab := record_node.get_aabb()
		record_center = ab.position + ab.size * 0.5
		# 唱片是个薄盘，最薄的那个轴就是它的法向，也就是自转轴。
		var thin := 0
		for i in 3:
			if ab.size[i] < ab.size[thin]:
				thin = i
		record_spin_axis = Vector3.ZERO
		record_spin_axis[thin] = 1.0

	var key := DirectionalLight3D.new()
	key.light_energy = 2.2
	key.rotation_degrees = Vector3(-38, 145, 0)
	craft_root.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.9
	fill.rotation_degrees = Vector3(25, -40, 0)
	craft_root.add_child(fill)


func _index_components(node: Node) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		component_nodes[mi.name] = mi
		original_materials[mi.name] = mi.mesh.surface_get_material(0)
		# 生成三角网格碰撞体，供精确拾取。
		#
		# 早先用的是「包围盒射线求交 + 取进入距离最近者」，在嵌套包围盒下
		# 必然失效：Bus 的包围盒把金唱片整个包住，射线先进 Bus 的盒子，
		# 于是点唱片永远选中 Bus。必须按真实三角面拾取。
		mi.create_trimesh_collision()
	for c in node.get_children():
		_index_components(c)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	ui = Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(ui)

	if fatal_error != "":
		var err := Label.new()
		err.text = "数据包加载失败\n\n%s\n\n先运行：\n  go run ./cmd/ingest\n  blender --background --factory-startup --python tools/model/assign.py -- --mode export\n  go run ./cmd/export" % fatal_error
		err.position = Vector2(40, 40)
		err.add_theme_font_size_override("font_size", 16)
		ui.add_child(err)
		return

	# 左上：状态读数
	var left := PanelContainer.new()
	left.position = Vector2(16, 12)
	left.custom_minimum_size = Vector2(430, 0)
	left.mouse_filter = Control.MOUSE_FILTER_STOP
	ui.add_child(left)
	var vb := VBoxContainer.new()
	left.add_child(vb)

	lbl_date = Label.new()
	lbl_date.add_theme_font_size_override("font_size", 21)
	vb.add_child(lbl_date)

	lbl_readout = RichTextLabel.new()
	lbl_readout.bbcode_enabled = true
	lbl_readout.fit_content = true
	lbl_readout.custom_minimum_size = Vector2(410, 0)
	lbl_readout.scroll_active = false
	vb.add_child(lbl_readout)

	lbl_dsn = Label.new()
	lbl_dsn.text = "DSN 链路：未查询"
	vb.add_child(lbl_dsn)
	var btn_dsn := Button.new()
	btn_dsn.text = "查询 DSN 实时链路"
	btn_dsn.pressed.connect(_on_dsn_pressed)
	vb.add_child(btn_dsn)

	# 左栏底部：功率曲线
	spark_power = Sparkline.new()
	spark_power.custom_minimum_size = Vector2(410, 56)
	spark_power.caption = "RTG 输出 1977 → 2035（模型推演）"
	vb.add_child(spark_power)

	spark_dist = Sparkline.new()
	spark_dist.custom_minimum_size = Vector2(410, 56)
	spark_dist.caption = "距地球距离 1977 → 2026"
	spark_dist.line_color = Color(0.62, 0.86, 0.68)
	spark_dist.fill_color = Color(0.35, 0.65, 0.45, 0.20)
	vb.add_child(spark_dist)

	# 右栏
	var right_scroll := ScrollContainer.new()
	right_scroll.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	right_scroll.offset_left = -486
	right_scroll.offset_top = 16
	right_scroll.offset_right = -16
	right_scroll.offset_bottom = -112
	right_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	ui.add_child(right_scroll)
	var right_col := VBoxContainer.new()
	right_col.custom_minimum_size = Vector2(455, 0)
	right_col.add_theme_constant_override("separation", 6)
	right_scroll.add_child(right_col)

	record_panel = PanelContainer.new()
	record_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	record_panel.visible = false
	right_col.add_child(record_panel)

	lbl_tracking = _panel_label(right_col, 450)
	lbl_link = _panel_label(right_col, 450)

	spark_rx = Sparkline.new()
	spark_rx.custom_minimum_size = Vector2(450, 52)
	spark_rx.caption = "DSN 接收信号强度 dBm（自由空间路径损耗）"
	spark_rx.line_color = Color(0.95, 0.72, 0.45)
	spark_rx.fill_color = Color(0.75, 0.50, 0.25, 0.20)
	right_col.add_child(spark_rx)

	lbl_orbit = _panel_label(right_col, 450)
	lbl_component = _panel_label(right_col, 450)

	var rv := VBoxContainer.new()
	record_panel.add_child(rv)
	var rscroll := ScrollContainer.new()
	rscroll.custom_minimum_size = Vector2(450, 300)
	rscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	rv.add_child(rscroll)
	lbl_record = RichTextLabel.new()
	lbl_record.bbcode_enabled = true
	lbl_record.fit_content = true
	lbl_record.custom_minimum_size = Vector2(432, 0)
	lbl_record.scroll_active = false
	rscroll.add_child(lbl_record)
	var rrow := HBoxContainer.new()
	rv.add_child(rrow)
	var b_tone := Button.new()
	b_tone.text = "▶ 1000 Hz 校准音"
	b_tone.pressed.connect(_play_calibration)
	rrow.add_child(b_tone)
	var b_scan := Button.new()
	b_scan.text = "▶ 图像扫描线编码"
	b_scan.pressed.connect(_play_scanlines)
	rrow.add_child(b_scan)
	var b_spin := Button.new()
	b_spin.text = "⟳ 转起来"
	b_spin.pressed.connect(func() -> void: record_spinning = not record_spinning)
	rrow.add_child(b_spin)

	# 底部：时间轴
	var bottom := PanelContainer.new()
	bottom.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.position = Vector2(0, -104)
	bottom.mouse_filter = Control.MOUSE_FILTER_STOP
	ui.add_child(bottom)
	var bv := VBoxContainer.new()
	bottom.add_child(bv)

	slider = HSlider.new()
	slider.min_value = jd_min
	slider.max_value = jd_max
	slider.step = 0.01
	slider.value = jd_now
	slider.custom_minimum_size = Vector2(0, 26)
	slider.value_changed.connect(_on_slider_changed)
	bv.add_child(slider)

	var row := HBoxContainer.new()
	bv.add_child(row)
	btn_play = Button.new()
	btn_play.text = "▶ 播放"
	btn_play.pressed.connect(_on_play_pressed)
	row.add_child(btn_play)
	btn_mode = Button.new()
	btn_mode.text = "切到探测器特写"
	btn_mode.pressed.connect(_on_mode_pressed)
	row.add_child(btn_mode)

	for ev in eph.events:
		var b := Button.new()
		b.text = JDTime.format_date_short(float(ev["jd"]))
		b.tooltip_text = String(ev["label"])
		var target := float(ev["jd"])
		b.pressed.connect(func() -> void: _seek(target))
		row.add_child(b)


func _panel_label(parent: Node, width: int) -> RichTextLabel:
	var pc := PanelContainer.new()
	pc.mouse_filter = Control.MOUSE_FILTER_STOP
	parent.add_child(pc)
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.custom_minimum_size = Vector2(width, 0)
	rt.scroll_active = false
	pc.add_child(rt)
	return rt


func _on_slider_changed(v: float) -> void:
	if _syncing_slider:
		return
	jd_now = v
	_refresh()


func _on_play_pressed() -> void:
	playing = not playing
	btn_play.text = "⏸ 暂停" if playing else "▶ 播放"


func _on_mode_pressed() -> void:
	_set_mode(ViewMode.CRAFT if mode == ViewMode.SYSTEM else ViewMode.SYSTEM)


func _seek(jd: float) -> void:
	jd_now = clampf(jd, jd_min, jd_max)
	_syncing_slider = true
	slider.value = jd_now
	_syncing_slider = false
	_refresh()


func _set_mode(m: ViewMode) -> void:
	mode = m
	system_root.visible = (m == ViewMode.SYSTEM)
	craft_root.visible = (m == ViewMode.CRAFT)
	if m == ViewMode.SYSTEM:
		# 自动取景：按探测器当前距离取，免得一进场是一片空旷。
		var d := JDTime.vec_len(eph.state_at("voyager2", jd_now)["pos"]) / eph.au_km * AU_UNITS
		cam_dist = clampf(d * 1.5, 120.0, 6000.0)
		btn_mode.text = "切到探测器特写"
	else:
		cam_dist = 34.0
		btn_mode.text = "切回太阳系视图"
	_update_camera()


func _process(delta: float) -> void:
	if fatal_error != "":
		return
	_pump_audio()
	if record_spinning and record_node != null:
		# 唱片实际转速 16⅔ rpm，这里按真实转速转，慢得有点催眠但是对的。
		record_angle += delta * TAU * (16.6667 / 60.0)
		var to_c := Transform3D(Basis(), record_center)
		var rot := Transform3D(Basis(record_spin_axis, record_angle), Vector3.ZERO)
		record_node.transform = record_orig_xform * to_c * rot * to_c.affine_inverse()
	if playing:
		jd_now += play_days_per_sec * delta
		if jd_now >= jd_max:
			jd_now = jd_max
			playing = false
			btn_play.text = "▶ 播放"
		_syncing_slider = true
		slider.value = jd_now
		_syncing_slider = false
		_refresh()


func _refresh() -> void:
	var probe := eph.state_at("voyager2", jd_now)
	var earth := eph.state_at("earth", jd_now)
	var in_range: bool = probe["in_range"]

	for name_str in planet_nodes:
		var st := eph.state_at(name_str, jd_now)
		planet_nodes[name_str].position = _to_units(st["pos"])
		planet_nodes[name_str].visible = st["in_range"]
		_spin_body(name_str)

	probe_root.position = _to_units(probe["pos"])
	probe_root.visible = in_range
	_orient_probe(probe, earth)
	_aim_sun_light()
	_scale_markers()
	_rebuild_traveled()
	_rebuild_link_line(probe, earth)
	_update_camera()

	var helio_km := JDTime.vec_len(probe["pos"])
	var speed := JDTime.vec_len(probe["vel"])
	var pw := eph.power_at(jd_now)
	var trk := Geometry.tracking(probe, earth)
	var link := Geometry.link_budget(float(trk["range_km"]))
	var orb := Geometry.orbit(probe)

	lbl_date.text = JDTime.format_date(jd_now)

	# ---- 左栏：任务状态 ----
	# 注意用的是**距地球**的光时，不是距太阳的。指令和遥测走的是地球这条线，
	# 早先按距日算是错的（143 AU 时两者差约 1 AU，即 8 分多钟）。
	var lines := PackedStringArray()
	lines.append("[color=#8fa3bf]距地球[/color]  %.3f AU   (%s km)" % [
		float(trk["range_au"]), JDTime.sci(float(trk["range_km"]))])
	lines.append("[color=#8fa3bf]距离变化率[/color]  %+.4f km/s   [color=#6f7f96]← DSN 的多普勒观测量[/color]"
		% float(trk["range_rate_kms"]))
	lines.append("[color=#8fa3bf]单程光时[/color]  %s      [color=#8fa3bf]往返[/color]  %s" % [
		JDTime.duration_text(float(trk["owlt_sec"])),
		JDTime.duration_text(float(trk["rtlt_sec"]))])
	lines.append("[color=#8fa3bf]距太阳[/color]  %.2f AU    [color=#8fa3bf]日心速度[/color]  %.3f km/s" % [
		helio_km / eph.au_km, speed])
	lines.append("")
	lines.append("[color=#8fa3bf]RTG 输出[/color]  %.1f W   [color=#d98a3a]〔模型推演，非遥测〕[/color]" % pw["watts"])
	lines.append("  燃料剩余 %.1f%%   转换器效率 %.1f%%" % [
		float(pw["fuel_fraction"]) * 100.0, float(pw["converter_fraction"]) * 100.0])
	lines.append("  [color=#6f7f96]两者几乎相等：功率损失约一半来自钚衰变、一半来自热电偶老化[/color]")
	lines.append("")
	if in_range:
		lines.append("[color=#5f9e6f]轨迹数据：归档实测 + Hermite 插值[/color]")
	else:
		lines.append("[color=#b06060]该时刻超出星历覆盖范围[/color]")
	lbl_readout.text = "\n".join(lines)

	# ---- 右栏：测控几何 ----
	var t := PackedStringArray()
	t.append("[b]测控几何[/b]  [color=#6f7f96]全部由星历推导[/color]")
	t.append("[color=#8fa3bf]赤经[/color] %.3f°    [color=#8fa3bf]赤纬[/color] %+.3f°   [color=#6f7f96]← 天线往哪儿指[/color]"
		% [float(trk["ra_deg"]), float(trk["dec_deg"])])
	t.append("[color=#8fa3bf]X 波段多普勒[/color]  %+.1f Hz  (8.420 GHz 载波)" % float(trk["doppler_hz"]))
	t.append("[color=#8fa3bf]日-地-探夹角 SEP[/color]  %.2f°%s" % [
		float(trk["sep_deg"]),
		"   [color=#c07050]← 接近太阳合，链路受太阳噪声压制[/color]" if float(trk["sep_deg"]) < 5.0 else ""])
	t.append("")
	t.append("[color=#8fa3bf]DSN 测站可见性[/color]  [color=#6f7f96](中天高度 > 10° 才够得着)[/color]")
	for st_v in Geometry.visible_stations(float(trk["dec_deg"])):
		var ok: bool = st_v["visible"]
		t.append("  %s %-16s 中天 %+6.1f°  %s" % [
			"[color=#5f9e6f]●[/color]" if ok else "[color=#7a4a4a]○[/color]",
			String(st_v["name"]), float(st_v["culmination_deg"]),
			"[color=#5f9e6f]可跟踪[/color]" if ok else "[color=#8a6060]地平线以下[/color]"])
	lbl_tracking.text = "\n".join(t)

	# ---- 右栏：链路预算 ----
	var l := PackedStringArray()
	l.append("[b]下行链路预算[/b]  [color=#6f7f96]18 W 行波管 + 3.7 m 碟 → DSN 70 m[/color]")
	l.append("[color=#8fa3bf]自由空间路径损耗[/color]  %.1f dB" % float(link["fspl_db"]))
	l.append("[color=#8fa3bf]DSN 接收信号[/color]  %.1f dBm" % float(link["rx_dbm"]))
	l.append("[color=#6f7f96]损耗随距离平方增长 —— 这就是数据率从 115 kbps 一路降到 160 bps 的物理原因[/color]")
	lbl_link.text = "\n".join(l)

	# ---- 右栏：轨道能量 ----
	var o := PackedStringArray()
	o.append("[b]日心轨道[/b]")
	o.append("[color=#8fa3bf]当前速度[/color] %.3f km/s   [color=#8fa3bf]该处逃逸速度[/color] %.3f km/s" % [
		float(orb["speed_kms"]), float(orb["v_escape_kms"])])
	if bool(orb["escaping"]):
		o.append("[color=#5f9e6f]已达逃逸条件[/color]，双曲剩余速度 %.3f km/s（永不返回）" % float(orb["v_inf_kms"]))
	else:
		o.append("[color=#c0a060]仍在束缚轨道上[/color]")
	o.append("[color=#8fa3bf]日球层顶[/color]  %s  [color=#6f7f96](119 AU，2018-11-05 穿越)[/color]" % (
		"[color=#7f9fd0]已进入星际空间[/color]" if bool(orb["beyond_heliopause"]) else "仍在日球层内"))
	var near := Geometry.nearest_body(probe["pos"], eph.bodies,
		func(n: String, j: float) -> Dictionary: return eph.state_at(n, j), jd_now)
	if String(near["name"]) != "":
		o.append("[color=#8fa3bf]最近天体[/color]  %s   %s km  (%.4f AU)" % [
			String(near["label"]), JDTime.sci(float(near["distance_km"])),
			float(near["distance_km"]) / eph.au_km])
	lbl_orbit.text = "\n".join(o)

	# ---- 曲线标记 ----
	var ratio := (jd_now - jd_min) / maxf(1e-9, jd_max - jd_min)
	spark_power.marker_ratio = clampf(ratio, 0.0, 1.0)
	spark_power.value_text = "%.1f W" % float(pw["watts"])
	spark_power.queue_redraw()
	spark_dist.marker_ratio = clampf(ratio, 0.0, 1.0)
	spark_dist.value_text = "%.2f AU" % float(trk["range_au"])
	spark_dist.queue_redraw()
	spark_rx.marker_ratio = clampf(ratio, 0.0, 1.0)
	spark_rx.value_text = "%.1f dBm" % float(link["rx_dbm"])
	spark_rx.queue_redraw()

	if selected_component == "":
		var hint := "按 Tab 切到探测器特写，再[b]右键[/b]点选部件。"
		if mode == ViewMode.CRAFT:
			hint = "[b]右键[/b]点选部件查看归属与置信度。试试舱体侧面那张金唱片。"
		lbl_component.text = "[color=#8fa3bf]%s[/color]" % hint


## 行星和探测器按真实比例在这个尺度下只有零点几个单位，拉远之后就是几个
## 亚像素的点，等于看不见。所以标记随相机距离等比放大 —— 这是示意尺寸，
## 不是真实比例，行星本体的相对大小仍然保留。
func _scale_markers() -> void:
	var k := maxf(1.0, cam_dist * 0.0016)
	for n in planet_nodes:
		planet_nodes[n].scale = Vector3.ONE * k
	# 探测器的缩放：近处固定世界尺寸，远处才按距离放大。
	#
	# 早先做成了纯粹的「恒定视角大小」（scale ∝ cam_dist），后果是无论怎么
	# 放大它都只占屏幕 4% —— **永远凑不近看**。对一个数字孪生来说这是错的，
	# 拉近检视本来就是核心操作。
	#
	# 现在：pk = max(近处固定值, cam_dist × 系数)
	#   近处 —— 固定 0.50。基准要看**碟面**（直径 3.8）而不是整机跨度 17，
	#           因为那 17 里有 15 米是几乎看不见的磁强计桁架。
	#           原本取 1.1，但飞掠时探测器把行星整个挡住了 —— 天王星特写里
	#           两者只隔 100 万公里，夸张后的探测器直接盖在行星前面。
	#           压到 0.50 后仍可推近到充满画面（cam_dist 3 时占屏高约 41%）。
	#   远处 —— 按 0.0011·d 放大以免消失，上限 5.0。
	#
	# 这个远处系数是压过一次的：早先取 0.016，结果在木星飞掠的视距上探测器
	# 的碟面有 9.7 个单位、而木星直径只有 3.7 —— 探测器比木星还大，荒谬。
	# 两者的夸张倍数本来就天差地别（行星约 620 倍，探测器约 4 亿倍），
	# 没有诚实的可比性，但至少不能让人看出「探测器比行星大」这种反直觉画面。
	var pk := clampf(maxf(0.50, cam_dist * 0.0011), 0.50, 5.0)
	if probe_model != null:
		probe_model.scale = Vector3.ONE * pk
	# 光晕只是**远距离的定位提示**：拉远时它是唯一能让人找到探测器的线索，
	# 但凑近时必须让路 —— 加法混合的光晕会把模型本身糊成一团发光的球。
	var halo_on := cam_dist > 140.0
	probe_marker.visible = halo_on
	if halo_on:
		probe_marker.scale = Vector3.ONE * clampf(cam_dist * 0.0075, 1.0, 46.0)


## 天体自转。
##
## 自转**速率**用真实的恒星自转周期（NASA Planetary Fact Sheet），负号为逆行
## —— 金星和天王星确实是倒着转的。但**绝对相位是任意的**：要定死相位需要
## 各天体本初子午线在 J2000 的定向（IAU 的 W0/W1 参数），那份数据本项目没有
## 接入，所以这里只保证转速和转向正确，不假装知道此刻哪一面朝着我们。
##
## 时间轴快放时行星会转成一团模糊 —— 那是如实的：木星 9.93 小时一圈，
## 按 60 天/秒播放时它每秒真的转 145 圈。
func _spin_body(name_str: String) -> void:
	if not planet_spin.has(name_str):
		return
	var hours: float = float(BodyData.ROTATION_HOURS.get(name_str, 0.0))
	if absf(hours) < 1e-6:
		return
	var turns := (jd_now - jd_min) * 24.0 / hours
	planet_spin[name_str].rotation.y = fmod(turns, 1.0) * TAU


## 平行光方向 = 从太阳射向探测器。
func _aim_sun_light() -> void:
	if sun_light == null:
		return
	var d := probe_root.position
	if d.length() < 1e-5:
		return
	sun_light.look_at_from_position(Vector3.ZERO, d, Vector3.UP)


## 让高增益天线指向地球。
##
## 这不是随手摆的姿态：Voyager 2 的姿态控制律就是把高增益天线保持对地指向
## ——否则 19 小时外的下行链路根本建立不起来。模型在 glTF 里以 Y-up 导出，
## 碟面法向落在 +Y，所以要构造一个把 +Y 对准地球方向的基。
func _orient_probe(probe: Dictionary, earth: Dictionary) -> void:
	if probe_model == null or not bool(probe["in_range"]) or not bool(earth["in_range"]):
		return
	var to_earth := (_to_units(earth["pos"]) - _to_units(probe["pos"]))
	if to_earth.length() < 1e-6:
		return
	var y_axis := to_earth.normalized()
	# 取一个跟指向不共线的参考轴来定滚转。滚转本身在公开数据里没有，
	# 这里只保证天线指向正确，不假装知道滚转角。
	var ref := Vector3(0, 0, 1)
	if absf(y_axis.dot(ref)) > 0.98:
		ref = Vector3(1, 0, 0)
	var x_axis := ref.cross(y_axis).normalized()
	var z_axis := x_axis.cross(y_axis)
	probe_root.basis = Basis(x_axis, y_axis, z_axis)


## 探测器↔地球连线。DSN 的上下行就走这条路径。
func _rebuild_link_line(probe: Dictionary, earth: Dictionary) -> void:
	var im: ImmediateMesh = link_line.mesh
	im.clear_surfaces()
	if not bool(probe["in_range"]) or not bool(earth["in_range"]):
		return
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.35, 0.75, 0.95, 0.45)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	im.surface_add_vertex(_to_units(earth["pos"]))
	im.surface_add_vertex(_to_units(probe["pos"]))
	im.surface_end()


## 曲线数据只跟时间有关，启动时算一次即可。
func _build_series() -> void:
	var n := 320
	var d := PackedFloat32Array()
	var p := PackedFloat32Array()
	var rx := PackedFloat32Array()
	for i in n:
		var jd := lerpf(jd_min, jd_max, float(i) / float(n - 1))
		var pr := eph.state_at("voyager2", jd)
		var ea := eph.state_at("earth", jd)
		var tr := Geometry.tracking(pr, ea)
		d.append(float(tr["range_au"]))
		p.append(float(eph.power_at(jd)["watts"]))
		rx.append(float(Geometry.link_budget(float(tr["range_km"]))["rx_dbm"]))
	spark_dist.set_series(d, 1.0)
	spark_power.set_series(p, 1.0)
	spark_rx.set_series(rx, 1.0)


func _update_camera() -> void:
	if mode == ViewMode.SYSTEM and probe_marker != null:
		_scale_markers()
	var target := craft_focus
	if mode == ViewMode.SYSTEM:
		target = probe_root.position * 0.35
		if _shot_focus_probe:
			target = probe_root.position
		elif _shot_focus_sun:
			target = Vector3.ZERO
		elif _shot_focus_body != "" and planet_nodes.has(_shot_focus_body):
			target = planet_nodes[_shot_focus_body].position
	var dir := Vector3(
		cos(cam_pitch) * sin(cam_yaw), sin(cam_pitch), cos(cam_pitch) * cos(cam_yaw))
	camera.position = target + dir * cam_dist
	camera.look_at(target, Vector3.UP)


func _unhandled_input(event: InputEvent) -> void:
	if fatal_error != "":
		return
	if event is InputEventMouseMotion and (event as InputEventMouseMotion).button_mask & MOUSE_BUTTON_MASK_LEFT:
		var mm := event as InputEventMouseMotion
		_drag_travel += mm.relative.length()
		cam_yaw -= mm.relative.x * 0.006
		cam_pitch = clampf(cam_pitch + mm.relative.y * 0.006, -1.45, 1.45)
		_update_camera()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			cam_dist = maxf(cam_dist * 0.88, 3.0)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			cam_dist = minf(cam_dist * 1.14, 40000.0)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed and mode == ViewMode.CRAFT:
			_pick_component(mb.position)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			# 左键按下开始计拖动距离；松手时几乎没动，就当作点选。
			if mb.pressed:
				_drag_travel = 0.0
			elif _drag_travel < 6.0 and mode == ViewMode.CRAFT:
				_pick_component(mb.position)
	elif event is InputEventKey and (event as InputEventKey).pressed:
		var k := event as InputEventKey
		if k.keycode == KEY_SPACE:
			_on_play_pressed()
		elif k.keycode == KEY_TAB:
			_on_mode_pressed()


## 部件点选：对三角网格做物理射线求交，精确到面。
func _pick_component(screen_pos: Vector2) -> void:
	var from := camera.project_ray_origin(screen_pos)
	var to := from + camera.project_ray_normal(screen_pos) * 2000.0
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_areas = false
	q.collide_with_bodies = true
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return
	# create_trimesh_collision() 把 StaticBody3D 挂成 MeshInstance3D 的子节点，
	# 所以碰撞体的父节点就是组件本身。
	var collider: Object = hit.get("collider")
	if collider == null or not (collider is Node):
		return
	var owner_node := (collider as Node).get_parent()
	if owner_node == null or not component_nodes.has(owner_node.name):
		return
	_select_component(owner_node.name)


func _select_component(node_name: String) -> void:
	# 还原上一次高亮。
	if selected_component != "" and component_nodes.has(selected_component):
		var prev: MeshInstance3D = component_nodes[selected_component]
		prev.mesh.surface_set_material(0, original_materials[selected_component])
	selected_component = node_name
	var mi: MeshInstance3D = component_nodes[node_name]
	# 金唱片是唯一不做高亮的部件：它的价值就在那张真实的封面蚀刻贴图上，
	# 换成纯色高亮材质等于把要看的东西盖掉。这里靠镜头推近来给反馈。
	if node_name != "GoldenRecord":
		mi.mesh.surface_set_material(0, highlight_material)

	# 找出所有指向该节点的 ComponentID（含模型未区分的别名）。
	var ids := []
	var note := ""
	for c in eph.components:
		if String(c["node"]) == node_name:
			ids.append(c)
			note = String(c["confidence_note"])

	var lines := PackedStringArray()
	lines.append("[b]%s[/b]" % node_name)
	if ids.is_empty():
		lines.append("[color=#b06060]该节点不在组件契约中[/color]")
	else:
		var distinct := []
		var aliased := []
		for c in ids:
			if bool(c["distinct_geometry"]):
				distinct.append(String(c["id"]))
			else:
				aliased.append(String(c["id"]))
		if not distinct.is_empty():
			lines.append("ComponentID：%s" % ", ".join(distinct))
		if not aliased.is_empty():
			lines.append("[color=#d98a3a]该视觉模型未区分以下仪器，它们共用这块几何：[/color]")
			lines.append("  %s" % ", ".join(aliased))
		lines.append("")
		lines.append("[color=#8fa3bf]归属判据[/color]  %s" % note)
	lines.append("")
	lines.append("[color=#6f7f96]NASA 不提供 Voyager 2 的公开工程遥测，[/color]")
	lines.append("[color=#6f7f96]所以此处没有该部件的温度/电压读数 —— 没有就是没有。[/color]")
	lbl_component.text = "\n".join(lines)

	if node_name == "GoldenRecord":
		_show_record_panel()
		# 把镜头推到唱片上，让人直接看 NASA 模型自带的真实封面蚀刻图案。
		craft_focus = mi.global_transform * record_center
		# 唱片直径 0.314 m，要填满画面，相机距离取直径的 1.4 倍左右。
		cam_dist = 0.45
		cam_yaw = 1.5708
		cam_pitch = 0.0
		record_spinning = true
		_update_camera()
	else:
		record_panel.visible = false
		craft_focus = Vector3.ZERO
		record_spinning = false
		if record_node != null:
			record_node.transform = record_orig_xform
			record_angle = 0.0


func _show_record_panel() -> void:
	record_panel.visible = true
	var spec := GoldenRecord.SPEC
	var r := PackedStringArray()
	r.append("[b]旅行者金唱片[/b]  [color=#c9a227]12 英寸镀金铜盘[/color]")
	r.append("[color=#6f7f96]你现在看到的封面蚀刻图案是 NASA 模型自带的真实贴图：[/color]")
	r.append("[color=#6f7f96]左上播放示意 · 右上二进制时基 · 中间图像光栅 · 左下 14 颗脉冲星定位图 · 右下氢原子跃迁[/color]")
	r.append("")
	r.append("转速 %s" % String(spec["rpm"]))
	r.append("%s" % String(spec["clock"]))
	r.append("载荷：%d 张图像 · %d 种语言问候 · %d 首乐曲（约 %d 分钟）· %d 分钟地球之声" % [
		int(spec["images"]), int(spec["languages"]), int(spec["music_tracks"]),
		int(spec["music_minutes"]), int(spec["sounds_minutes"])])
	r.append("")
	for sec in GoldenRecord.CONTENTS:
		r.append("[b]%s[/b]" % String(sec["section"]))
		if String(sec["note"]) != "":
			r.append("  [color=#6f7f96]%s[/color]" % String(sec["note"]))
		for it in sec["items"]:
			r.append("  · %s" % String(it))
		r.append("")
	r.append("[color=#d98a3a]为什么这里没有唱片上的音乐：[/color]")
	r.append("[color=#6f7f96]那 27 首绝大多数是受版权保护的商业录音，NASA 当年只取得一次性搭载[/color]")
	r.append("[color=#6f7f96]授权，并未置于公有领域 —— NASA 自己的图库都因版权只展示 116 张图的一部分。[/color]")
	r.append("[color=#6f7f96]所以这里不打包任何录音，只合成唱片上真实存在的物理信号：[/color]")
	r.append("[color=#6f7f96]1000 Hz 参考校准音，以及图像的模拟扫描线编码。[/color]")
	lbl_record.text = "\n".join(r)


func _ensure_audio() -> AudioStreamGeneratorPlayback:
	if audio == null:
		audio = AudioStreamPlayer.new()
		var gen := AudioStreamGenerator.new()
		gen.mix_rate = GoldenRecord.SAMPLE_RATE
		gen.buffer_length = 0.5
		audio.stream = gen
		add_child(audio)
	if not audio.playing:
		audio.play()
	return audio.get_stream_playback() as AudioStreamGeneratorPlayback


func _queue_audio(frames: PackedVector2Array) -> void:
	audio_queue = frames
	audio_cursor = 0
	_ensure_audio()


func _play_calibration() -> void:
	_queue_audio(GoldenRecord.calibration_tone(2.5))
	record_spinning = true


func _play_scanlines() -> void:
	# 用唱片封面自己的贴图做演示：把它按唱片的方式编码成扫描线音频。
	# 这不是那 116 张图之一，但编码方式是真实的。
	var img: Image = null
	if record_node != null:
		var mat := record_node.mesh.surface_get_material(0)
		if mat is StandardMaterial3D:
			var tex := (mat as StandardMaterial3D).albedo_texture
			if tex != null:
				img = tex.get_image()
	if img == null:
		# 退化情况：合成一幅同心圆图样，至少能听出扫描线的结构。
		img = Image.create(96, 48, false, Image.FORMAT_RGB8)
		for y in 48:
			for x in 96:
				var v := 0.5 + 0.5 * sin(sqrt(pow(x - 48.0, 2.0) + pow(y - 24.0, 2.0)) * 0.6)
				img.set_pixel(x, y, Color(v, v, v))
	_queue_audio(GoldenRecord.encode_image_scanlines(img))
	record_spinning = true


## 把排队的音频逐帧推给生成器。
func _pump_audio() -> void:
	if audio == null or audio_queue.is_empty():
		return
	var pb := audio.get_stream_playback() as AudioStreamGeneratorPlayback
	if pb == null:
		return
	var n := pb.get_frames_available()
	while n > 0 and audio_cursor < audio_queue.size():
		pb.push_frame(audio_queue[audio_cursor])
		audio_cursor += 1
		n -= 1
	if audio_cursor >= audio_queue.size():
		audio_queue = PackedVector2Array()


func _on_dsn_pressed() -> void:
	if dsn_request == null:
		dsn_request = HTTPRequest.new()
		add_child(dsn_request)
		dsn_request.request_completed.connect(_on_dsn_done)
	lbl_dsn.text = "DSN 链路：查询中…"
	var url := "https://eyes.nasa.gov/dsn/data/dsn.xml?r=%d" % Time.get_unix_time_from_system()
	if dsn_request.request(url) != OK:
		lbl_dsn.text = "DSN 链路：请求发起失败"


func _on_dsn_done(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if code != 200:
		lbl_dsn.text = "DSN 链路：HTTP %d" % code
		return
	var parser := XMLParser.new()
	if parser.open_buffer(body) != OK:
		lbl_dsn.text = "DSN 链路：XML 解析失败"
		return
	var connected := false
	var rate := 0.0
	var dish := ""
	var last_dish := ""
	# 阳性对照：统计 feed 里所有正在下行的航天器。
	#
	# 「Voyager 2 未跟踪」是绝对的常态（它赤纬极低，基本只有堪培拉 DSS-43
	# 能看见，一天连几小时），但解析器坏掉时也会给出同样的结论。所以必须同时
	# 证明解析器确实看见了别的航天器，否则这个「未跟踪」毫无信息量。
	dsn_active_craft.clear()
	while parser.read() == OK:
		if parser.get_node_type() != XMLParser.NODE_ELEMENT:
			continue
		var tag := parser.get_node_name()
		if tag == "dish":
			last_dish = _attr(parser, "name")
		elif tag == "downSignal":
			if _attr(parser, "active") != "true":
				continue
			var sc := _attr(parser, "spacecraft")
			if sc != "" and not dsn_active_craft.has(sc):
				dsn_active_craft.append(sc)
			if _attr(parser, "spacecraftID") == "-32":
				connected = true
				rate = float(_attr(parser, "dataRate"))
				dish = last_dish
	if connected:
		lbl_dsn.text = "DSN 链路：正在跟踪  %s   下行 %.0f bps  〔实时〕" % [dish, rate]
	elif dsn_active_craft.is_empty():
		# 一个航天器都没解析出来，说明是解析或馈送出了问题，不是「没在跟踪」。
		lbl_dsn.text = "DSN 链路：馈送已收到但未解析出任何航天器 —— 疑似解析故障"
	else:
		# 这是常态：Voyager 2 赤纬极低，基本只有堪培拉 DSS-43 能看见，一天连几小时。
		lbl_dsn.text = "DSN 链路：当前未跟踪（常态，非故障）｜此刻全网在跟 %s 〔实时〕" % ", ".join(dsn_active_craft)


func _attr(parser: XMLParser, key: String) -> String:
	for i in parser.get_attribute_count():
		if parser.get_attribute_name(i) == key:
			return parser.get_attribute_value(i)
	return ""


## 截图自检：按脚本走一遍关键状态并存 PNG，供人工核对渲染是否真的对。
## 无头模式渲染不出东西，所以这个必须在有窗口的情况下跑：
##   Godot --path . -- --shots
func _run_screenshot_harness() -> void:
	var out_dir := "res://../assets/generated/godot_shots"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))

	var steps: Array = [
		{"name": "01_now_system", "jd": jd_max, "mode": ViewMode.SYSTEM, "dist": 3200.0},
		{"name": "02_neptune_flyby", "jd": _event_jd("1989-08-25"), "mode": ViewMode.SYSTEM, "dist": 520.0},
		{"name": "03_jupiter_flyby", "jd": _event_jd("1979-07-09"), "mode": ViewMode.SYSTEM, "dist": 160.0},
		{"name": "04_launch", "jd": jd_min + 1.0, "mode": ViewMode.SYSTEM, "dist": 60.0},
		{"name": "05_craft", "jd": jd_max, "mode": ViewMode.CRAFT, "dist": 30.0},
		{"name": "06_craft_rtg", "jd": jd_max, "mode": ViewMode.CRAFT, "dist": 13.0,
			"select": "RTG_2", "yaw": 1.9, "pitch": 0.15},
		{"name": "07_golden_record", "jd": jd_max, "mode": ViewMode.CRAFT, "dist": 1.1,
			"select": "GoldenRecord"},
		{"name": "08_sun", "jd": _event_jd("1979-07-09"), "mode": ViewMode.SYSTEM,
			"dist": 16.0, "focus_sun": true, "deselect": true},
		{"name": "09_probe_closeup", "jd": _event_jd("1989-08-25"), "mode": ViewMode.SYSTEM,
			"dist": 14.0, "focus_probe": true, "deselect": true},
		{"name": "10_jupiter", "jd": _event_jd("1979-07-09"), "mode": ViewMode.SYSTEM,
			"dist": 14.0, "focus_body": "jupiter", "deselect": true},
		{"name": "11_saturn", "jd": _event_jd("1981-08-26"), "mode": ViewMode.SYSTEM,
			"dist": 24.0, "focus_body": "saturn", "deselect": true,
			"yaw": 0.9, "pitch": 0.42},
		{"name": "12_earth", "jd": jd_min + 900.0, "mode": ViewMode.SYSTEM,
			"dist": 3.2, "focus_body": "earth", "deselect": true},
		{"name": "13_uranus", "jd": _event_jd("1986-01-24"), "mode": ViewMode.SYSTEM,
			"dist": 14.0, "focus_body": "uranus", "deselect": true},
		{"name": "14_neptune", "jd": _event_jd("1989-08-25"), "mode": ViewMode.SYSTEM,
			"dist": 14.0, "focus_body": "neptune", "deselect": true},
	]

	for st in steps:
		_seek(float(st["jd"]))
		_set_mode(st["mode"])
		cam_dist = float(st["dist"])
		_shot_focus_probe = st.has("focus_probe")
		_shot_focus_sun = st.has("focus_sun")
		_shot_focus_body = String(st.get("focus_body", ""))
		if st.has("deselect"):
			selected_component = ""
			record_panel.visible = false
			record_spinning = false
		if st.has("yaw"):
			cam_yaw = float(st["yaw"])
		if st.has("pitch"):
			cam_pitch = float(st["pitch"])
		if st.has("select") and component_nodes.has(String(st["select"])):
			_select_component(String(st["select"]))
		_update_camera()
		# 等两帧，确保 UI 布局与渲染都已落定。
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := ProjectSettings.globalize_path(out_dir) + "/" + String(st["name"]) + ".png"
		var err := img.save_png(path)
		print("SHOT %s -> %s (%s)" % [st["name"], path, "ok" if err == OK else "err %d" % err])

	print("SHOTS_DONE")
	get_tree().quit()


func _event_jd(date: String) -> float:
	for ev in eph.events:
		if String(ev["date"]) == date:
			return float(ev["jd"])
	return jd_max


## DSN 实时链路自检：真发一次请求，把结果打出来再退出。
## 未测过的网络代码就是尾巴，所以这条唯一的实时链路必须能在无人值守下验证。
##   Godot --headless --path . -- --dsntest
func _run_dsn_selftest() -> void:
	_on_dsn_pressed()
	var waited := 0.0
	while lbl_dsn.text.ends_with("查询中…") and waited < 30.0:
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
	print("DSNTEST %s" % lbl_dsn.text)
	# 顺带用一个确定在被跟踪的航天器做阳性对照，证明解析器不是永远返回未跟踪。
	print("DSNTEST_DONE")
	get_tree().quit()


## 拾取自检：对每个部件取若干真实表面点，从模型外侧朝该点看，打射线验证
## 选中的是不是它自己。
##
## 这条自检守的是一个真实踩过的坑：早先用包围盒求交 + 取最近进入点，在嵌套
## 包围盒下必然失效 —— Bus 的盒子把金唱片整个包住，点唱片永远选中 Bus。
## 肉眼看截图看不出这种问题，必须让机器判。
##
## 注意瞄准点必须取**真实顶点**而不是包围盒中心：磁强计桁架、推力器、鞭状
## 天线这类细杆/格栅件，包围盒中心是空气，射线会从缝里穿过去，那是测试瞄错
## 了地方，不是拾取坏了。
##   Godot --path . -- --picktest
func _run_pick_selftest() -> void:
	_set_mode(ViewMode.CRAFT)
	var model_center := Vector3.ZERO
	if component_nodes.has("Bus"):
		var bus: MeshInstance3D = component_nodes["Bus"]
		var bab := bus.get_aabb()
		model_center = bus.global_transform * (bab.position + bab.size * 0.5)

	var pass_n := 0
	var fail_n := 0
	var report := PackedStringArray()
	for name_str in component_nodes.keys():
		var mi: MeshInstance3D = component_nodes[name_str]
		var verts: PackedVector3Array = mi.mesh.get_faces()
		if verts.is_empty():
			continue
		# 取若干均匀分布的表面点，只要有一个能被正确选中就算通过
		# （被遮挡的表面点选不中是合理行为：看不见的东西本来就点不到）。
		var tries := 12
		var ok := false
		var last_got := "(未命中)"
		for k in tries:
			var idx := int(float(k) / float(tries) * float(verts.size()))
			idx = clampi(idx, 0, verts.size() - 1)
			var target: Vector3 = mi.global_transform * verts[idx]
			var outward := (target - model_center)
			if outward.length() < 1e-4:
				outward = Vector3(1, 0.4, 0.3)
			outward = outward.normalized()

			craft_focus = target
			camera.position = target + outward * 2.2
			camera.look_at(target, Vector3.UP)
			await get_tree().physics_frame

			var sc := get_viewport().get_visible_rect().size * 0.5
			var from := camera.project_ray_origin(sc)
			var to := from + camera.project_ray_normal(sc) * 2000.0
			var hit := get_world_3d().direct_space_state.intersect_ray(
				PhysicsRayQueryParameters3D.create(from, to))
			if hit.is_empty():
				continue
			var col: Object = hit.get("collider")
			if col is Node and (col as Node).get_parent() != null:
				last_got = (col as Node).get_parent().name
				if last_got == name_str:
					ok = true
					break
		if ok:
			pass_n += 1
			report.append("PICKTEST %-18s OK" % name_str)
		else:
			fail_n += 1
			report.append("PICKTEST %-18s FAIL -> 最后命中 %s" % [name_str, last_got])
	for line in report:
		print(line)
	print("PICKTEST_DONE pass=%d fail=%d" % [pass_n, fail_n])
	get_tree().quit()


## 姿态自检：验证高增益天线确实指向地球。
##
## 不靠肉眼看渲染图判断朝向 —— 碟面在斜视角下是个椭圆，正对和偏 30 度
## 看起来差不多。模型经 glTF 以 Y-up 导出，碟面法向落在 +Y，所以直接量
## probe_root 的 +Y 轴与「探测器→地球」方向的夹角，应当恒为 0。
func _run_attitude_selftest() -> void:
	_set_mode(ViewMode.SYSTEM)
	var worst := 0.0
	var checks := [jd_min + 30.0, _event_jd("1979-07-09"), _event_jd("1989-08-25"),
		(jd_min + jd_max) * 0.5, jd_max]
	for jd in checks:
		_seek(jd)
		var probe := eph.state_at("voyager2", jd)
		var earth := eph.state_at("earth", jd)
		var want := (_to_units(earth["pos"]) - _to_units(probe["pos"])).normalized()
		var got: Vector3 = probe_root.basis.y.normalized()
		var deg := rad_to_deg(acos(clampf(got.dot(want), -1.0, 1.0)))
		worst = maxf(worst, deg)
		print("ATTITUDE %s  天线轴与对地方向夹角 %.4f°" % [JDTime.format_date_short(jd), deg])
	print("ATTITUDE_DONE 最大偏差 %.4f° %s" % [worst, "OK" if worst < 0.01 else "FAIL"])
	get_tree().quit()
