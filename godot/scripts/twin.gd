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

## 界面倍率的可选档位与存盘位置。倍率是乘进字号和布局像素的（见 HudTheme），
## 换档要重建整层 HUD，所以做成离散档位而不是连续滑块。
const UI_SCALES := [1.0, 1.5]
const SETTINGS_PATH := "user://settings.cfg"

## 行星半径的夸张倍数是**随相机距离变化**的，不是常数。
##
## 为什么必须这样：场景里 1 AU = 10 个单位，而地球半径只有 0.000426 个单位。
## 拉远看太阳系时必须把行星放大上千倍才看得见；但一旦要看卫星系统，同样的
## 倍数就会把内部几何彻底摧毁 —— 早先我用行星的夸张倍数去放大卫星轨道，
## 结果月球被甩到地球公转轨道的 3 倍远（用户一眼看出「离婚了」），木卫四的
## 轨道比木星自己的公转轨道还宽。
##
## 现在：远处大幅放大（看得见行星），近处退回接近真实比例（卫星系统的比例
## 才正确）。在对数空间插值。卫星轨道**一律真实比例，不再放大**。
const EXA_NEAR_DIST := 0.35     # 这个距离及更近 => 倍数 EXA_MIN
## 近处的放大倍数不取 1（真实比例）而取 6，这是一个刻意的、有代价的折中。
##
## 真实比例下地球只有月球轨道半径的 1/60：取景框住月球轨道时，地球就是
## 十几个像素、月球是三个像素。技术上正确，看着毫无意义。
##
## 关键是行星和它的卫星按**同一个倍数**放大，所以两者的**相对大小仍然真实**
## （月球/地球半径 = 0.273，渲染出来还是 0.273）。被压缩的只有「轨道半径 /
## 天体半径」这一个比值，从 60 变成 10。
##
## 这和之前那个 bug 是两码事：那次是把月球轨道本身放大了 1173 倍，甩到地球
## 公转轨道的 3 倍远。现在轨道是真实尺度，只有天体被等比放大。
const EXA_MIN := 6.0
## 卫星系统的取景距离落在 0.006–0.25 之间，所以阈值必须高于这个区间，
## 否则锁定行星后卫星系统的内部比例仍然是被压缩的。
const EXA_FAR_DIST := 400.0     # 这个距离及更远 => 倍数 EXA_MAX
const EXA_MAX := 2000.0
const SUN_RADIUS := 3.2

## 与 planet.gdshader 里的 kind 分支一一对应。
const KIND_ID := {
	"rocky": 0, "venus": 1, "earth": 2, "mars": 3, "gas": 4,
	"ice": 5, "io": 6, "europa": 7, "titan": 8, "triton": 9,
}
const TRAJECTORY_SAMPLES := 2400

# 天体表面贴图。Solar System Scope 2K 全套（CC BY 4.0，见
# godot/assets/textures/CREDITS.md）。
#
# 这里只有九张 —— 那套图里**没有**木卫一/二/三/四、土卫六、天卫五、海卫一，
# 它们继续走 planet.gdshader 的程序化分支。别把这张表当"全部天体"。
# 金星取大气贴图而不是表面贴图：可见光下看到的就是硫酸云顶，表面图是
# 麦哲伦号雷达测高的产物，直接贴上去等于把云层剥了。
const BODY_TEXTURE := {
	"mercury": "res://assets/textures/2k_mercury.jpg",
	"venus": "res://assets/textures/2k_venus_atmosphere.jpg",
	"earth": "res://assets/textures/2k_earth_daymap.jpg",
	"moon": "res://assets/textures/2k_moon.jpg",
	"mars": "res://assets/textures/2k_mars.jpg",
	"jupiter": "res://assets/textures/2k_jupiter.jpg",
	"saturn": "res://assets/textures/2k_saturn.jpg",
	"uranus": "res://assets/textures/2k_uranus.jpg",
	"neptune": "res://assets/textures/2k_neptune.jpg",
}
const TEX_SUN := "res://assets/textures/2k_sun.jpg"
const TEX_EARTH_NIGHT := "res://assets/textures/2k_earth_nightmap.jpg"
const TEX_EARTH_CLOUDS := "res://assets/textures/2k_earth_clouds.jpg"
const TEX_SATURN_RING := "res://assets/textures/2k_saturn_ring_alpha.png"
const TEX_MILKY_WAY := "res://assets/textures/8k_stars_milky_way.jpg"

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
var planet_tilt := {}
var body_real_radius := {}
var satellite_orbits := {}
var _satellite_allowed := {}
var _orbit_built_jd := {}
var _orbit_from_ephemeris := {}
var _orbit_points := {}
## 各天体因「屏幕最小尺寸下限」被额外撑大的倍数。1.0 表示比例真实。
var _size_inflation := {}
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

# UI —— 赛博朋克 HUD 全部在 hud.gd 里，这边只留接线用的引用
var hud: Hud
var ui_scale := 1.0
var slider: HudTimeline
var dsn_text := ""
var dsn_request: HTTPRequest
var dsn_active_craft: Array = []
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
var audio: AudioStreamPlayer
var audio_queue: PackedVector2Array = PackedVector2Array()
var audio_cursor := 0

# 太阳系视图里的地球连线（DSN 链路那条线）
var link_line: MeshInstance3D
var craft_focus := Vector3.ZERO
var _drag_travel := 0.0
var _touch_positions: Dictionary[int, Vector2] = {}
var _multitouch_active := false
var _pinch_distance := 0.0
var _long_press_index := -1
var _long_press_start := Vector2.ZERO
var _long_press_position := Vector2.ZERO
var _long_press_elapsed := 0.0
var _long_press_consumed := false
var _shot_focus_probe := false
var _shot_focus_sun := false
var _shot_focus_body := ""
## 相机锁定目标："" = 太阳，"voyager2" = 跟随探测器，其余为天体名。
var focus_target := ""
var btn_focus: OptionButton
var focus_note := ""
var _syncing_slider := false
var _probe_in_range := true


func _ready() -> void:
	# 数据包缺失时的 FATAL 屏没法靠正常流程截图（那时候 _ready 直接返回了），
	# 给它一个专用钩子，方便和设计稿对图。
	if "--fatalshot" in OS.get_cmdline_user_args():
		fatal_error = "res://data/metadata.json 不存在"
		_load_settings()
		_build_ui()
		_run_fatal_shot.call_deferred()
		return

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
	# 默认落在真实"现在"。星历现在覆盖到 2060，取末端会开在几十年后。
	jd_now = clampf(JDTime.now_jd(), jd_min, jd_max)

	_load_settings()
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
	if "--orbittest" in OS.get_cmdline_user_args():
		_run_orbit_selftest.call_deferred()
	if "--ringtest" in OS.get_cmdline_user_args():
		_run_ring_selftest.call_deferred()
	if "--scaletest" in OS.get_cmdline_user_args():
		_run_scale_selftest.call_deferred()
	if "--focustest" in OS.get_cmdline_user_args():
		_run_focus_selftest.call_deferred()
	if "--skytest" in OS.get_cmdline_user_args():
		_run_sky_selftest.call_deferred()
	if "--hudtest" in OS.get_cmdline_user_args():
		_run_hud_selftest.call_deferred()
	print("孪生体就绪：%d 天体，%d 组件，时间跨度 %s .. %s" % [
		eph.bodies.size(), eph.components.size(),
		JDTime.format_date_short(jd_min), JDTime.format_date_short(jd_max)])


func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.background_color = Color(0.015, 0.017, 0.028)
	env.sky = _build_sky()
	# 环境光仍取常量色，不用 AMBIENT_SOURCE_SKY：让银河去照亮行星会把
	# 夜面染成一片灰紫，而且亮度随相机朝向变 —— 一转视角行星就变色。
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
	# near/far 每帧按相机距离重算，见 _update_camera。
	#
	# 写死 near=0.05 曾经把整颗地球裁掉：锁定地球时相机距离只有 0.0411 个
	# 单位，比近裁剪面还近，地球直接消失，只剩月球（它在 0.05 之外）挂在
	# 画面上。场景跨度从 0.004 到 3000 个单位，跨了六个数量级，固定的
	# near/far 不可能同时成立。
	camera.far = 60000.0
	camera.near = 0.05
	add_child(camera)


## 天穹。银河全天图按银道 -> 黄道 -> 世界坐标对齐，见 shaders/sky.gdshader。
func _build_sky() -> Sky:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/sky.gdshader")
	mat.set_shader_parameter("panorama", load(TEX_MILKY_WAY))
	var rows := _galactic_rows()
	mat.set_shader_parameter("gal_row0", rows[0])
	mat.set_shader_parameter("gal_row1", rows[1])
	mat.set_shader_parameter("gal_row2", rows[2])
	var sky := Sky.new()
	sky.sky_material = mat
	# 天穹不参与辐照度烘焙（环境光走常量色），把烘焙尺寸压到最小省显存。
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	sky.process_mode = Sky.PROCESS_MODE_REALTIME
	return sky


## 世界坐标（黄道 J2000，见 _to_units）-> 银道坐标的旋转矩阵，返回三个行向量。
##
## 复合三步，每步都是标准量，没有拟合值：
##   1. 世界 -> 黄道：_to_units 把黄道 (x,y,z) 摆成 (x, z, -y)，逆变换是
##      (gx, -gz, gy)。行列式 +1，是纯旋转，不含镜像 —— 这一点必须成立，
##      否则银河会左右翻转而肉眼很难发现。
##   2. 黄道 -> 赤道：绕 X 轴转黄赤交角 23.4392911°（IAU 2006，J2000）。
##   3. 赤道 -> 银道：Hipparcos/ICRS 标准矩阵（银北极 RA 192.85948°、
##      Dec +27.12825°，天北极银经 122.93192°）。
##
## 正确性由 --skytest 校验（银心落在贴图正中、黄北极落在 l=96.4°/b=+29.8°）。
func _galactic_rows() -> Array:
	# 赤道 -> 银道（ICRS，行优先）
	var ag := [
		Vector3(-0.0548755604162154, -0.8734370902348850, -0.4838350155487132),
		Vector3(0.4941094278755837, -0.4448296299600112, 0.7469822444972189),
		Vector3(-0.8676661490190047, -0.1980763734312015, 0.4559837761750669),
	]
	var eps := deg_to_rad(23.4392911)
	var ce := cos(eps)
	var se := sin(eps)
	# 黄道 -> 赤道 绕 X，再右乘 世界 -> 黄道 的置换，一次算完
	# 世界 -> 黄道: ecl = (w.x, -w.z, w.y)
	# 黄道 -> 赤道: eq  = (e.x, ce*e.y - se*e.z, se*e.y + ce*e.z)
	# 合成后作用在世界向量 w 上：
	#   eq.x = w.x
	#   eq.y = -ce*w.z - se*w.y
	#   eq.z = -se*w.z + ce*w.y
	var m := [
		Vector3(1.0, 0.0, 0.0),
		Vector3(0.0, -se, -ce),
		Vector3(0.0, ce, -se),
	]
	var out := []
	for i in 3:
		var r: Vector3 = ag[i]
		out.append(Vector3(
			r.x * m[0].x + r.y * m[1].x + r.z * m[2].x,
			r.x * m[0].y + r.y * m[1].y + r.z * m[2].y,
			r.x * m[0].z + r.y * m[1].z + r.z * m[2].z))
	return out


