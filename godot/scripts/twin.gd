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
const PLANET_EXAGGERATION := 300.0
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
var probe_marker: MeshInstance3D
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
	_refresh()

	if "--shots" in OS.get_cmdline_user_args():
		_run_screenshot_harness.call_deferred()
	if "--dsntest" in OS.get_cmdline_user_args():
		_run_dsn_selftest.call_deferred()
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
	env.glow_enabled = true
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

	# 太阳。半径不按真实比例 —— 真实比例下它在这个尺度里只有 0.05 单位。
	var sun := MeshInstance3D.new()
	var sun_mesh := SphereMesh.new()
	sun_mesh.radius = 4.0
	sun_mesh.height = 8.0
	sun.mesh = sun_mesh
	var sun_mat := StandardMaterial3D.new()
	sun_mat.albedo_color = Color(1.0, 0.93, 0.72)
	sun_mat.emission_enabled = true
	sun_mat.emission = Color(1.0, 0.88, 0.55)
	sun_mat.emission_energy_multiplier = 3.0
	sun_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sun.mesh.surface_set_material(0, sun_mat)
	system_root.add_child(sun)

	var light := OmniLight3D.new()
	light.light_energy = 3.0
	light.omni_range = 40000.0
	system_root.add_child(light)

	for b in eph.bodies:
		var name_str: String = b["name"]
		if bool(b["is_spacecraft"]):
			continue
		var radius_units := clampf(
			float(b["mean_radius_km"]) / eph.au_km * AU_UNITS * PLANET_EXAGGERATION, 0.5, 6.0)
		var node := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = radius_units
		mesh.height = radius_units * 2.0
		node.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.albedo_color = PLANET_COLORS.get(name_str, Color(0.7, 0.7, 0.7))
		node.mesh.surface_set_material(0, mat)
		node.name = name_str
		system_root.add_child(node)
		planet_nodes[name_str] = node

		if name_str in ORBIT_BODIES:
			system_root.add_child(_build_path_mesh(name_str, jd_min, jd_max,
				Color(mat.albedo_color, 0.45), 600))

	# Voyager 2 的完整航迹。
	system_root.add_child(_build_path_mesh("voyager2", jd_min, jd_max,
		Color(0.48, 0.55, 0.70, 0.85), TRAJECTORY_SAMPLES))

	# 已飞过的那一段，随时间轴增长。
	traveled_mesh = MeshInstance3D.new()
	traveled_mesh.mesh = ImmediateMesh.new()
	system_root.add_child(traveled_mesh)

	probe_marker = MeshInstance3D.new()
	var pm := SphereMesh.new()
	pm.radius = 3.0
	pm.height = 6.0
	probe_marker.mesh = pm
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(1.0, 0.35, 0.20)
	pmat.emission_enabled = true
	pmat.emission = Color(1.0, 0.40, 0.20)
	pmat.emission_energy_multiplier = 2.5
	pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	probe_marker.mesh.surface_set_material(0, pmat)
	system_root.add_child(probe_marker)


func _build_path_mesh(body: String, from_jd: float, to_jd: float, color: Color, samples: int) -> MeshInstance3D:
	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = false
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, mat)
	for i in samples:
		var jd := lerpf(from_jd, to_jd, float(i) / float(samples - 1))
		var st := eph.state_at(body, jd)
		im.surface_add_vertex(_to_units(st["pos"]))
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	mi.name = body + "_path"
	return mi


func _rebuild_traveled() -> void:
	var im: ImmediateMesh = traveled_mesh.mesh
	im.clear_surfaces()
	if jd_now <= jd_min:
		return
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.55, 0.25)
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, mat)
	var n := 900
	for i in n:
		var jd := lerpf(jd_min, jd_now, float(i) / float(n - 1))
		im.surface_add_vertex(_to_units(eph.state_at("voyager2", jd)["pos"]))
	im.surface_end()


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
		component_nodes[node.name] = node
		original_materials[node.name] = (node as MeshInstance3D).mesh.surface_get_material(0)
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
	left.position = Vector2(16, 16)
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

	# 右上：组件面板
	var right := PanelContainer.new()
	right.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	right.position = Vector2(-470, 16)
	right.custom_minimum_size = Vector2(450, 0)
	right.mouse_filter = Control.MOUSE_FILTER_STOP
	ui.add_child(right)
	lbl_component = RichTextLabel.new()
	lbl_component.bbcode_enabled = true
	lbl_component.fit_content = true
	lbl_component.custom_minimum_size = Vector2(430, 120)
	lbl_component.scroll_active = false
	right.add_child(lbl_component)

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
		cam_dist = 2600.0
		btn_mode.text = "切到探测器特写"
	else:
		cam_dist = 34.0
		btn_mode.text = "切回太阳系视图"
	_update_camera()