## 世界方向 -> 银河贴图 UV。与 sky.gdshader 里的算式必须一致，--skytest 校验。
func _galactic_uv(world_dir: Vector3) -> Vector2:
	var rows := _galactic_rows()
	var d := world_dir.normalized()
	var r0: Vector3 = rows[0]
	var r1: Vector3 = rows[1]
	var r2: Vector3 = rows[2]
	var g := Vector3(r0.dot(d), r1.dot(d), r2.dot(d)).normalized()
	var l := atan2(g.y, g.x)
	var b := asin(clampf(g.z, -1.0, 1.0))
	return Vector2(fposmod(0.5 - l / TAU, 1.0), 0.5 + b / PI)


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
	sun_mat.set_shader_parameter("albedo_tex", load(TEX_SUN))
	sun_mat.set_shader_parameter("use_tex", true)
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

	# 先建行星，再建卫星（卫星要挂在母星下面）。
	for b in eph.bodies:
		if bool(b["is_spacecraft"]) or eph.satellites.has(String(b["name"])):
			continue
		_build_body(b, null)

	# 卫星：挂在母星 pivot 下，位置用「相对母星的偏移 × 放大倍数」。
	#
	# 为什么要放大偏移：行星半径被夸张了约 620 倍，而卫星轨道半径按真实比例
	# 只有零点零几个单位 —— 木卫一轨道 0.028 单位，而木星的渲染半径是 2.9 个
	# 单位，卫星会整个埋在行星里面。把偏移按**同一个倍数**放大，整个卫星系统
	# 就被等比放大，内部几何比例保持正确（木卫一在 6.03 个木星半径处，真值）。
	for b in eph.bodies:
		var nm := String(b["name"])
		if not eph.satellites.has(nm):
			continue
		var parent := String(eph.satellites[nm]["parent"])
		if not planet_nodes.has(parent):
			continue
		_build_body(b, planet_nodes[parent])
		_rebuild_satellite_orbit(nm)

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


## 建一个天体。parent 非空时表示这是卫星，挂在母星 pivot 下。
func _build_body(b: Dictionary, parent: Node3D) -> void:
	var nm := String(b["name"])
	var prof: Dictionary = eph.profiles.get(nm, {})
	var is_sat := parent != null

	# 卫星的半径下限取得比行星小得多：行星下限 0.5 会把木卫一撑到木星的
	# 0.17 倍（真值 0.025），比例失真 7 倍。0.06 让主要卫星落在真实比例上。
	# 网格按**真实**半径建，视觉放大交给 tilt 节点的 scale，这样卫星（挂在
	# pivot 下）完全不受放大影响，保持真实轨道尺度。
	var real_units := float(b["mean_radius_km"]) / eph.au_km * AU_UNITS
	var radius_units := maxf(real_units, 1e-9)

	var pivot := Node3D.new()
	pivot.name = nm
	if is_sat:
		parent.add_child(pivot)
	else:
		system_root.add_child(pivot)

	var tilt := Node3D.new()
	tilt.rotation_degrees = Vector3(0, 0, float(prof.get("obliquity_deg", 0.0)))
	pivot.add_child(tilt)

	var node := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius_units
	mesh.height = radius_units * 2.0
	mesh.radial_segments = 48 if not is_sat else 32
	mesh.rings = 24 if not is_sat else 16
	node.mesh = mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var sc: Array = prof.get("surface_color", [0.7, 0.7, 0.7])
	var col := Color(float(sc[0]), float(sc[1]), float(sc[2]))
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/planet.gdshader")
	mat.set_shader_parameter("base_color", col)
	mat.set_shader_parameter("kind", KIND_ID.get(String(prof.get("kind", "rocky")), 0))
	# 有真实贴图的走贴图，没有的（七颗卫星）保持程序化。kind 仍然照传：
	# 贴图缺失时它就是唯一的外观依据，不能因为"现在用贴图了"就删掉。
	if BODY_TEXTURE.has(nm):
		mat.set_shader_parameter("albedo_tex", load(BODY_TEXTURE[nm]))
		mat.set_shader_parameter("use_tex", true)
	if nm == "earth":
		mat.set_shader_parameter("night_tex", load(TEX_EARTH_NIGHT))
		mat.set_shader_parameter("night_strength", 0.85)
		mat.set_shader_parameter("cloud_tex", load(TEX_EARTH_CLOUDS))
		mat.set_shader_parameter("cloud_strength", 0.80)
	var ac: Array = prof.get("atmosphere_color", [0.5, 0.7, 1.0])
	mat.set_shader_parameter("atmo_color", Color(float(ac[0]), float(ac[1]), float(ac[2])))
	mat.set_shader_parameter("atmo_power", float(prof.get("atmosphere_power", 0.0)))
	match nm:
		"jupiter":
			mat.set_shader_parameter("band_tint", Color(0.62, 0.38, 0.24))
			mat.set_shader_parameter("band_freq", 11.0)
			mat.set_shader_parameter("spot_size", 0.30)
			mat.set_shader_parameter("spot_color", Color(0.80, 0.34, 0.20))
		"saturn":
			mat.set_shader_parameter("band_tint", Color(0.72, 0.56, 0.34))
			mat.set_shader_parameter("band_freq", 8.0)
		"uranus":
			mat.set_shader_parameter("band_freq", 4.0)
		"neptune":
			mat.set_shader_parameter("band_freq", 6.0)
			mat.set_shader_parameter("spot_size", 0.26)
			mat.set_shader_parameter("spot_lat", -0.42)
			mat.set_shader_parameter("spot_color", Color(0.10, 0.16, 0.42))
	node.material_override = mat
	tilt.add_child(node)

	planet_nodes[nm] = pivot
	planet_spin[nm] = node
	planet_tilt[nm] = tilt
	body_real_radius[nm] = real_units

	var rings: Array = prof.get("rings", [])
	if not rings.is_empty():
		tilt.add_child(_build_ring_system(nm, prof, real_units))

	if nm in ORBIT_BODIES:
		system_root.add_child(_build_path_mesh(nm, jd_min, jd_max,
			col.lerp(Color(0.35, 0.85, 1.0), 0.55), Color(0.55, 0.35, 1.0), 700,
			0.22, 0.0009, 2.0))


## 通用环系。土星 / 天王星 / 海王星共用一套，环带边界来自 Go 侧真实数据。
func _build_ring_system(nm: String, prof: Dictionary, planet_radius_units: float) -> MeshInstance3D:
	var bands: Array = prof["rings"]
	var planet_km := float(prof["equatorial_radius_km"])
	var floor_km := eph.ring_render_floor_km

	# 整个环系的内外缘
	var lo_km := INF
	var hi_km := -INF
	for band in bands:
		lo_km = minf(lo_km, float(band["inner_km"]))
		hi_km = maxf(hi_km, float(band["outer_km"]))

	var inner := planet_radius_units * lo_km / planet_km
	var outer := planet_radius_units * hi_km / planet_km
	var segs := 256

	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	for i in segs + 1:
		var a := TAU * float(i) / float(segs)
		var ca := cos(a)
		var sa := sin(a)
		verts.append(Vector3(ca * inner, 0.0, sa * inner))
		uvs.append(Vector2(0.0, 0.0)); norms.append(Vector3.UP)
		verts.append(Vector3(ca * outer, 0.0, sa * outer))
		uvs.append(Vector2(1.0, 0.0)); norms.append(Vector3.UP)
	for i in segs:
		var bi := i * 2
		idx.append_array([bi, bi + 1, bi + 2, bi + 1, bi + 3, bi + 2])

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
	mi.name = nm + "_rings"
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# 把环带打包成纹理送给着色器：一行像素，R 通道存不透明度。
	# 这样任意多道环/缝都能表达，不必为每颗行星写一套 uniform。
	var w := 1024
	var img := Image.create(w, 1, false, Image.FORMAT_RF)
	for x in w:
		var r_km := lerpf(lo_km, hi_km, float(x) / float(w - 1))
		var op := 0.0
		for band in bands:
			var b_lo := float(band["inner_km"])
			var b_hi := float(band["outer_km"])
			# 极窄的环按渲染下限加宽，否则任何缩放下都细于一个像素。
			if b_hi - b_lo < floor_km:
				var mid := (b_lo + b_hi) * 0.5
				b_lo = mid - floor_km * 0.5
				b_hi = mid + floor_km * 0.5
			if r_km >= b_lo and r_km <= b_hi:
				if bool(band.get("is_gap", false)):
					op = minf(op, float(band["opacity"]))
				else:
					op = maxf(op, float(band["opacity"]))
		img.set_pixel(x, 0, Color(op, 0, 0))
	var tex := ImageTexture.create_from_image(img)

	var rt: Array = prof.get("ring_tint", [0.86, 0.79, 0.66])
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/rings.gdshader")
	mat.set_shader_parameter("ring_color", Color(float(rt[0]), float(rt[1]), float(rt[2])))
	mat.set_shader_parameter("band_lut", tex)
	mat.set_shader_parameter("planet_radius", planet_radius_units)
	# 只有土星有对应贴图。贴图的径向跨度和我们的 LUT 基本一致：卡西尼缝在
	# 贴图上的 alpha 低谷落在 u≈0.70，而按 internal/bodies 的环带数据算
	# (117580-74658)/(136775-74658)=0.691 —— 两者对得上，才敢把 U 直接当
	# 归一化半径用。
	if nm == "saturn":
		mat.set_shader_parameter("color_tex", load(TEX_SATURN_RING))
		mat.set_shader_parameter("use_color_tex", true)
	mi.material_override = mat
	return mi


## 卫星轨道环。
##
## **采样充分时直接用星历画**，而不是用开普勒要素。
##
## 为什么：要素是固定曆元（J2000）的，抓不住轨道面进动。月球的交点退行周期
## 18.6 年，实测轨道面法向在 1977 和 2026 与星历相差 6-10 度 —— 环和天体明显
## 错开，用户一眼就看出「月球不在轨道上」。用星历画则精确、自带进动、而且
## **必然与天体的绘制位置一致**（同一个数据源）。
##
## 采样不足的卫星（木卫一 1.77 天一圈，日采样连半个样本都不到）退回要素，
## 因为那时星历本身就是混叠的 —— 此时天体本体也被隐藏，只留环示意。
func _rebuild_satellite_orbit(nm: String) -> void:
	var parent := String(eph.satellites[nm]["parent"])
	if not planet_nodes.has(parent):
		return
	var period := float(eph.satellites[nm]["period_days"])
	var n := 220
	var pts := PackedVector3Array()
	var s := AU_UNITS / eph.au_km
	var from_ephemeris: bool = eph.satellite_position_is_resolved(nm, jd_now)

	if from_ephemeris:
		# 以当前时刻为中心取一整个周期。
		for i in n:
			var jd := jd_now + period * (float(i) / float(n - 1) - 0.5)
			var ms := eph.state_at(nm, jd)
			var ps := eph.state_at(parent, jd)
			var dx := float(ms["pos"][0]) - float(ps["pos"][0])
			var dy := float(ms["pos"][1]) - float(ps["pos"][1])
			var dz := float(ms["pos"][2]) - float(ps["pos"][2])
			pts.append(Vector3(dx * s, dz * s, -dy * s))
	else:
		var obl := float(eph.profiles.get(parent, {}).get("obliquity_deg", 0.0))
		for i in n:
			var jd2 := float(eph.satellites[nm]["epoch_jd"]) + period * float(i) / float(n - 1)
			var off: Array = eph.satellite_offset_km(nm, jd2, obl)
			pts.append(Vector3(float(off[0]) * s, float(off[2]) * s, -float(off[1]) * s))

	if satellite_orbits.has(nm) and is_instance_valid(satellite_orbits[nm]):
		(satellite_orbits[nm] as Node3D).queue_free()
	# 星历画的环用实线冷色，要素推的环用更暗的紫色 —— 一眼能区分
	# 「这条是实测轨迹」还是「这条只是要素示意」。
	var mi := _build_ribbon(pts, 0.0007,
		Color(0.30, 0.80, 0.95) if from_ephemeris else Color(0.42, 0.30, 0.62),
		Color(0.55, 0.55, 0.95) if from_ephemeris else Color(0.30, 0.22, 0.48),
		0.34 if from_ephemeris else 0.20, 1.0)
	mi.name = nm + "_orbit"
	planet_nodes[parent].add_child(mi)
	satellite_orbits[nm] = mi
	_orbit_built_jd[nm] = jd_now
	_orbit_from_ephemeris[nm] = from_ephemeris
	_orbit_points[nm] = pts


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
	hud = Hud.new()
	layer.add_child(hud)

	if fatal_error != "":
		hud.build_fatal(fatal_error)
		return

	# 相机锁定的候选目标：太阳、探测器，然后行星在前、卫星按母星缩进排后面。
	var focus_items: Array = [
		{"label": "太阳", "meta": ""},
		{"label": "★ 跟随旅行者2号", "meta": "voyager2"},
	]
	for b in eph.bodies:
		var nm := String(b["name"])
		if bool(b["is_spacecraft"]) or eph.satellites.has(nm):
			continue
		focus_items.append({"label": String(b["label"]), "meta": nm})
	for b in eph.bodies:
		var nm2 := String(b["name"])
		if not eph.satellites.has(nm2):
			continue
		var parent_label := String(eph.body_by_name.get(
			String(eph.satellites[nm2]["parent"]), {}).get("label", ""))
		focus_items.append({
			"label": "  └ %s（%s 的卫星）" % [String(b["label"]), parent_label],
			"meta": nm2,
		})

	hud.build(jd_min, jd_max, eph.events, focus_items, "%d 目标" % focus_items.size())
	slider = hud.timeline
	btn_focus = hud.btn_focus
	spark_power = hud.spark_power
	spark_dist = hud.spark_dist
	spark_rx = hud.spark_rx

	slider.value_changed.connect(_on_slider_changed)
	slider.value = jd_now
	hud.play_pressed.connect(_on_play_pressed)
	hud.mode_pressed.connect(func(craft: bool) -> void:
		_set_mode(ViewMode.CRAFT if craft else ViewMode.SYSTEM))
	hud.focus_probe_pressed.connect(func() -> void: _set_focus("voyager2"))
	hud.focus_sun_pressed.connect(func() -> void: _set_focus(""))
	hud.dsn_pressed.connect(_on_dsn_pressed)
	hud.tone_pressed.connect(_play_calibration)
	hud.scan_pressed.connect(_play_scanlines)
	hud.spin_pressed.connect(func() -> void: record_spinning = not record_spinning)
	btn_focus.item_selected.connect(func(i: int) -> void:
		_set_focus(String(btn_focus.get_item_metadata(i))))
	hud.ui_scale_picked.connect(_set_ui_scale)
	hud.set_ui_scale_selection(ui_scale)


func _on_slider_changed(v: float) -> void:
	if _syncing_slider:
		return
	jd_now = v
	_refresh()


func _on_play_pressed() -> void:
	playing = not playing
	hud.set_playing(playing)


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
		if focus_target == "":
			# 自动取景：按探测器当前距离取，免得一进场是一片空旷。
			var d := JDTime.vec_len(eph.state_at("voyager2", jd_now)["pos"]) / eph.au_km * AU_UNITS
			cam_dist = clampf(d * 1.5, 120.0, 6000.0)
		hud.set_mode(false)
	else:
		cam_dist = 34.0
		hud.set_mode(true)
	_update_camera()


func _process(delta: float) -> void:
	if fatal_error != "":
		return
	_update_long_press(delta)
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
			hud.set_playing(false)
		_syncing_slider = true
		slider.value = jd_now
		_syncing_slider = false
		_refresh()


func _refresh() -> void:
	var probe := eph.state_at("voyager2", jd_now)
	var earth := eph.state_at("earth", jd_now)
	var in_range: bool = probe["in_range"]

	for name_str in planet_nodes:
		var pv: Node3D = planet_nodes[name_str]
		if eph.satellites.has(name_str):
			_place_satellite(name_str, pv)
			_maybe_refresh_orbit(name_str)
		else:
			var st := eph.state_at(name_str, jd_now)
			pv.position = _to_units(st["pos"])
			pv.visible = st["in_range"]
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

	# ---- HUD 数值 ----
	# 注意光时用的是**距地球**的，不是距太阳的。指令和遥测走的是地球这条线，
	# 早先按距日算是错的（143 AU 时两者差约 1 AU，即 8 分多钟）。
	var range_au := float(trk["range_au"])
	var owlt := float(trk["owlt_sec"])
	var rtlt := float(trk["rtlt_sec"])
	var helio_au := helio_km / eph.au_km
	var sep := float(trk["sep_deg"])

	var vals := {
		"date": JDTime.format_date_short(jd_now),
		"time": JDTime.format_time(jd_now),
		"jdline": "JD %.4f TDB  ·  任务第 %d 天" % [jd_now, int(floor(jd_now - jd_min))],
		"range_au": "%.7f" % range_au,
		"range_km": "%s km" % JDTime.sci(float(trk["range_km"]), 5),
		"range_rate": "%+.4f km/s" % float(trk["range_rate_kms"]),
		"doppler": "↳ 这就是 DSN 的多普勒观测量 · X 波段 %+.1f Hz @ 8.420 GHz"
			% float(trk["doppler_hz"]),
		"helio": "%.2f" % helio_au,
		"speed": "%.3f" % speed,
		"watts": "%.1f" % float(pw["watts"]),
		"fuel_pct": "%.1f%%" % (float(pw["fuel_fraction"]) * 100.0),
		"conv_pct": "%.1f%%" % (float(pw["converter_fraction"]) * 100.0),
		"ra": "%.3f°" % float(trk["ra_deg"]),
		"dec": _typo_minus("%+.3f°" % float(trk["dec_deg"])),
		"sep": "%.2f°" % sep,
		"fspl": "%.1f" % float(link["fspl_db"]),
		"rx": "%.2f" % float(link["rx_dbm"]),
		"v_now": "%.3f" % float(orb["speed_kms"]),
		"v_esc": "%.3f" % float(orb["v_escape_kms"]),
	}

	# 光时的单位跟着量级走：飞掠木星时是分钟，现在是小时／天。
	var op := _time_pair(owlt)
	vals["owlt"] = op[0]
	vals["owlt_unit"] = op[1]
	var rp := _time_pair(rtlt)
	vals["rtlt"] = rp[0]
	vals["rtlt_unit"] = rp[1]

	if bool(orb["escaping"]):
		vals["v_inf"] = "双曲剩余速度 %.3f km/s · 永不返回" % float(orb["v_inf_kms"])
		vals["escape"] = "已达逃逸条件 ESCAPE"
	else:
		vals["v_inf"] = "仍在束缚轨道上"
		vals["escape"] = "尚未逃逸 BOUND"
	vals["heliopause"] = ("已进入星际空间" if bool(orb["beyond_heliopause"])
		else "仍在日球层内")
	vals["sep_note"] = ("↳ 天线往哪儿指 · SEP < 5° 时链路被太阳噪声压制" if sep >= 5.0
		else "↳ SEP %.2f° —— 接近太阳合，链路正被太阳噪声压制" % sep)

	var near := Geometry.nearest_body(probe["pos"], eph.bodies,
		func(n: String, j: float) -> Dictionary: return eph.state_at(n, j), jd_now)
	if String(near["name"]) != "":
		vals["near_name"] = String(near["label"])
		vals["near_dist"] = "· %s km（%.4f AU）" % [
			JDTime.sci(float(near["distance_km"])),
			float(near["distance_km"]) / eph.au_km]
	else:
		vals["near_name"] = "—"
		vals["near_dist"] = ""

	hud.set_values(vals)
	hud.set_escaping(bool(orb["escaping"]))
	hud.set_bars(float(pw["fuel_fraction"]), float(pw["converter_fraction"]))
	hud.set_stations(Geometry.visible_stations(float(trk["dec_deg"])))
	if not _syncing_slider:
		slider.value = jd_now

	# ---- 数据来源与相机锁定的附注 ----
	var notes := PackedStringArray()
	if not in_range:
		notes.append("⚠ 该时刻超出星历覆盖范围")
	if eph.satellites.has(focus_target):
		var src_ok: bool = bool(_orbit_from_ephemeris.get(focus_target, false))
		notes.append("锁定 %s：轨道环数据源 %s" % [_focus_label(),
			"归档星历（精确，含轨道面进动）" if src_ok
			else "开普勒要素示意（相位不可信）"])
	if focus_note != "":
		notes.append(focus_note)
	hud.set_focus_note("\n".join(notes))

	# ---- 屏幕空间标注（探测器准星 / 地球 / 下行链路线）----
	# 只更新文字，屏幕坐标由 _project_annotations() 在相机变动时算 ——
	# 相机可以在不刷新星历的情况下单独拖动，投影不能只在这儿算一次。
	_probe_in_range = in_range
	var an := hud.annotations
	an.probe_line2 = "%.2f AU · %.3f km/s" % [helio_au, speed]
	an.probe_line3 = "NAIF -32 · %s" % (
		"星际空间" if bool(orb["beyond_heliopause"]) else "日球层内")
	var op2 := _time_pair(owlt)
	an.link_label = "DOWNLINK · %s %s 光时" % [op2[0], _unit_abbr(String(op2[1]))]

	# ---- 曲线标记 ----
	var ratio := (jd_now - jd_min) / maxf(1e-9, jd_max - jd_min)
	spark_power.marker_ratio = clampf(ratio, 0.0, 1.0)
	spark_power.queue_redraw()
	spark_dist.marker_ratio = clampf(ratio, 0.0, 1.0)
	spark_dist.queue_redraw()
	spark_rx.marker_ratio = clampf(ratio, 0.0, 1.0)
	spark_rx.queue_redraw()

	if selected_component == "":
		hud.set_component("—", "右键点选部件，查看 ComponentID、归属判据与置信度。"
			+ "试试舱体侧面那张金唱片。", "", "未选中")