func _process(delta: float) -> void:
	if fatal_error != "":
		return
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
	var in_range: bool = probe["in_range"]

	for name_str in planet_nodes:
		var st := eph.state_at(name_str, jd_now)
		planet_nodes[name_str].position = _to_units(st["pos"])
		planet_nodes[name_str].visible = st["in_range"]

	probe_marker.position = _to_units(probe["pos"])
	probe_marker.visible = in_range
	_rebuild_traveled()
	_update_camera()

	var dist_km := JDTime.vec_len(probe["pos"])
	var speed := JDTime.vec_len(probe["vel"])
	var pw := eph.power_at(jd_now)

	lbl_date.text = JDTime.format_date(jd_now)
	var lines := PackedStringArray()
	lines.append("[color=#8fa3bf]距日[/color]  %.2f AU   (%s km)" % [dist_km / eph.au_km, JDTime.sci(dist_km)])
	lines.append("[color=#8fa3bf]日心速度[/color]  %.3f km/s" % speed)
	lines.append("[color=#8fa3bf]单程光时[/color]  %s" % JDTime.light_time_text(dist_km))
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

	if selected_component == "":
		var hint := "点击左下按钮切到探测器特写，再点选部件查看归属与置信度。"
		if mode == ViewMode.CRAFT:
			hint = "点选任意部件查看归属与置信度。"
		lbl_component.text = "[color=#8fa3bf]%s[/color]" % hint


func _update_camera() -> void:
	var target := Vector3.ZERO
	if mode == ViewMode.SYSTEM:
		target = probe_marker.position * 0.35
	var dir := Vector3(
		cos(cam_pitch) * sin(cam_yaw), sin(cam_pitch), cos(cam_pitch) * cos(cam_yaw))
	camera.position = target + dir * cam_dist
	camera.look_at(target, Vector3.UP)


func _unhandled_input(event: InputEvent) -> void:
	if fatal_error != "":
		return
	if event is InputEventMouseMotion and (event as InputEventMouseMotion).button_mask & MOUSE_BUTTON_MASK_LEFT:
		var mm := event as InputEventMouseMotion
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
	elif event is InputEventKey and (event as InputEventKey).pressed:
		var k := event as InputEventKey
		if k.keycode == KEY_SPACE:
			_on_play_pressed()
		elif k.keycode == KEY_TAB:
			_on_mode_pressed()


## 部件点选。glb 里没有碰撞体，所以直接对每个组件的世界 AABB 做射线求交
## —— 比生成碰撞形状简单，对这个用途也足够。
func _pick_component(screen_pos: Vector2) -> void:
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	var best := ""
	var best_t := INF
	for name_str in component_nodes:
		var mi: MeshInstance3D = component_nodes[name_str]
		var aabb := mi.global_transform * mi.get_aabb()
		var t := _ray_aabb(from, dir, aabb)
		if t >= 0.0 and t < best_t:
			best_t = t
			best = name_str
	if best == "":
		return
	_select_component(best)


func _ray_aabb(from: Vector3, dir: Vector3, box: AABB) -> float:
	var tmin := -INF
	var tmax := INF
	var bmin := box.position
	var bmax := box.position + box.size
	for i in 3:
		var d: float = dir[i]
		if absf(d) < 1e-9:
			if from[i] < bmin[i] or from[i] > bmax[i]:
				return -1.0
			continue
		var t1 := (bmin[i] - from[i]) / d
		var t2 := (bmax[i] - from[i]) / d
		tmin = maxf(tmin, minf(t1, t2))
		tmax = minf(tmax, maxf(t1, t2))
	if tmax < maxf(tmin, 0.0):
		return -1.0
	return maxf(tmin, 0.0)


func _select_component(node_name: String) -> void:
	# 还原上一次高亮。
	if selected_component != "" and component_nodes.has(selected_component):
		var prev: MeshInstance3D = component_nodes[selected_component]
		prev.mesh.surface_set_material(0, original_materials[selected_component])
	selected_component = node_name
	var mi: MeshInstance3D = component_nodes[node_name]
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
	]

	for st in steps:
		_seek(float(st["jd"]))
		_set_mode(st["mode"])
		cam_dist = float(st["dist"])
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