## "-60.108°" -> "−60.108°"。稿子里的负号是排版负号 U+2212，不是 ASCII 连字符。
func _typo_minus(t: String) -> String:
	return t.replace("-", "−")


## 屏幕标注里用缩写单位（稿子写的是 "20.01 h 光时"）。
func _unit_abbr(u: String) -> String:
	match u:
		"秒": return "s"
		"分钟": return "min"
		"小时": return "h"
		"天": return "d"
	return u


## 时长拆成 [数值, 单位]，喂给四格里的大数字 + 小单位。
func _time_pair(sec: float) -> Array:
	if sec <= 0.0:
		return ["—", ""]
	if sec < 120.0:
		return ["%.1f" % sec, "秒"]
	if sec < 7200.0:
		return ["%.1f" % (sec / 60.0), "分钟"]
	if sec < 86400.0:
		return ["%.2f" % (sec / 3600.0), "小时"]
	return ["%.2f" % (sec / 86400.0), "天"]

## 行星和探测器按真实比例在这个尺度下只有零点几个单位，拉远之后就是几个
## 亚像素的点，等于看不见。所以标记随相机距离等比放大 —— 这是示意尺寸，
## 不是真实比例，行星本体的相对大小仍然保留。
## 当前的行星夸张倍数。对数插值：近处 1（真实比例），远处 EXA_MAX。
func _exaggeration() -> float:
	var lo := EXA_NEAR_DIST
	var hi := EXA_FAR_DIST
	if cam_dist <= lo:
		return EXA_MIN
	if cam_dist >= hi:
		return EXA_MAX
	var t := log(cam_dist / lo) / log(hi / lo)
	return EXA_MIN * pow(EXA_MAX / EXA_MIN, t)


## 某颗行星系统实际使用的放大倍数。
##
## 全局倍数会被**该系统最内侧卫星的轨道**卡住上限：天卫五只在 5.08 个天王星
## 半径处，6 倍放大后天王星的渲染半径就超过了它的轨道，直接把它吞掉。所以
## 上限取「最内侧轨道的 35%」。
##
## 母星和它的全部卫星共用这一个倍数，所以彼此的**相对大小仍然真实**。
func _system_exaggeration(parent: String) -> float:
	var exa := _exaggeration()
	if not _showing_satellites(parent):
		return exa
	var r: float = body_real_radius.get(parent, 0.0)
	var innermost := _innermost_orbit_units(parent)
	if r <= 0.0 or innermost == INF:
		return exa
	return minf(exa, innermost * 0.35 / r)


func _innermost_orbit_units(parent: String) -> float:
	var v := INF
	for nm in eph.satellites:
		if String(eph.satellites[nm]["parent"]) != parent:
			continue
		v = minf(v, float(eph.satellites[nm]["semi_major_km"]) / eph.au_km * AU_UNITS)
	return v


func _outermost_orbit_units(parent: String) -> float:
	var v := 0.0
	for nm in eph.satellites:
		if String(eph.satellites[nm]["parent"]) != parent:
			continue
		v = maxf(v, float(eph.satellites[nm]["semi_major_km"]) / eph.au_km * AU_UNITS)
	return v


## 某颗行星的卫星系统此刻是否该显示。
##
## 判据是「最外侧卫星轨道在画面里占得下」：拉远看太阳系时整个卫星系统只有
## 亚像素大小，画出来只是一团噪声，不如不画。
func _showing_satellites(parent: String) -> bool:
	var outer := _outermost_orbit_units(parent)
	if outer <= 0.0:
		return false
	return cam_dist < outer * 12.0


func _scale_markers() -> void:
	var global_exa := _exaggeration()
	for n in planet_tilt:
		var t: Node3D = planet_tilt[n]
		var r: float = body_real_radius.get(n, 0.0)
		# 卫星跟着母星用同一个系统倍数，行星用自己系统的倍数。
		var owner_name: String = n
		if eph.satellites.has(n):
			owner_name = String(eph.satellites[n]["parent"])
		var sc := _system_exaggeration(owner_name) if (
			eph.satellites.has(n) or _outermost_orbit_units(n) > 0.0) else global_exa
		# 屏幕最小尺寸下限。
		#
		# 这一项会**破坏**母星与卫星之间的尺寸比例，而且是不得不为：天卫五
		# 真实直径只有 472 km，在框住它 12.98 万公里轨道的视距下只有四分之一
		# 个像素。不给下限就是彻底看不见。给了下限，它相对天王星就被撑大约
		# 3.8 倍。
		#
		# 这里的取舍是：**轨道尺度保持真实**（这是最要紧的，也是「月球离婚」
		# 那个 bug 的正解），天体本身允许被撑到最小可见尺寸。撑大的倍数记在
		# _size_inflation 里，自检会把它逐个打出来，不藏。
		var inflation := 1.0
		if r > 0.0:
			var min_units := cam_dist * 0.0016
			var floored := maxf(sc, min_units / r)
			inflation = floored / maxf(sc, 1e-12)
			sc = floored
		_size_inflation[n] = inflation
		# 卫星另外受一条约束：渲染半径不能超过自身轨道半径的 15%。
		if eph.satellites.has(n):
			var a_units := float(eph.satellites[n]["semi_major_km"]) / eph.au_km * AU_UNITS
			sc = minf(sc, a_units * 0.15 / maxf(r, 1e-12))
		t.scale = Vector3.ONE * minf(sc, 3.0e5)

	for nm in eph.satellites:
		if not planet_nodes.has(nm):
			continue
		var parent := String(eph.satellites[nm]["parent"])
		var show := _showing_satellites(parent)
		if satellite_orbits.has(nm):
			(satellite_orbits[nm] as Node3D).visible = show
		_satellite_allowed[nm] = show

	# 探测器的缩放分两种情形。
	#
	# 聚焦在它身上时给一个固定的世界尺寸下限，这样能一路推近检视部件。
	# 但**不**聚焦它时必须走恒定视角大小 —— 否则在行星系统视距下（比如
	# 锁定木星时相机距离只有 0.2 个单位）那个 0.50 的下限会让探测器的碟面
	# 达到 1.9 个单位，而木星的渲染半径只有 0.0099，探测器比木星大 190 倍，
	# 一堆白色结构糊满整个画面。
	var pk: float
	if focus_target == "voyager2":
		pk = clampf(maxf(0.50, cam_dist * 0.0011), 0.50, 5.0)
	else:
		pk = clampf(cam_dist * 0.012, 1.0e-7, 5.0)
	if probe_model != null:
		probe_model.scale = Vector3.ONE * pk
	var halo_on := cam_dist > 140.0
	probe_marker.visible = halo_on
	if halo_on:
		probe_marker.scale = Vector3.ONE * clampf(cam_dist * 0.0075, 1.0, 46.0)


## 卫星定位。
##
## 位置一律取自**星历**（真实定轨数据），不用开普勒要素 —— internal/orbit
## 的测试量过，那套要素在飞掠时刻的相位误差高达半长轴的 200%，也就是把卫星
## 画到行星的另一侧。要素只用来画轨道环。
##
## 但星历本身也有前提：木卫一 1.77 天一圈，日采样只有 0.56 个样本每圈，
## 插出来是混叠的垃圾。所以采样不足 8 个样本每圈时**隐藏卫星本体**，只留
## 轨道环 —— 宁可不画，也不画错。四次飞掠窗口有 30 分钟采样，那里是准的。
func _place_satellite(nm: String, pivot: Node3D) -> void:
	var parent := String(eph.satellites[nm]["parent"])
	var ps := eph.state_at(parent, jd_now)
	var ms := eph.state_at(nm, jd_now)
	var resolved: bool = eph.satellite_position_is_resolved(nm, jd_now)
	pivot.visible = (bool(ms["in_range"]) and bool(ps["in_range"]) and resolved
		and bool(_satellite_allowed.get(nm, false)))
	if not pivot.visible:
		return
	# 真实比例的相对偏移。
	var s := AU_UNITS / eph.au_km
	var dx := float(ms["pos"][0]) - float(ps["pos"][0])
	var dy := float(ms["pos"][1]) - float(ps["pos"][1])
	var dz := float(ms["pos"][2]) - float(ps["pos"][2])
	pivot.position = Vector3(dx * s, dz * s, -dy * s)


## 时间走动或数据可用性变化时，按需重建卫星轨道环。
##
## 不每帧重建：一条环 220 个采样点、每点两次星历查询，8 颗卫星每帧重建会
## 明显掉帧。只在时间移动超过周期的 5%、或者数据来源发生切换时才重建。
func _maybe_refresh_orbit(nm: String) -> void:
	if not _satellite_allowed.get(nm, false):
		return
	var period := float(eph.satellites[nm]["period_days"])
	var last: float = float(_orbit_built_jd.get(nm, -1.0e18))
	var resolved: bool = eph.satellite_position_is_resolved(nm, jd_now)
	var source_changed: bool = bool(_orbit_from_ephemeris.get(nm, false)) != resolved
	if source_changed or absf(jd_now - last) > period * 0.05:
		_rebuild_satellite_orbit(nm)


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
	var hours: float = float(eph.profiles.get(name_str, {}).get("rotation_hours", 0.0))
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
		target = _focus_position()
		if _shot_focus_probe:
			target = probe_root.global_position
		elif _shot_focus_sun:
			target = Vector3.ZERO
		elif _shot_focus_body != "" and planet_nodes.has(_shot_focus_body):
			target = (planet_nodes[_shot_focus_body] as Node3D).global_position
	var dir := Vector3(
		cos(cam_pitch) * sin(cam_yaw), sin(cam_pitch), cos(cam_pitch) * cos(cam_yaw))
	camera.position = target + dir * cam_dist
	camera.look_at(target, Vector3.UP)
	# 近/远裁剪面都按相机距离缩放，而且**比例必须收在安全范围**。
	#
	# 场景跨度从 0.004 到 3000 个单位，跨六个数量级，固定的 near/far 不可能
	# 同时成立：写死 near=0.05 会把锁定地球时（相机距离 0.0411）的地球整个
	# 裁掉。但第一版修正取 near=cam_dist·0.0012、far=8000，比例达到 1.6e8，
	# 深度精度直接崩掉，画面全空 —— 从一个极端跳到另一个极端。
	#
	# 现在固定比例 8e4：近处看得到贴脸的天体，远处装得下该视距下有意义的
	# 内容。行星系统视图里看不到整条航迹，这是可接受的取舍。
	camera.near = clampf(cam_dist * 0.01, 1.0e-5, 20.0)
	camera.far = camera.near * 8.0e4
	_project_annotations()


## 把探测器和地球的 3D 位置投影到屏幕，喂给 HUD 的准星标注。
## 相机一动就要重算，所以挂在 _update_camera() 尾巴上。
func _project_annotations() -> void:
	if hud == null or hud.annotations == null or camera == null:
		return
	var an := hud.annotations
	if mode != ViewMode.SYSTEM or probe_root == null:
		an.probe_on = false
		an.earth_on = false
		return
	var pp := probe_root.global_position
	an.probe_on = _probe_in_range and not camera.is_position_behind(pp)
	if an.probe_on:
		an.probe_pos = camera.unproject_position(pp)
	if planet_nodes.has("earth"):
		var earth_node: Node3D = planet_nodes["earth"]
		var ep := earth_node.global_position
		an.earth_on = earth_node.visible and not camera.is_position_behind(ep)
		if an.earth_on:
			an.earth_pos = camera.unproject_position(ep)
	else:
		an.earth_on = false


## 当前锁定目标的人类可读名字，外加它是否真的被对准。
func _focus_label() -> String:
	if focus_target == "":
		return "太阳"
	if focus_target == "voyager2":
		return "旅行者 2 号（跟随）"
	var label := String(eph.body_by_name.get(focus_target, {}).get("label", focus_target))
	if planet_nodes.has(focus_target) and not (planet_nodes[focus_target] as Node3D).visible:
		var parent := String(eph.satellites.get(focus_target, {}).get("parent", ""))
		var pl := String(eph.body_by_name.get(parent, {}).get("label", parent))
		return "%s [color=#b06060]（此刻不可定位，已回退到 %s）[/color]" % [label, pl]
	return label


## 当前相机锁定的目标位置。
##
## focus_target 取值：""（太阳/原点）、"voyager2"（跟随探测器）、或任意
## 天体名（含卫星）。卫星是母星 pivot 的子节点，所以要取 global_position。
func _focus_position() -> Vector3:
	if focus_target == "":
		return Vector3.ZERO
	if focus_target == "voyager2":
		return probe_root.global_position
	if planet_nodes.has(focus_target):
		var n: Node3D = planet_nodes[focus_target]
		if n.visible:
			return n.global_position
		# 卫星此刻不可见（星历采样不足以定位它）。回退到**母星**而不是静默
		# 跳回原点 —— 原点是太阳，而取景距离已经被设成 0.006 个单位，相机会
		# 直接钻进太阳内部，画面完全莫名其妙。用户报的「点啥都对准某颗星」
		# 就是这个。
		if eph.satellites.has(focus_target):
			var parent := String(eph.satellites[focus_target]["parent"])
			if planet_nodes.has(parent):
				return (planet_nodes[parent] as Node3D).global_position
	return Vector3.ZERO


## 切换锁定目标，并把相机距离调到能框住它的量级。
## 各颗行星的飞掠历元 —— 只有这些窗口里才有 30 分钟采样，也就是唯一能
## 准确定位内侧卫星的时段。
const ENCOUNTER_DATE := {
	"jupiter": "1979-07-09", "saturn": "1981-08-26",
	"uranus": "1986-01-24", "neptune": "1989-08-25",
}


func _set_focus(target: String) -> void:
	focus_target = target
	focus_note = ""

	# 锁定一颗只有飞掠期才有数据的卫星时，直接把时间轴带到那次飞掠。
	#
	# 这不是取巧：木卫一 1.77 天一圈，日采样只有 0.56 个样本每圈，别处的
	# 位置本来就不该显示。与其让用户对着一个空位置发愣，不如带他去唯一
	# 知道答案的时刻，并说明为什么。
	if target != "" and eph.satellites.has(target):
		if not eph.satellite_position_is_resolved(target, jd_now):
			var parent := String(eph.satellites[target]["parent"])
			var date := String(ENCOUNTER_DATE.get(parent, ""))
			if date != "":
				var jd := _event_jd(date)
				if jd != jd_now:
					_seek(jd)
					focus_note = "已跳到 %s 飞掠 —— 只有这个窗口有 30 分钟采样，别处日采样定不出它的位置" % date
			if focus_note == "":
				focus_note = "该卫星在此刻的星历采样不足以定位，已回退到母星"
	# 按目标的渲染尺寸自动取景，免得锁到月球却还是全太阳系的视距。
	var d := 2400.0
	if target == "voyager2":
		d = 26.0
	elif target != "" and eph.profiles.has(target):
		var prof: Dictionary = eph.profiles[target]
		var body: Dictionary = eph.body_by_name.get(target, {})
		var real_units := float(body.get("mean_radius_km", 1000.0)) / eph.au_km * AU_UNITS
		var r := real_units
		# 取景要把该有的东西都框进来：环系、以及最外侧卫星的轨道。
		var span := r * 40.0
		var rings: Array = prof.get("rings", [])
		if not rings.is_empty():
			var hi := 0.0
			for band in rings:
				hi = maxf(hi, float(band["outer_km"]))
			span = maxf(span, real_units * hi / float(prof["equatorial_radius_km"]) * 3.0)
		for snm in eph.satellites:
			if String(eph.satellites[snm]["parent"]) != target:
				continue
			span = maxf(span, float(eph.satellites[snm]["semi_major_km"]) / eph.au_km * AU_UNITS * 1.6)
		d = maxf(span, 0.006)
	cam_dist = d
	if btn_focus != null:
		for i in btn_focus.item_count:
			if String(btn_focus.get_item_metadata(i)) == target:
				btn_focus.selected = i
				break
	_update_camera()


func _unhandled_input(event: InputEvent) -> void:
	if fatal_error != "":
		return
	if event is InputEventScreenTouch:
		_handle_screen_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_handle_screen_drag(event as InputEventScreenDrag)
	elif event is InputEventMouseMotion and (event as InputEventMouseMotion).button_mask & MOUSE_BUTTON_MASK_LEFT:
		# 第二根手指抬起后，模拟鼠标的相对位移基准可能已经换到另一根手指；
		# 等整次多指手势结束再恢复旋转，才能避免相机突然甩动。
		if _multitouch_active:
			return
		var mm := event as InputEventMouseMotion
		_drag_travel += mm.relative.length()
		cam_yaw -= mm.relative.x * 0.006
		cam_pitch = clampf(cam_pitch + mm.relative.y * 0.006, -1.45, 1.45)
		_update_camera()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			cam_dist = maxf(cam_dist * 0.88, 0.004)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			cam_dist = minf(cam_dist * 1.14, 40000.0)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed and mode == ViewMode.CRAFT:
			_pick_component(mb.position)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			# 左键按下开始计拖动距离；松手时几乎没动，就当作点选。
			if mb.pressed:
				_drag_travel = 1000000.0 if _multitouch_active else 0.0
			elif not _long_press_consumed and _drag_travel < 6.0 and mode == ViewMode.CRAFT:
				_pick_component(mb.position)
	elif event is InputEventKey and (event as InputEventKey).pressed:
		var k := event as InputEventKey
		if k.keycode == KEY_SPACE:
			_on_play_pressed()
		elif k.keycode == KEY_F:
			_set_focus("voyager2")
		elif k.keycode == KEY_ESCAPE:
			_set_focus("")
		elif k.keycode == KEY_TAB:
			_on_mode_pressed()


func _handle_screen_touch(touch: InputEventScreenTouch) -> void:
	if touch.pressed:
		_touch_positions[touch.index] = touch.position
		if _touch_positions.size() == 1 and not _multitouch_active:
			_long_press_index = touch.index
			_long_press_start = touch.position
			_long_press_position = touch.position
			_long_press_elapsed = 0.0
			_long_press_consumed = false
		elif _touch_positions.size() >= 2:
			_multitouch_active = true
			_pinch_distance = _pinch_pair_distance()
			_cancel_long_press()
			_drag_travel = 1000000.0
		return

	_touch_positions.erase(touch.index)
	if touch.index == _long_press_index:
		if _long_press_consumed:
			_drag_travel = 1000000.0
		_cancel_long_press()
		_long_press_consumed = false
	if _multitouch_active:
		# 捏合中换了一对手指时距离基准也必须重置，否则会把换指误当成缩放。
		_pinch_distance = _pinch_pair_distance() if _touch_positions.size() >= 2 else 0.0
		if _touch_positions.is_empty():
			_multitouch_active = false
			_drag_travel = 1000000.0


func _handle_screen_drag(drag: InputEventScreenDrag) -> void:
	_touch_positions[drag.index] = drag.position
	if _multitouch_active:
		if _touch_positions.size() < 2:
			return
		var distance := _pinch_pair_distance()
		if _pinch_distance > 0.0 and distance > 0.0:
			cam_dist = minf(maxf(cam_dist * _pinch_distance / distance, 0.004), 40000.0)
			_update_camera()
		_pinch_distance = distance
		return
	if drag.index == _long_press_index:
		_long_press_position = drag.position
		if _long_press_start.distance_to(drag.position) > 12.0:
			_cancel_long_press()


func _pinch_pair_distance() -> float:
	if _touch_positions.size() < 2:
		return 0.0
	var indices: Array[int] = []
	for index: int in _touch_positions:
		indices.append(index)
	indices.sort()
	return _touch_positions[indices[0]].distance_to(_touch_positions[indices[1]])


func _update_long_press(delta: float) -> void:
	if _long_press_index < 0 or _long_press_consumed or _multitouch_active:
		return
	if not _touch_positions.has(_long_press_index):
		_cancel_long_press()
		return
	_long_press_elapsed += delta
	if _long_press_elapsed < 0.45:
		return
	if mode == ViewMode.CRAFT:
		_pick_component(_long_press_position)
		_long_press_consumed = true
		_drag_travel = 1000000.0
	else:
		_cancel_long_press()


func _cancel_long_press() -> void:
	_long_press_index = -1
	_long_press_elapsed = 0.0



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


## 把某个部件的契约信息推给 HUD。只管文字，不碰 3D 材质和相机 ——
## 换界面倍率重建 HUD 之后要能单独把这块内容填回去。
func _push_component_contract(node_name: String) -> void:
	# 找出所有指向该节点的 ComponentID（含模型未区分的别名）。
	var ids := []
	var note := ""
	for c in eph.components:
		if String(c["node"]) == node_name:
			ids.append(c)
			note = String(c["confidence_note"])

	var id_text := node_name
	var attribution := "该节点不在组件契约中。"
	var alias := ""
	if not ids.is_empty():
		var distinct := []
		var aliased := []
		for c in ids:
			if bool(c["distinct_geometry"]):
				distinct.append(String(c["id"]))
			else:
				aliased.append(String(c["id"]))
		if not distinct.is_empty():
			id_text = ", ".join(distinct)
		attribution = note
		if not aliased.is_empty():
			alias = "⚠ 该视觉模型未区分以下仪器，它们共用这块几何：%s" % ", ".join(aliased)
	var badge := "12 英寸镀金铜盘" if node_name == "GoldenRecord" else node_name
	hud.set_component(id_text, attribution, alias, badge)
	hud.set_values({"sel_name": node_name})


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

	_push_component_contract(node_name)

	if node_name == "GoldenRecord":
		hud.set_record_visible(true)
		# 把镜头推到唱片上，让人直接看 NASA 模型自带的真实封面蚀刻图案。
		craft_focus = mi.global_transform * record_center
		# 唱片直径 0.314 m，要填满画面，相机距离取直径的 1.4 倍左右。
		cam_dist = 0.45
		cam_yaw = 1.5708
		cam_pitch = 0.0
		record_spinning = true
		_update_camera()
	else:
		hud.set_record_visible(false)
		craft_focus = Vector3.ZERO
		record_spinning = false
		if record_node != null:
			record_node.transform = record_orig_xform
			record_angle = 0.0


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


## ---- 界面倍率 ----
##
## 走的是"按新字号重新栅格化字体 + 按新倍率重排布局"，不是给画布加 transform：
## Godot 的字体是按字号栅格化进位图图集的，缩放画布只会把字形贴图放大糊掉。
## 代价是换档必须重建整层 HUD，所以做成离散档位。
func _set_ui_scale(v: float) -> void:
	if is_equal_approx(v, ui_scale):
		return
	ui_scale = clampf(v, 0.5, 3.0)
	_save_settings()
	_rebuild_hud()


func _rebuild_hud() -> void:
	# 旧层立刻脱树再释放：queue_free 是延迟的，不 remove_child 会有一帧两层
	# HUD 叠在一起。
	var old_layer := hud.get_parent()
	remove_child(old_layer)
	old_layer.queue_free()

	HudTheme.set_scale(ui_scale)
	_build_ui()
	_build_series()
	_set_mode(mode)
	hud.set_playing(playing)
	if dsn_text != "":
		hud.set_dsn(dsn_text)
	# 相机锁定下拉与部件契约都要回到重建前的状态
	if btn_focus != null:
		for i in btn_focus.item_count:
			if String(btn_focus.get_item_metadata(i)) == focus_target:
				btn_focus.selected = i
	if selected_component != "":
		_push_component_contract(selected_component)
		hud.set_record_visible(selected_component == "GoldenRecord")
	_refresh()


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	var v := float(cfg.get_value("display", "ui_scale", 1.0))
	# 只认已知档位，配置文件被手改成 3.7 之类也不至于把界面搞崩
	for step in UI_SCALES:
		if is_equal_approx(float(step), v):
			ui_scale = float(step)
	HudTheme.set_scale(ui_scale)


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)      # 存在就沿用，别把别的段落冲掉
	cfg.set_value("display", "ui_scale", ui_scale)
	cfg.save(SETTINGS_PATH)


## DSN 状态栏的文案。带 bbcode 给 HUD，纯文本留给自检。
func _set_dsn(bb: String) -> void:
	var re := RegEx.create_from_string("\\[/?[^\\]]+\\]")
	dsn_text = re.sub(bb, "", true)
	hud.set_dsn(bb)


func _on_dsn_pressed() -> void:
	if dsn_request == null:
		dsn_request = HTTPRequest.new()
		add_child(dsn_request)
		dsn_request.request_completed.connect(_on_dsn_done)
	_set_dsn("[color=#5c7d76]查询中…[/color]")
	var url := "https://eyes.nasa.gov/dsn/data/dsn.xml?r=%d" % Time.get_unix_time_from_system()
	if dsn_request.request(url) != OK:
		_set_dsn("[color=#ff9a9a]请求发起失败[/color]")


func _on_dsn_done(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if code != 200:
		_set_dsn("[color=#ff9a9a]HTTP %d[/color]" % code)
		return
	var parser := XMLParser.new()
	if parser.open_buffer(body) != OK:
		_set_dsn("[color=#ff9a9a]XML 解析失败[/color]")
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
		_set_dsn("正在跟踪 [color=#7dffd4]%s[/color] · 下行 [color=#7dffd4]%.0f bps[/color]"
			% [dish, rate])
	elif dsn_active_craft.is_empty():
		# 一个航天器都没解析出来，说明是解析或馈送出了问题，不是「没在跟踪」。
		_set_dsn("[color=#ffcf8f]馈送已收到但未解析出任何航天器 —— 疑似解析故障[/color]")
	else:
		# 这是常态：Voyager 2 赤纬极低，基本只有堪培拉 DSS-43 能看见，一天连几小时。
		_set_dsn("当前未跟踪（常态，非故障）· 全网在跟 [color=#7dffd4]%s[/color]"
			% ", ".join(dsn_active_craft))


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
		{"name": "01_now_system", "jd": _jd_today(), "mode": ViewMode.SYSTEM, "dist": 3200.0},
		{"name": "02_neptune_flyby", "jd": _event_jd("1989-08-25"), "mode": ViewMode.SYSTEM, "dist": 520.0},
		{"name": "03_jupiter_flyby", "jd": _event_jd("1979-07-09"), "mode": ViewMode.SYSTEM, "dist": 160.0},
		{"name": "04_launch", "jd": jd_min + 1.0, "mode": ViewMode.SYSTEM, "dist": 60.0},
		{"name": "05_craft", "jd": _jd_today(), "mode": ViewMode.CRAFT, "dist": 30.0},
		{"name": "06_craft_rtg", "jd": _jd_today(), "mode": ViewMode.CRAFT, "dist": 13.0,
			"select": "RTG_2", "yaw": 1.9, "pitch": 0.15},
		{"name": "07_golden_record", "jd": _jd_today(), "mode": ViewMode.CRAFT, "dist": 1.1,
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
		{"name": "12_uranus_rings", "jd": _event_jd("1986-01-24"), "mode": ViewMode.SYSTEM,
			"dist": 22.0, "focus_body": "uranus", "deselect": true,
			"yaw": 0.6, "pitch": 0.30},
		{"name": "13_neptune_rings", "jd": _event_jd("1989-08-25"), "mode": ViewMode.SYSTEM,
			"dist": 20.0, "focus_body": "neptune", "deselect": true,
			"yaw": 1.2, "pitch": 0.35},
		{"name": "14_jupiter_moons", "jd": _event_jd("1979-07-09"), "mode": ViewMode.SYSTEM,
			"lock": "jupiter", "deselect": true, "yaw": 0.5, "pitch": 0.62},
		{"name": "15_earth_moon", "jd": jd_min + 3000.0, "mode": ViewMode.SYSTEM,
			"lock": "earth", "deselect": true, "yaw": 0.7, "pitch": 0.45},
		{"name": "16_saturn_titan", "jd": _event_jd("1981-08-26"), "mode": ViewMode.SYSTEM,
			"lock": "saturn", "deselect": true, "yaw": 1.0, "pitch": 0.38},
	]

	for st in steps:
		_seek(float(st["jd"]))
		_set_mode(st["mode"])
		cam_dist = float(st.get("dist", 0.0))
		_shot_focus_probe = st.has("focus_probe")
		_shot_focus_sun = st.has("focus_sun")
		_shot_focus_body = String(st.get("focus_body", ""))
		if st.has("lock"):
			_shot_focus_body = ""
			_set_focus(String(st["lock"]))
		else:
			focus_target = ""
		if st.has("deselect"):
			selected_component = ""
			hud.set_record_visible(false)
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


## HUD 接线自检：数值 key、时间轴、播放、视图切换、金唱片面板。
##
## 存在的理由：HUD 是"喂 key 改文字"的结构，key 打错或撞名不会报错，
## 只会让某个数字永远停在占位符上 —— 肉眼很难发现。
func _run_hud_selftest() -> void:
	await get_tree().process_frame
	var fails := 0
	# 自检必须在已知倍率下跑：界面倍率是持久化的，上次退出时留在 150% 的话，
	# 下面所有宽度断言都会按 1.5 倍去量，结果看起来像 bug（踩过一次）。
	var entry_scale := ui_scale
	if not is_equal_approx(ui_scale, 1.0):
		_set_ui_scale(1.0)
		await get_tree().process_frame
	print("HUDTEST 起始倍率 %.2f -> 自检固定在 1.00" % entry_scale)

	# 1. 数值 key 必须一一对得上
	_refresh()
	if not hud.unknown_keys.is_empty():
		fails += 1
		print("HUDTEST FAIL 喂了 HUD 不认识的 key: %s" % ", ".join(hud.unknown_keys))
	if not hud.duplicate_keys.is_empty():
		fails += 1
		print("HUDTEST FAIL key 撞名（后者顶掉前者）: %s" % ", ".join(hud.duplicate_keys))
	print("HUDTEST key 对齐  未知 %d  撞名 %d  %s" % [
		hud.unknown_keys.size(), hud.duplicate_keys.size(),
		"OK" if hud.unknown_keys.is_empty() and hud.duplicate_keys.is_empty() else "FAIL"])

	# 2. 时间轴拖动要真的改时间
	var before := jd_now
	hud.timeline._seek_to(hud.timeline.size.x * 0.25)
	var moved := absf(jd_now - before) > 1.0
	if not moved:
		fails += 1
	print("HUDTEST 时间轴拖动 %s -> %s  %s" % [
		JDTime.format_date_short(before), JDTime.format_date_short(jd_now),
		"OK" if moved else "FAIL 时间没动"])
	_seek(before)

	# 3. 播放按钮
	_on_play_pressed()
	var play_ok := playing and hud.play_label() == "暂停"
	_on_play_pressed()
	play_ok = play_ok and not playing and hud.play_label() == "播放"
	if not play_ok:
		fails += 1
	print("HUDTEST 播放按钮 %s" % ("OK" if play_ok else "FAIL 文案或状态不同步"))

	# 4. 视图切换：两栏 HUD 与时间轴的显隐
	_set_mode(ViewMode.CRAFT)
	var craft_ok := hud.panel_visible("left_craft") \
		and not hud.panel_visible("left_system") \
		and not hud.panel_visible("right_system") \
		and not hud.panel_visible("timeline")
	_set_mode(ViewMode.SYSTEM)
	var sys_ok := hud.panel_visible("left_system") \
		and hud.panel_visible("right_system") \
		and hud.panel_visible("timeline") \
		and not hud.panel_visible("left_craft")
	if not (craft_ok and sys_ok):
		fails += 1
	print("HUDTEST 视图切换 CRAFT=%s SYSTEM=%s  %s" % [
		craft_ok, sys_ok, "OK" if craft_ok and sys_ok else "FAIL 面板显隐不对"])

	# 5. 金唱片面板只在选中金唱片时出现
	_set_mode(ViewMode.CRAFT)
	var rec_ok := not hud.panel_visible("right_craft")
	if component_nodes.has("GoldenRecord"):
		_select_component("GoldenRecord")
		rec_ok = rec_ok and hud.panel_visible("right_craft")
		if component_nodes.has("RTG_2"):
			_select_component("RTG_2")
			rec_ok = rec_ok and not hud.panel_visible("right_craft")
	else:
		rec_ok = false
	if not rec_ok:
		fails += 1
	print("HUDTEST 金唱片面板 %s" % ("OK" if rec_ok else "FAIL 显隐跟选中不同步"))

	# 6. 窄窗口降级：底栏必须自己收得住，且控件永不消失
	_set_mode(ViewMode.SYSTEM)
	for w in [1600.0, 1400.0, 1280.0, 1100.0, 960.0, 820.0]:
		hud.size = Vector2(float(w), 900.0)
		hud.relayout()
		var avail := float(w) - 80.0
		var need := hud.bar_row_min_width()
		# 要么装得下，要么该收的都收完了（极窄时允许溢出，但不能是没降级）
		var fits := need <= avail + 1.0
		var bottomed := not hud.bar_item_visible("legend") \
			and not hud.bar_item_visible("legend_compact") \
			and not hud.bar_item_visible("lock_cap")
		var controls_ok := hud.btn_focus.visible
		# 设计稿基准宽度下，数据来源图例至少要留着紧凑版 —— "每个数字都带来源
		# 标注"是第一纪律，宁可牺牲字数。字重上浮后长版在 1600 宽已装不下，
		# 所以这里要的是"没被整块收掉"，不是"必须显示长版"。
		var no_over_degrade := float(w) < 1400.0 \
			or hud.bar_item_visible("legend") or hud.bar_item_visible("legend_compact")
		var ok := (fits or bottomed) and controls_ok and no_over_degrade
		if not ok:
			fails += 1
		print("HUDTEST 窄窗口 %4d 宽  需要 %4d / 可用 %4d  [%s]  %s" % [
			int(float(w)), int(need), int(avail), hud.bar_row_breakdown(),
			"OK" if ok else "FAIL"])
	hud.size = get_viewport().get_visible_rect().size
	hud.relayout()

	# 7. 界面倍率：重建后字号与布局按倍率放大，且状态不丢
	_seek(_jd_today())
	var jd_before := jd_now
	_set_mode(ViewMode.CRAFT)
	if component_nodes.has("GoldenRecord"):
		_select_component("GoldenRecord")
	for target in [1.5, 1.0]:
		_set_ui_scale(float(target))
		await get_tree().process_frame
		await get_tree().process_frame
		var f := float(target)
		var want_col := HudTheme.dp(428)
		var got_col := hud.column_size("left_craft").x
		var math_ok := is_equal_approx(HudTheme.scale, f) \
			and HudTheme.fs(11) == int(round(11.0 * f)) \
			and is_equal_approx(HudTheme.dp(428), round(428.0 * f))
		# 布局真的按倍率变了（左栏在 CRAFT 下宽 400，不是 428）
		var layout_ok := absf(got_col - HudTheme.dp(400)) < 2.0
		# 重建不能丢状态
		var state_ok := mode == ViewMode.CRAFT \
			and selected_component == "GoldenRecord" \
			and hud.panel_visible("right_craft") \
			and absf(slider.value - jd_before) < 1e-6
		var ok := math_ok and layout_ok and state_ok
		if not ok:
			fails += 1
		# 窗口装不下就必须给出提示（1600×900 下 150% 会溢出）
		var vs := get_viewport().get_visible_rect().size
		var should_warn := vs.x < HudTheme.dp(1600) - 1.0 or vs.y < HudTheme.dp(900) - 1.0
		var warn_ok := hud.bar_item_visible("too_small") == should_warn
		if not warn_ok:
			fails += 1
			print("HUDTEST FAIL 倍率 %d%% 装不下=%s 但提示=%s" % [
				int(f * 100.0), should_warn, hud.bar_item_visible("too_small")])
		print("HUDTEST 界面倍率 %3d%%  字号 11->%d  布局 400->%d(实测 %d)  状态保持=%s  %s" % [
			int(f * 100.0), HudTheme.fs(11), int(HudTheme.dp(400)), int(got_col),
			state_ok, "OK" if ok and warn_ok else "FAIL"])
	_set_ui_scale(entry_scale)
	_set_mode(ViewMode.SYSTEM)

	print("HUDTEST_DONE 失败 %d" % fails)
	get_tree().quit()


## FATAL 屏单独截图。
func _run_fatal_shot() -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var out := ProjectSettings.globalize_path("res://../assets/generated/godot_shots")
	DirAccess.make_dir_recursive_absolute(out)
	var err := get_viewport().get_texture().get_image().save_png(out + "/00_fatal.png")
	print("SHOT 00_fatal -> %s (%s)" % [out, "ok" if err == OK else "err %d" % err])
	get_tree().quit()


## 真实"现在"在时间轴上的位置。星历覆盖到 2060，jd_max 不再等于现在。
func _jd_today() -> float:
	return clampf(JDTime.now_jd(), jd_min, jd_max)


func _event_jd(date: String) -> float:
	for ev in eph.events:
		if String(ev["date"]) == date:
			return float(ev["jd"])
	return _jd_today()


## DSN 实时链路自检：真发一次请求，把结果打出来再退出。
## 未测过的网络代码就是尾巴，所以这条唯一的实时链路必须能在无人值守下验证。
##   Godot --headless --path . -- --dsntest
func _run_dsn_selftest() -> void:
	_on_dsn_pressed()
	var waited := 0.0
	while dsn_text.ends_with("查询中…") and waited < 30.0:
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
	print("DSNTEST %s" % dsn_text)
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


## 卫星轨道解算的跨语言契约自检。
##
## 逐帧计算必须在 GDScript 里做，但物理模型的真相源在 Go（internal/orbit）。
## 两份实现会静默漂移 —— 一个小数位打错、一次旋转顺序写反，画面上看不出来，
## 但轨道就错了。所以 cmd/export 会把 Go 侧在若干固定历元的解算结果写进
## metadata.json，这里逐点比对。
##   Godot --headless --path . -- --orbittest
## 天穹对齐自检。
##
## 银河贴图的坐标系是实测定出来的（见 shaders/sky.gdshader 的推导），
## 而世界坐标到银道要过三次旋转。这两段里任何一处符号写反，画面上都只是
## "银河歪了一点"，肉眼几乎判不出来 —— 所以必须拿已知天体的银道坐标校验。
##
## 基准值全部是查得到的常量，不是从本实现反推的：
##   银心            l=0     b=0        -> 贴图正中 (0.5, 0.5)
##   黄北极          l=96.38 b=+29.81   -> 世界 +Y 必须落在这里
##   大/小麦哲伦云   贴图上肉眼可见的亮团，实测落点已在着色器注释里
##   Vector3 只有 float32，所以容差给到 1e-3（贴图 8192 宽，约 8 像素）。
##   Godot --headless --path . -- --skytest
func _run_sky_selftest() -> void:
	var fails := 0
	var rows := _galactic_rows()

	# 1. 必须是纯旋转：行向量正交、模长为 1、行列式 +1（含镜像会让银河左右翻转）
	for i in 3:
		var ri: Vector3 = rows[i]
		var n: float = ri.length()
		if absf(n - 1.0) > 1e-5:
			fails += 1
			print("SKYTEST FAIL 第 %d 行不是单位向量：|r| = %.8f" % [i, n])
	for pair in [[0, 1], [0, 2], [1, 2]]:
		var ra: Vector3 = rows[pair[0]]
		var rb: Vector3 = rows[pair[1]]
		var d: float = ra.dot(rb)
		if absf(d) > 1e-5:
			fails += 1
			print("SKYTEST FAIL 第 %d、%d 行不正交：点积 = %.8f" % [pair[0], pair[1], d])
	var d0: Vector3 = rows[0]
	var d1: Vector3 = rows[1]
	var d2: Vector3 = rows[2]
	var det: float = d0.dot(d1.cross(d2))
	if absf(det - 1.0) > 1e-5:
		fails += 1
		print("SKYTEST FAIL 行列式 = %.8f，不是 +1（含镜像，银河会左右翻转）" % det)

	# 2. 已知方向必须落在已知 UV 上
	# 黄北极的银道坐标 l=96.383° b=+29.811° 是标准值；世界 +Y 就是黄北极。
	var cases := [
		["黄北极", Vector3(0, 1, 0), 0.5 - 96.383 / 360.0, 0.5 + 29.811 / 180.0],
	]
	for c in cases:
		var uv := _galactic_uv(c[1])
		var du: float = absf(uv.x - float(c[2]))
		du = minf(du, 1.0 - du)                       # 经度环绕
		var dv: float = absf(uv.y - float(c[3]))
		if du > 1e-3 or dv > 1e-3:
			fails += 1
			print("SKYTEST FAIL %s：得到 (%.5f, %.5f)，期望 (%.5f, %.5f)" % [
				c[0], uv.x, uv.y, float(c[2]), float(c[3])])

	# 3. 反向：银心 / 麦哲伦云的银道坐标必须回到贴图上的实测落点
	var marks := [
		["银心", 0.0, 0.0, 0.5, 0.5],
		["大麦哲伦云", 280.47, -32.89, 0.7209, 0.3173],
		["小麦哲伦云", 302.81, -44.33, 0.6589, 0.2537],
	]
	for m in marks:
		var l := deg_to_rad(float(m[1]))
		var b := deg_to_rad(float(m[2]))
		# 银道向量 -> 世界向量（矩阵是正交的，转置即逆）
		var g := Vector3(cos(b) * cos(l), cos(b) * sin(l), sin(b))
		var r0: Vector3 = rows[0]
		var r1: Vector3 = rows[1]
		var r2: Vector3 = rows[2]
		var w: Vector3 = r0 * g.x + r1 * g.y + r2 * g.z
		var uv := _galactic_uv(w)
		var du: float = absf(uv.x - float(m[3]))
		du = minf(du, 1.0 - du)
		var dv: float = absf(uv.y - float(m[4]))
		if du > 1e-3 or dv > 1e-3:
			fails += 1
			print("SKYTEST FAIL %s：得到 (%.5f, %.5f)，期望 (%.5f, %.5f)" % [
				m[0], uv.x, uv.y, float(m[3]), float(m[4])])
		else:
			print("SKYTEST  ok  %-12s uv=(%.4f, %.4f)" % [m[0], uv.x, uv.y])

	# 4. 贴图与着色器都得真的在
	if load(TEX_MILKY_WAY) == null:
		fails += 1
		print("SKYTEST FAIL 找不到 %s" % TEX_MILKY_WAY)
	if load("res://shaders/sky.gdshader") == null:
		fails += 1
		print("SKYTEST FAIL 找不到 res://shaders/sky.gdshader")

	print("SKYTEST_DONE 失配 %d" % fails)
	get_tree().quit()


func _run_orbit_selftest() -> void:
	var checks: Array = eph.metadata.get("satellite_check", [])
	if checks.is_empty():
		print("ORBITTEST FAIL 数据包里没有契约基准点，先跑 go run ./cmd/export")
		get_tree().quit()
		return
	var worst := 0.0
	var worst_name := ""
	var fails := 0
	for c in checks:
		var nm := String(c["name"])
		var jd := float(c["jd"])
		var obl := float(c["obliquity_deg"])
		var want: Array = c["offset_km"]
		var got: Array = eph.satellite_offset_km(nm, jd, obl)
		# 比对必须在 double 里做，不能过 Vector3。
		var ex := float(got[0]) - float(want[0])
		var ey := float(got[1]) - float(want[1])
		var ez := float(got[2]) - float(want[2])
		var d := sqrt(ex * ex + ey * ey + ez * ez)
		# 相对半长轴的误差
		var a := float(eph.satellites[nm]["semi_major_km"])
		var rel := d / a
		if rel > worst:
			worst = rel
			worst_name = "%s @ jd %.2f" % [nm, jd]
		if rel > 1e-9:
			fails += 1
			print("ORBITTEST FAIL %-9s jd %.2f  偏差 %.4f km = %s 个半长轴" % [
				nm, jd, d, JDTime.sci(rel)])
	print("ORBITTEST_DONE 基准点 %d  失配 %d  最大相对偏差 %s (%s)" % [
		checks.size(), fails, JDTime.sci(worst), worst_name])
	get_tree().quit()


## 尺度自检：守住用户实际发现的那个 bug。
##
## 原来的做法是拿行星半径的夸张倍数去放大卫星轨道。地球被 0.5 单位的半径
## 下限把 620 倍抬成 1173 倍，于是月球被甩到地球公转轨道的 3 倍远（用户
## 一眼看出「月球和地球离婚了」）；木卫四的轨道也比木星自己的公转轨道还宽。
##
## 这条自检断言两件事：
##   1. 任何卫星的轨道半径都必须远小于母星的公转轨道半径
##   2. 锁定母星后，卫星与母星的**渲染**距离比要接近真实比值
##      （月球 / 地球半径 = 60.3）
##   Godot --path . -- --scaletest
func _run_scale_selftest() -> void:
	_set_mode(ViewMode.SYSTEM)
	var fails := 0

	print("--- 卫星轨道 vs 母星公转轨道 ---")
	for nm in eph.satellites:
		var parent := String(eph.satellites[nm]["parent"])
		var a_units := float(eph.satellites[nm]["semi_major_km"]) / eph.au_km * AU_UNITS
		var ps := eph.state_at(parent, jd_now)
		var orbit_r := JDTime.vec_len(ps["pos"]) / eph.au_km * AU_UNITS
		var ratio := a_units / maxf(orbit_r, 1e-9)
		var ok := ratio < 0.05
		if not ok:
			fails += 1
		print("SCALETEST %-9s 轨道 %9.5f 单位 / 母星公转 %8.2f 单位 = %.5f  %s" % [
			nm, a_units, orbit_r, ratio, "OK" if ok else "FAIL 卫星轨道过大"])

	print("--- 锁定母星后的渲染比例 ---")
	# 每颗卫星必须用它自己那次飞掠的历元 —— 别处只有日采样，位置本就不该显示。
	var epoch_for := {
		"moon": jd_min + 3000.0,
		"io": _event_jd("1979-07-09"), "europa": _event_jd("1979-07-09"),
		"titan": _event_jd("1981-08-26"), "miranda": _event_jd("1986-01-24"),
		"triton": _event_jd("1989-08-25"),
	}
	for nm in ["moon", "io", "europa", "titan", "miranda", "triton"]:
		if not eph.satellites.has(nm):
			continue
		var parent := String(eph.satellites[nm]["parent"])
		_seek(float(epoch_for.get(nm, jd_now)))
		_set_focus(parent)
		await get_tree().process_frame
		_refresh()
		var pv: Node3D = planet_nodes[parent]
		var sv: Node3D = planet_nodes[nm]
		var sep := (sv.global_position - pv.global_position).length()
		# 母星的渲染半径 = 真实半径 × tilt 缩放
		var r_render: float = body_real_radius[parent] * (planet_tilt[parent] as Node3D).scale.x
		var exa := _system_exaggeration(parent)
		# 断言一：卫星轨道是**真实尺度**（这是用户发现的那个 bug 的正解）。
		# 渲染出来的「轨道/天体半径」应当等于真实比值 ÷ 放大倍数。
		var rendered_ratio := sep / maxf(r_render, 1e-12)
		var true_ratio := (float(eph.satellites[nm]["semi_major_km"])
			/ float(eph.profiles[parent]["equatorial_radius_km"]))
		var expect := true_ratio / exa
		var err := absf(rendered_ratio - expect) / expect
		# 断言二：尺寸比例只允许被「屏幕最小尺寸下限」**向上**撑大，
		# 不允许被缩小，而且撑大的倍数必须与记录的 inflation 一致。
		var r_sat: float = body_real_radius[nm] * (planet_tilt[nm] as Node3D).scale.x
		var size_ratio := r_sat / maxf(r_render, 1e-12)
		var true_size_ratio := (float(eph.profiles[nm]["equatorial_radius_km"])
			/ float(eph.profiles[parent]["equatorial_radius_km"]))
		var inflation: float = float(_size_inflation.get(nm, 1.0))
		var parent_infl: float = float(_size_inflation.get(parent, 1.0))
		var expect_size := true_size_ratio * inflation / maxf(parent_infl, 1e-12)
		var size_err := absf(size_ratio - expect_size) / maxf(expect_size, 1e-12)
		var never_shrunk := size_ratio >= true_size_ratio * 0.9
		var ok2 := err < 0.35 and size_err < 0.35 and never_shrunk
		if not ok2:
			fails += 1
		print("SCALETEST %-9s 锁定 %-8s 轨道比 %7.2f (期望 %7.2f, 偏差 %4.1f%%)  尺寸比 %7.4f (真值 %7.4f, 可见性撑大 %5.2f×, 偏差 %4.1f%%)  %s" % [
			nm, parent, rendered_ratio, expect, err * 100.0,
			size_ratio, true_size_ratio, inflation / maxf(parent_infl, 1e-12),
			size_err * 100.0, "OK" if ok2 else "FAIL"])

	print("SCALETEST_DONE 失败 %d" % fails)
	get_tree().quit()


## 相机锁定自检：逐个选中下拉框里的每一项，验证相机真的对准了它。
##   Godot --path . -- --focustest
func _run_focus_selftest() -> void:
	_set_mode(ViewMode.SYSTEM)
	var fails := 0
	for i in btn_focus.item_count:
		var meta := String(btn_focus.get_item_metadata(i))
		var label := btn_focus.get_item_text(i)
		# 走真实路径：模拟用户点选
		btn_focus.selected = i
		_set_focus(meta)
		await get_tree().process_frame
		_refresh()

		var want := Vector3.ZERO
		var what := "太阳/原点"
		if meta == "voyager2":
			want = probe_root.global_position
			what = "探测器"
		elif meta != "" and planet_nodes.has(meta):
			want = (planet_nodes[meta] as Node3D).global_position
			what = meta
		# 相机看向的点：位置 + 前方 × 距离
		var looking_at := camera.global_position - camera.global_transform.basis.z * cam_dist
		var err := (looking_at - want).length()
		# 误差按相机距离归一（同样的绝对误差在近景是灾难、在远景无所谓）
		var rel := err / maxf(cam_dist, 1e-9)
		# 聚焦目标必须可见 —— 不可见时 _focus_position 会回退到母星，
		# 表现就是「锁定月球却对准了地球」。
		var vis := true
		if meta != "" and meta != "voyager2" and planet_nodes.has(meta):
			vis = (planet_nodes[meta] as Node3D).visible
		var ok := rel < 0.02 and vis
		if not ok:
			fails += 1
		print("FOCUSTEST %-22s meta=%-10s 目标=%-10s 距离=%10.5f 偏差=%s 可见=%s  %s" % [
			label.strip_edges(), meta, what, cam_dist, JDTime.sci(rel), str(vis),
			"OK" if ok else "FAIL"])
	print("FOCUSTEST_DONE 项数 %d 失败 %d" % [btn_focus.item_count, fails])
	get_tree().quit()


## 轨道环自检：卫星本体必须**落在**它自己画出的环上。
##
## 这条自检是补的，因为它本该拦住一个用户发现的 bug：月球的开普勒要素是
## 黄道系的，我却当成地球赤道系套了 23.44 度的倾角旋转，把环整体歪掉，
## 月球明显不在环上。实测轨道面法向偏差 16-26 度。
##
## 截图自检看不出这种问题 —— 画面上环也在、天体也在，只是位置不对。
##   Godot --path . -- --ringtest
func _run_ring_selftest() -> void:
	_set_mode(ViewMode.SYSTEM)
	var epoch_for := {
		"moon": jd_min + 3000.0,
		"io": _event_jd("1979-07-09"), "europa": _event_jd("1979-07-09"),
		"ganymede": _event_jd("1979-07-09"), "callisto": _event_jd("1979-07-09"),
		"titan": _event_jd("1981-08-26"), "miranda": _event_jd("1986-01-24"),
		"triton": _event_jd("1989-08-25"),
	}
	var fails := 0
	for nm in eph.satellites:
		var parent := String(eph.satellites[nm]["parent"])
		_seek(float(epoch_for.get(nm, jd_now)))
		_set_focus(parent)
		await get_tree().process_frame
		_refresh()
		var pv: Node3D = planet_nodes[nm]
		if not pv.visible or not _orbit_points.has(nm):
			print("RINGTEST %-9s 跳过（此刻不可见）" % nm)
			continue
		# 天体在母星局部坐标系里的位置
		var local := pv.position
		# 到环折线的最短距离
		var pts: PackedVector3Array = _orbit_points[nm]
		var best := INF
		for i in pts.size() - 1:
			var a := pts[i]
			var b := pts[i + 1]
			var ab := b - a
			var l2 := ab.length_squared()
			var t := 0.0 if l2 < 1e-24 else clampf((local - a).dot(ab) / l2, 0.0, 1.0)
			best = minf(best, (local - (a + ab * t)).length())
		var a_units := float(eph.satellites[nm]["semi_major_km"]) / eph.au_km * AU_UNITS
		var rel := best / maxf(a_units, 1e-12)
		var src := "星历" if bool(_orbit_from_ephemeris.get(nm, false)) else "要素"
		var ok := rel < 0.06
		if not ok:
			fails += 1
		print("RINGTEST %-9s 环源=%s  离环 %s 单位 = %5.2f%% 半长轴  %s" % [
			nm, src, JDTime.sci(best), rel * 100.0, "OK" if ok else "FAIL 天体不在环上"])
	print("RINGTEST_DONE 失败 %d" % fails)
	get_tree().quit()
