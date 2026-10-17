## 赛博朋克 HUD —— UI 层的全部内容。
##
## 逐像素对齐 Claude Design 的 `赛博朋克 HUD.dc.html`（1600×900 三屏：
## 01 SYSTEM 太阳系视图 / 02 CRAFT 探测器特写 + 金唱片 / 03 FATAL 加载失败）。
## 稿子里每个 left/top/font-size/letter-spacing/color 都是显式写死的行内样式，
## 这里就照抄成布局参数，不"估一个差不多"。
##
## 3D 场景（星球、天穹、轨迹带、光照）完全不碰，这层只是压在上面的画布。
class_name Hud
extends Control

signal play_pressed
signal ui_scale_picked(v: float)
signal mode_pressed(craft: bool)
signal focus_probe_pressed
signal focus_sun_pressed
signal dsn_pressed
signal tone_pressed
signal scan_pressed
signal spin_pressed

const RAIL_H := 52
const PAD_X := 40
const COL_TOP := 80
const LEFT_W := 428
const RIGHT_W := 436
const BAR_H_SYSTEM := 164
const BAR_H_CRAFT := 98

# ---- 对外暴露给 twin.gd 的部件 ----
var backdrop: HudBackdrop
var annotations: HudAnnotations
var timeline: HudTimeline
var btn_focus: OptionButton
var spark_power: Sparkline
var spark_dist: Sparkline
var spark_rx: Sparkline

var _vals := {}                  # key -> Label
## 自检用：喂进来但 HUD 里没有对应标签的 key / 被注册两次的 key。
var unknown_keys: Array = []
var duplicate_keys: Array = []
var _blinkers := []              # [{node, period}]
var _t := 0.0

var _left_system: Control
var _right_system: Control
var _left_craft: Control
var _right_craft: Control
var _brackets: Array = []
var _bar: Control
var _bar_bg: Control
var _timeline_group: Control
var _bar_row: Control
var _seg_system: HudClickPanel
var _seg_craft: HudClickPanel
var _seg_system_lbl: Label
var _seg_craft_lbl: Label
var _play_lbl: Label
var _rail_selected: Control
var _rail_dsn: Control
var _lbl_dsn: RichTextLabel
var _lbl_focus_extra: Label
var _station_rows: VBoxContainer
var _station_widgets: Array = []
var _fuel_bar: Bar
var _conv_bar: Bar
var _lbl_alias: Label
var _lbl_attr: Label
var _record_sections: VBoxContainer
var _craft_mode := false
var _title: Label
var btn_ui_scale: OptionButton
var _lbl_too_small: Label
var _scrim_left: TextureRect
var _scrim_right: TextureRect
var _overlay_mat: ShaderMaterial
var _legend: Control
var _legend_compact: Control
var _craft_hint: Control
var _lbl_lock_cap: Label
var _esc_badge: PanelContainer
var _touch_controls: HBoxContainer


# ============================================================
#  内部小控件
# ============================================================

## 方框的四角小括号（稿子里 RTG 面板和无遥测面板的装饰）。
class CornerTicks:
	extends Control
	var color := Color.WHITE
	var both := true
	var arm := HudTheme.dp(8.0)

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var t := HudTheme.dp(1)
		draw_rect(Rect2(0, 0, arm, t), color, true)
		draw_rect(Rect2(0, 0, t, arm), color, true)
		if both:
			draw_rect(Rect2(size.x - arm, size.y - t, arm, t), color, true)
			draw_rect(Rect2(size.x - t, size.y - arm, t, arm), color, true)


## 细进度条（燃料剩余 / 转换器效率）。
class Bar:
	extends Control
	var ratio := 0.0:
		set(v):
			ratio = clampf(v, 0.0, 1.0)
			queue_redraw()
	var track := Color(1.0, 0.72, 0.30, 0.14)
	var fill := HudTheme.AMBER

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2(0, HudTheme.dp(4))

	func _draw() -> void:
		draw_rect(Rect2(0, 0, size.x, size.y), track, true)
		draw_rect(Rect2(0, 0, size.x * ratio, size.y), fill, true)


## 危险斜纹（FATAL 屏上下两条）。
class Stripes:
	extends Control
	var a := HudTheme.RED
	var b := Color("#2a0a0c")

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		draw_rect(Rect2(0, 0, size.x, size.y), b, true)
		var band := HudTheme.dp(14)
		var x := -size.y
		while x < size.x + size.y:
			draw_colored_polygon(PackedVector2Array([
				Vector2(x, size.y), Vector2(x + band, size.y),
				Vector2(x + band + size.y, 0), Vector2(x + size.y, 0)]), a)
			x += band * 2.0


## 四角取景框。
class Bracket:
	extends Control
	var color := HudTheme.PH
	var hx := 1        # +1 左, -1 右
	var vy := 1        # +1 上, -1 下

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2(HudTheme.dp(20), HudTheme.dp(20))

	func _draw() -> void:
		var t := HudTheme.dp(1)
		var y0 := 0.0 if vy > 0 else size.y - t
		var x0 := 0.0 if hx > 0 else size.x - t
		draw_rect(Rect2(0, y0, size.x, t), color, true)
		draw_rect(Rect2(x0, 0, t, size.y), color, true)


# ============================================================
#  构建
# ============================================================

func _ready() -> void:
	HudTheme.fill(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)
	# 窗口尺寸变了要重排：四角取景框的位置和底栏那一行的降级都跟宽高有关。
	resized.connect(relayout)


func _process(delta: float) -> void:
	_t += delta
	# 测站行每帧重建，闪烁登记表里会攒下已释放的节点，顺手清掉。
	var dead := []
	for b in _blinkers:
		if not is_instance_valid(b["node"]):
			dead.append(b)
			continue
		var node: CanvasItem = b["node"]
		var p: float = b["period"]
		# 稿子的 blink：0-48% 亮，52-100% 暗到 .12
		node.modulate.a = 1.0 if fmod(_t, p) < p * 0.5 else 0.12
	for d in dead:
		_blinkers.erase(d)
	# 标题偶发闪一下（稿子的 flickerText：7s 周期里 96% 时间全亮）
	if _title != null:
		var ft := fmod(_t, 7.0) / 7.0
		var a := 1.0
		if ft > 0.96 and ft < 0.97:
			a = 0.35
		elif ft > 0.98 and ft < 0.985:
			a = 0.75
		_title.modulate.a = a

	# 可跟踪的测站圆点在闪
	for wg in _station_widgets:
		if bool(wg["blink"]):
			(wg["mark"] as Label).modulate.a = 1.0 if fmod(_t, 1.6) < 0.8 else 0.12


func _blink(node: CanvasItem, period: float) -> CanvasItem:
	_blinkers.append({"node": node, "period": period})
	return node


func _val(key: String, text: String, font: Font, size: int, color: Color) -> Label:
	var l := HudTheme.label(text, font, size, color)
	# 同一个 key 注册两次 = 后者把前者顶掉，前者从此永远显示占位符，而且
	# 一声不响（"日心速度" 和播放速度就撞过一次）。记下来给 --hudtest 抓。
	if _vals.has(key):
		duplicate_keys.append(key)
	_vals[key] = l
	return l


## 设置一批数值。key 见各构建函数里的 _val 调用。
func set_values(d: Dictionary) -> void:
	for k in d:
		if _vals.has(k):
			(_vals[k] as Label).text = String(d[k])
		elif not unknown_keys.has(k):
			unknown_keys.append(String(k))


func _gradient(from: Color, to: Color, height: int, horizontal := false) -> TextureRect:
	var g := Gradient.new()
	g.set_color(0, from)
	g.set_color(1, to)
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.width = 8
	tex.height = 64
	tex.fill_from = Vector2.ZERO
	tex.fill_to = Vector2(1, 0) if horizontal else Vector2(0, 1)
	var tr := TextureRect.new()
	tr.texture = tex
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	HudTheme.fill(tr)
	if height > 0:
		tr.custom_minimum_size = Vector2(0, HudTheme.dp(height))
	return tr


## 径向底光（FATAL 屏中央那团暗红）。
func _radial(from: Color, to: Color) -> TextureRect:
	var g := Gradient.new()
	g.set_color(0, from)
	g.set_color(1, to)
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.width = 128
	tex.height = 128
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	var tr := TextureRect.new()
	tr.texture = tex
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	HudTheme.fill(tr)
	return tr


const SCRIM_COLOR := Color(0.008, 0.031, 0.035, 0.82)
const SCRIM_FADE := 90      # 栏外再往画面中间淡出多少像素


## 一栏底下的暗底。
##
## 关键是**三段**渐变而不是两段：栏本身的宽度范围内保持满值，只在栏外那
## SCRIM_FADE 像素里淡出。第一版用的是"从边缘一路淡到栏尾"，结果栏中央只剩
## 0.4 的底，压在金唱片那种极亮金属上照样看不清。
func _scrim(on_right: bool) -> TextureRect:
	var col_w := HudTheme.dp(PAD_X + (RIGHT_W if on_right else LEFT_W))
	var total := col_w + HudTheme.dp(SCRIM_FADE)
	var clear := Color(SCRIM_COLOR.r, SCRIM_COLOR.g, SCRIM_COLOR.b, 0.0)
	var solid_at := col_w / total

	var g := Gradient.new()
	if on_right:
		g.offsets = PackedFloat32Array([0.0, 1.0 - solid_at, 1.0])
		g.colors = PackedColorArray([clear, SCRIM_COLOR, SCRIM_COLOR])
	else:
		g.offsets = PackedFloat32Array([0.0, solid_at, 1.0])
		g.colors = PackedColorArray([SCRIM_COLOR, SCRIM_COLOR, clear])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.width = 256
	tex.height = 8
	tex.fill_from = Vector2.ZERO
	tex.fill_to = Vector2(1, 0)

	var tr := TextureRect.new()
	tr.texture = tex
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if on_right:
		HudTheme.anchor(tr, 1, 0, 1, 1, -total, 0, 0, 0)
	else:
		HudTheme.anchor(tr, 0, 0, 0, 1, 0, 0, total, 0)
	return tr


func _blank_tex() -> ImageTexture:
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	return ImageTexture.create_from_image(img)


## 整层 HUD 的构建入口。
func build(jd_min: float, jd_max: float, events: Array, focus_items: Array,
		focus_count_text: String) -> void:
	backdrop = HudBackdrop.new()
	HudTheme.fill(backdrop)
	add_child(backdrop)

	# 两栏底下垫一层从画面边缘向中间淡出的暗底。稿子是在纯黑背景上排的，
	# 真机背景可能是太阳、星云这种亮区，不垫底文字会直接糊进去。用渐变而不是
	# 实心块，HUD 才还是"浮在画面上"而不是一块贴片。
	_scrim_left = _scrim(false)
	add_child(_scrim_left)
	_scrim_right = _scrim(true)
	add_child(_scrim_right)

	annotations = HudAnnotations.new()
	HudTheme.fill(annotations)
	add_child(annotations)

	_build_rail()
	_build_left_system()
	_build_right_system()
	_build_left_craft()
	_build_right_craft()
	_build_bar(jd_min, jd_max, events, focus_items, focus_count_text)
	_build_brackets()
	_build_overlay()
	_build_touch_controls()
	set_mode(false)
	relayout()


func _build_overlay(scan_color := HudTheme.PH, vignette := 0.75,
		grain := 1.0, sweep := 1.0) -> void:
	var sh := load("res://shaders/hud_overlay.gdshader")
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("u_scan_color", scan_color)
	mat.set_shader_parameter("u_vignette", vignette)
	mat.set_shader_parameter("u_grain", grain)
	mat.set_shader_parameter("u_sweep", sweep)
	mat.set_shader_parameter("u_scale", HudTheme.scale)
	# 暗角渐变长度。设计稿是 1600×900 窗口上的 inset 200px 阴影，可顶部导轨
	# 只有 RAIL_H=52 单位高 —— 整条导轨都埋在渐变最深的一段里（52 处仍有
	# 0.41 的黑）。桌面大屏尚能辨认，手机上那几行 10px 的 MUTED 小字就废了。
	# 底部条 BAR_H=164、左右栏另有 scrim 垫底，所以只有顶部吃亏。
	# 触屏设备把渐变收短：暗角形状和强度都不变，只是不再吞掉导轨。
	# 两个旋钮一起调才有肉眼可见的差别：只收短渐变的话，导轨文字所在的
	# y≈26 处只从 0.535 降到 0.427，白跑一趟。
	if DisplayServer.is_touchscreen_available() or OS.has_feature("mobile"):
		mat.set_shader_parameter("u_vignette_px", 70.0)
		mat.set_shader_parameter("u_vignette", vignette * 0.73)
	var cr := ColorRect.new()
	cr.color = Color(1, 1, 1, 1)
	cr.material = mat
	HudTheme.fill(cr)
	cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(cr)
	_overlay_mat = mat
	_update_overlay_metrics()


## CRT shader 的 FRAGCOORD 是真实渲染像素，而布局尺寸是画布单位；两者必须
## 一起更新，canvas_items 拉伸时暗角等效果才不会错位。
func _update_overlay_metrics() -> void:
	if _overlay_mat == null:
		return
	var px_per_unit := 1.0
	if size.x > 0.0:
		px_per_unit = float(get_viewport().get_texture().get_size().x) / size.x
	_overlay_mat.set_shader_parameter("u_size", size)
	_overlay_mat.set_shader_parameter("u_px_per_unit", px_per_unit)


# ------------------------------------------------------------
#  顶部导轨
# ------------------------------------------------------------
func _build_rail() -> void:
	var rail := Control.new()
	HudTheme.anchor(rail, 0, 0, 1, 0, 0, 0, 0, HudTheme.dp(RAIL_H))
	rail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(rail)

	rail.add_child(_gradient(HudTheme.RAIL_BG, Color(0.008, 0.035, 0.043, 0.0), 0))
	var border := ColorRect.new()
	border.color = HudTheme.HAIRLINE
	HudTheme.anchor(border, 0, 1, 1, 1, 0, -HudTheme.dp(1))
	border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rail.add_child(border)

	var row := HudTheme.hbox(0)
	HudTheme.fill(row, HudTheme.dp(PAD_X), 0, -HudTheme.dp(PAD_X), 0)
	rail.add_child(row)

	# 左：标题
	var left := HudTheme.hbox(14)
	left.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_child(left)
	_title = HudTheme.label("VOYAGER 2", HudTheme.mono(15, 700, 0.30), 15, HudTheme.PH)
	left.add_child(_title)
	left.add_child(HudTheme.pad(_vrule(14), 0, 19))
	left.add_child(HudTheme.label("数字孪生", HudTheme.sans(13, 400, 0.16), 13, HudTheme.TEXT3))
	left.add_child(HudTheme.label("DIGITAL TWIN · EPHEMERIS-DRIVEN",
		HudTheme.mono(10, 400, 0.18), 10, HudTheme.MUTED))

	row.add_child(HudTheme.spacer())

	# 右（SYSTEM）：DSN 链路
	_rail_dsn = HudTheme.hbox(16)
	row.add_child(_rail_dsn)
	_rail_dsn.add_child(HudTheme.label("DSN LINK", HudTheme.mono(10, 400, 0.18),
		10, HudTheme.MUTED))
	var dsn_click := HudClickPanel.new()
	dsn_click.setup(HudTheme.flat(Color(0, 0, 0, 0)),
		HudTheme.flat(HudTheme.PH_FILL_SOFT))
	dsn_click.tooltip_text = "点一下查询 DSN 实时链路"
	dsn_click.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dsn_click.pressed.connect(func() -> void: dsn_pressed.emit())
	_rail_dsn.add_child(dsn_click)
	_lbl_dsn = RichTextLabel.new()
	_lbl_dsn.bbcode_enabled = true
	_lbl_dsn.fit_content = true
	_lbl_dsn.scroll_active = false
	_lbl_dsn.autowrap_mode = TextServer.AUTOWRAP_OFF
	_lbl_dsn.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lbl_dsn.add_theme_font_override("normal_font", HudTheme.sans(13, 400))
	_lbl_dsn.add_theme_font_size_override("normal_font_size", 13)
	_lbl_dsn.add_theme_color_override("default_color", HudTheme.TEXT)
	_lbl_dsn.custom_minimum_size = Vector2(0, HudTheme.dp(19))
	_lbl_dsn.fit_content = true
	_lbl_dsn.text = "DSN 链路 [color=#5c7d76]未查询 · 点此拉取实时馈送[/color]"
	dsn_click.add_child(_lbl_dsn)

	var live := HudTheme.hbox(6)
	var live_box := PanelContainer.new()
	live_box.add_theme_stylebox_override("panel",
		HudTheme.flat(HudTheme.PH_FILL, HudTheme.PH, 1, Vector4(8, 3, 8, 3)))
	live_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	live_box.add_child(live)
	var dot := ColorRect.new()
	dot.color = HudTheme.PH
	dot.custom_minimum_size = Vector2(HudTheme.dp(6), HudTheme.dp(6))
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_blink(dot, 1.1)
	live.add_child(dot)
	live.add_child(HudTheme.label("实时 LIVE", HudTheme.mono(10, 700, 0.18), 10, HudTheme.PH))
	_rail_dsn.add_child(live_box)

	# 右（CRAFT）：选中部件
	_rail_selected = HudTheme.hbox(14)
	_rail_selected.visible = false
	row.add_child(_rail_selected)
	_rail_selected.add_child(HudTheme.label("选中 SELECTED",
		HudTheme.mono(10, 400, 0.16), 10, HudTheme.MUTED))
	_rail_selected.add_child(_val("sel_name", "—", HudTheme.mono(13, 400, 0.10),
		13, HudTheme.BRIGHT))
	var sel_badge := PanelContainer.new()
	sel_badge.add_theme_stylebox_override("panel", HudTheme.flat(
		Color(0.79, 0.64, 0.15, 0.14), Color(0.79, 0.64, 0.15, 0.7), 1,
		Vector4(8, 3, 8, 3)))
	sel_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sel_badge.add_child(_val("sel_badge", "部件契约", HudTheme.mono(10, 700, 0.16),
		10, HudTheme.GOLD_BRIGHT))
	_rail_selected.add_child(sel_badge)


func _vrule(height: int) -> ColorRect:
	var r := ColorRect.new()
	r.color = Color(0.49, 1.0, 0.83, 0.3)
	r.custom_minimum_size = Vector2(HudTheme.dp(1), HudTheme.dp(height))
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


func _column(width: int, gap: int, on_right: bool) -> VBoxContainer:
	var col := HudTheme.vbox(gap)
	var px := HudTheme.dp(PAD_X)
	var top := HudTheme.dp(COL_TOP)
	var w := HudTheme.dp(width)
	if on_right:
		HudTheme.anchor(col, 1, 0, 1, 0, -(px + w), top, -px, top)
	else:
		HudTheme.anchor(col, 0, 0, 0, 0, px, top, px + w, top)
	col.custom_minimum_size = Vector2(HudTheme.dp(width), 0)
	add_child(col)
	return col


# ------------------------------------------------------------
#  01 SYSTEM · 左栏
# ------------------------------------------------------------
func _build_left_system() -> void:
	var col := _column(LEFT_W, 14, false)
	_left_system = col

	# ---- 时间 ----
	var time_block := HudTheme.vbox(2)
	col.add_child(time_block)
	var time_row := HudTheme.hbox(12)
	time_block.add_child(time_row)
	time_row.add_child(_val("date", "————-——-——", HudTheme.mono(44, 300, 0.02),
		44, HudTheme.BRIGHT))
	var tl := _val("time", "--:-- UTC", HudTheme.mono(15, 400), 15, HudTheme.PH)
	tl.size_flags_vertical = Control.SIZE_SHRINK_END
	time_row.add_child(HudTheme.pad(tl, 0, 0, 0, 4))
	time_block.add_child(_val("jdline", "JD — TDB  ·  任务第 — 天",
		HudTheme.mono(10, 400, 0.16), 10, HudTheme.MUTED))

	# ---- 渐变细线 ----
	col.add_child(_gradient(Color(0.49, 1.0, 0.83, 0.45),
		Color(0.49, 1.0, 0.83, 0.0), 1, true))

	# ---- 距地球 ----
	var range_block := HudTheme.vbox(6)
	col.add_child(range_block)
	var head := HudTheme.hbox(10)
	range_block.add_child(head)
	head.add_child(HudTheme.label("距地球", HudTheme.sans(12, 400, 0.18), 12, HudTheme.DIM2))
	head.add_child(HudTheme.label("RANGE TO EARTH", HudTheme.mono(10, 400, 0.16),
		10, HudTheme.MUTED2))
	head.add_child(HudTheme.spacer())
	head.add_child(HudTheme.badge("▪ 实测 MEASURED", HudTheme.PH,
		Color(0.49, 1.0, 0.83, 0.55), Color(0.31, 1.0, 0.82, 0.09)))

	var big := HudTheme.hbox(8)
	range_block.add_child(big)
	big.add_child(_val("range_au", "—", HudTheme.mono(52, 300), 52, HudTheme.BRIGHT))
	var au := _val("range_unit", "AU", HudTheme.mono(16, 400), 16, HudTheme.PH)
	au.size_flags_vertical = Control.SIZE_SHRINK_END
	big.add_child(HudTheme.pad(au, 0, 0, 0, 5))

	var sub := HudTheme.hbox(14)
	range_block.add_child(sub)
	sub.add_child(_val("range_km", "— km", HudTheme.mono(12, 400), 12, HudTheme.DIM2))
	sub.add_child(HudTheme.label("|", HudTheme.mono(12, 400), 12, HudTheme.MUTED2))
	sub.add_child(HudTheme.label("距离变化率", HudTheme.mono(12, 400), 12, HudTheme.DIM2))
	sub.add_child(_val("range_rate", "— km/s", HudTheme.mono(12, 400), 12, HudTheme.TEXT))
	range_block.add_child(_val("doppler", "↳ 这就是 DSN 的多普勒观测量 · X 波段 — Hz @ 8.420 GHz",
		HudTheme.mono(10, 400, 0.10), 10, HudTheme.MUTED2))

	# ---- 四格 ----
	col.add_child(_stat_grid([
		["OWLT 单程光时", "owlt", "小时"],
		["RTLT 往返光时", "rtlt", "天"],
		["距太阳 HELIOCENTRIC", "helio", "AU"],
		["日心速度 SPEED", "speed", "km/s"],
	]))

	# ---- RTG ----
	col.add_child(_build_rtg())

	# ---- 两条曲线 ----
	var sparks := HudTheme.vbox(8)
	col.add_child(sparks)
	spark_power = Sparkline.new()
	spark_power.custom_minimum_size = Vector2(HudTheme.dp(LEFT_W), HudTheme.dp(62))
	spark_power.caption = "RTG 输出 1977 → 2035 · MODELED"
	spark_power.caption_color = HudTheme.AMBER_DIM2
	spark_power.line_color = HudTheme.AMBER
	spark_power.fill_color = Color(1.0, 0.72, 0.30, 0.13)
	spark_power.marker_color = HudTheme.AMBER_BRIGHT
	spark_power.dash_color = Color(1.0, 0.72, 0.30, 0.45)
	sparks.add_child(spark_power)

	spark_dist = Sparkline.new()
	spark_dist.custom_minimum_size = Vector2(HudTheme.dp(LEFT_W), HudTheme.dp(62))
	spark_dist.caption = "距地球距离 1977 → 2026 · MEASURED"
	sparks.add_child(spark_dist)


func _stat_grid(cells: Array) -> PanelContainer:
	var outer := PanelContainer.new()
	outer.add_theme_stylebox_override("panel", HudTheme.flat(HudTheme.LINE_SOFT))
	outer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 1)
	grid.add_theme_constant_override("v_separation", 1)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outer.add_child(grid)
	for c in cells:
		var cell := PanelContainer.new()
		cell.add_theme_stylebox_override("panel",
			HudTheme.flat(HudTheme.SCREEN_BG, Color(0, 0, 0, 0), 0, Vector4(12, 10, 12, 10)))
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		grid.add_child(cell)
		var v := HudTheme.vbox(4)
		cell.add_child(v)
		v.add_child(HudTheme.label(String(c[0]), HudTheme.mono(9, 400, 0.18),
			9, HudTheme.MUTED))
		var row := HudTheme.hbox(0)
		v.add_child(row)
		row.add_child(_val(String(c[1]), "—", HudTheme.mono(26, 300), 26, HudTheme.TEXT))
		var unit := _val(String(c[1]) + "_unit", " " + String(c[2]),
			HudTheme.mono(13, 400), 13, HudTheme.PH)
		unit.size_flags_vertical = Control.SIZE_SHRINK_END
		row.add_child(HudTheme.pad(unit, 0, 0, 0, 3))
	return outer


func _build_rtg() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", HudTheme.flat(
		Color(1.0, 0.72, 0.30, 0.05), Color(1.0, 0.72, 0.30, 0.34), 1,
		Vector4(14, 12, 14, 12)))
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var v := HudTheme.vbox(8)
	panel.add_child(v)
	var ticks := CornerTicks.new()
	ticks.color = HudTheme.AMBER
	panel.add_child(ticks)

	var head := HudTheme.hbox(10)
	v.add_child(head)
	head.add_child(HudTheme.label("RTG 输出", HudTheme.sans(12, 400, 0.18), 12,
		HudTheme.AMBER_TEXT))
	head.add_child(HudTheme.spacer())
	head.add_child(HudTheme.badge("⚠ 推演 MODELED · 非遥测", HudTheme.AMBER_BRIGHT,
		HudTheme.AMBER, Color(1.0, 0.72, 0.30, 0.14), 9, 0.14))

	var row := HudTheme.hbox(8)
	v.add_child(row)
	row.add_child(_val("watts", "—", HudTheme.mono(40, 300), 40, HudTheme.AMBER_BRIGHT))
	var w_unit := HudTheme.label("W", HudTheme.mono(15, 400), 15, HudTheme.AMBER_TEXT)
	w_unit.size_flags_vertical = Control.SIZE_SHRINK_END
	row.add_child(HudTheme.pad(w_unit, 0, 0, 0, 4))
	row.add_child(HudTheme.spacer())
	var init := HudTheme.label("初始 470 W\n1977 → 2026", HudTheme.mono(10, 400), 10,
		HudTheme.AMBER_DIM2)
	init.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	init.size_flags_vertical = Control.SIZE_SHRINK_END
	row.add_child(init)

	var bars := HudTheme.vbox(5)
	v.add_child(bars)
	_fuel_bar = _bar_row_build(bars, "燃料剩余 FUEL", "fuel_pct")
	_conv_bar = _bar_row_build(bars, "转换器 CONVERT", "conv_pct")

	v.add_child(HudTheme.para("两者几乎相等：功率损失约一半来自钚衰变、一半来自热电偶老化。",
		HudTheme.sans(11, 400), 11, HudTheme.AMBER_DIM2, LEFT_W - 30, 6))
	return panel


func _bar_row_build(parent: Node, caption: String, key: String) -> Bar:
	var row := HudTheme.hbox(8)
	parent.add_child(row)
	var cap := HudTheme.label(caption, HudTheme.mono(10, 400), 10, HudTheme.AMBER_DIM)
	cap.custom_minimum_size = Vector2(HudTheme.dp(98), 0)
	row.add_child(cap)
	var bar := Bar.new()
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(bar)
	var pct := _val(key, "—", HudTheme.mono(10, 400), 10, HudTheme.AMBER_BRIGHT)
	pct.custom_minimum_size = Vector2(HudTheme.dp(44), 0)
	pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(pct)
	return bar


# ------------------------------------------------------------
#  01 SYSTEM · 右栏
# ------------------------------------------------------------
func _build_right_system() -> void:
	var col := _column(RIGHT_W, 13, true)
	_right_system = col

	# ---- 测控几何 ----
	var geo := HudTheme.vbox(8)
	col.add_child(geo)
	geo.add_child(_right_header("测控几何", "TRACKING GEOMETRY",
		HudTheme.badge("▪ 星历推导", HudTheme.PH, Color(0.49, 1.0, 0.83, 0.55),
			Color(0.31, 1.0, 0.82, 0.09))))
	var stats := HudTheme.hbox(28, BoxContainer.ALIGNMENT_END)
	geo.add_child(stats)
	stats.add_child(_stat_right("赤经 RA", "ra"))
	stats.add_child(_stat_right("赤纬 DEC", "dec"))
	stats.add_child(_stat_right("SEP 日地探夹角", "sep"))
	var note := _val("sep_note", "↳ 天线往哪儿指 · SEP < 5° 时链路被太阳噪声压制",
		HudTheme.mono(10, 400), 10, HudTheme.MUTED2)
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	geo.add_child(note)

	# ---- DSN 测站可见性 ----
	var dsn := HudTheme.vbox(7)
	col.add_child(dsn)
	var dh := HudTheme.hbox(10, BoxContainer.ALIGNMENT_END)
	dsn.add_child(dh)
	dh.add_child(HudTheme.label("中天高度 > 10° 才够得着", HudTheme.mono(9, 400, 0.16),
		9, HudTheme.MUTED2))
	dh.add_child(HudTheme.label("DSN 测站可见性", HudTheme.sans(12, 400, 0.18),
		12, HudTheme.TEXT3))
	_station_rows = HudTheme.vbox(7)
	dsn.add_child(_station_rows)

	# ---- 下行链路预算 ----
	var link := HudTheme.vbox(8)
	col.add_child(link)
	link.add_child(_right_header("下行链路预算", "DOWNLINK BUDGET", null))
	var ls := HudTheme.hbox(28, BoxContainer.ALIGNMENT_END)
	link.add_child(ls)
	ls.add_child(_stat_right("自由空间损耗 FSPL", "fspl", "dB"))
	ls.add_child(_stat_right("DSN 接收电平 RX", "rx", "dBm"))
	spark_rx = Sparkline.new()
	spark_rx.custom_minimum_size = Vector2(HudTheme.dp(RIGHT_W), HudTheme.dp(56))
	spark_rx.caption = "接收信号强度 dBm · 1977 → 2060"
	link.add_child(spark_rx)
	var lnote := HudTheme.para(
		"18 W 行波管 + 3.7 m 碟 → DSN 70 m。损耗随距离平方增长，这就是数据率从 115 kbps 降到 160 bps 的物理原因。",
		HudTheme.sans(11, 400), 11, HudTheme.DIM3, RIGHT_W, 6)
	lnote.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	link.add_child(lnote)

	# ---- 日心轨道 ----
	var orb := HudTheme.vbox(8)
	col.add_child(orb)
	orb.add_child(_right_header("日心轨道", "HELIOCENTRIC ORBIT", null))

	var r1 := HudTheme.hbox(10, BoxContainer.ALIGNMENT_END)
	orb.add_child(r1)
	r1.add_child(HudTheme.label("当前", HudTheme.mono(12, 400), 12, HudTheme.DIM))
	r1.add_child(_val("v_now", "—", HudTheme.mono(15, 400), 15, HudTheme.TEXT))
	r1.add_child(HudTheme.label("/ 逃逸", HudTheme.mono(12, 400), 12, HudTheme.DIM))
	r1.add_child(_val("v_esc", "—", HudTheme.mono(15, 400), 15, HudTheme.TEXT))
	r1.add_child(HudTheme.label("km/s", HudTheme.mono(12, 400), 12, HudTheme.DIM))

	var r2 := HudTheme.hbox(10, BoxContainer.ALIGNMENT_END)
	orb.add_child(r2)
	r2.add_child(_val("v_inf", "—", HudTheme.mono(11, 400), 11, HudTheme.DIM3))
	_esc_badge = PanelContainer.new()
	_esc_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_esc_badge.add_child(_val("escape", "已达逃逸条件 ESCAPE",
		HudTheme.mono(10, 700, 0.14), 10, HudTheme.PH))
	r2.add_child(_esc_badge)
	set_escaping(true)

	var dash := HudTheme.vbox(0)
	orb.add_child(dash)
	var r3 := HudTheme.hbox(10, BoxContainer.ALIGNMENT_END)
	r3.add_theme_constant_override("separation", 10)
	var r3wrap := PanelContainer.new()
	r3wrap.add_theme_stylebox_override("panel", HudTheme.edge(
		Color(0, 0, 0, 0), HudTheme.LINE_SOFT, 0, 1, 0, 0, Vector4(0, 6, 0, 0)))
	r3wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r3wrap.add_child(r3)
	dash.add_child(r3wrap)
	r3.add_child(HudTheme.label("119 AU · 2018-11-05 穿越", HudTheme.mono(11, 400),
		11, HudTheme.DIM3))
	r3.add_child(HudTheme.label("日球层顶", HudTheme.sans(12, 400), 12, HudTheme.BRIGHT))
	r3.add_child(_val("heliopause", "—", HudTheme.sans(12, 400), 12, HudTheme.PH))

	var r4 := HudTheme.hbox(6, BoxContainer.ALIGNMENT_END)
	orb.add_child(r4)
	r4.add_child(HudTheme.label("最近天体", HudTheme.mono(11, 400), 11, HudTheme.DIM3))
	r4.add_child(_val("near_name", "—", HudTheme.mono(11, 400), 11, HudTheme.TEXT))
	r4.add_child(_val("near_dist", "—", HudTheme.mono(11, 400), 11, HudTheme.DIM3))

	# ---- 相机锁定说明 + 操作提示 ----
	_lbl_focus_extra = HudTheme.para("", HudTheme.sans(11, 400), 11, HudTheme.AMBER_DIM,
		RIGHT_W, 5)
	_lbl_focus_extra.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_lbl_focus_extra.visible = false
	col.add_child(_lbl_focus_extra)

	var hint := PanelContainer.new()
	hint.add_theme_stylebox_override("panel", _dashed_box(Color(0.49, 1.0, 0.83, 0.22)))
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(hint)
	hint.add_child(HudTheme.para(
		"按 Tab 切到探测器特写，再右键点选部件，查看 ComponentID、归属判据与置信度。",
		HudTheme.sans(11, 400), 11, HudTheme.DIM3, RIGHT_W - 24, 6))


func _dashed_box(color: Color) -> StyleBoxFlat:
	# Godot 的 StyleBoxFlat 没有虚线描边，用低透明实线近似稿子里的 1px dashed。
	var sb := HudTheme.flat(Color(0, 0, 0, 0), color, 1, Vector4(12, 9, 12, 9))
	return sb


func _right_header(cn: String, en: String, badge: Control) -> PanelContainer:
	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", HudTheme.edge(
		Color(0, 0, 0, 0), HudTheme.LINE, 0, 0, 0, 1, Vector4(0, 0, 0, 6)))
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var row := HudTheme.hbox(10, BoxContainer.ALIGNMENT_END)
	wrap.add_child(row)
	if badge != null:
		row.add_child(badge)
	row.add_child(HudTheme.label(en, HudTheme.mono(10, 400, 0.18), 10, HudTheme.MUTED2))
	row.add_child(HudTheme.label(cn, HudTheme.sans(14, 400, 0.20), 14, HudTheme.TEXT))
	return wrap


func _stat_right(caption: String, key: String, unit: String = "") -> VBoxContainer:
	var v := HudTheme.vbox(2)
	var c := HudTheme.label(caption, HudTheme.mono(9, 400, 0.16), 9, HudTheme.MUTED)
	c.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.add_child(c)
	if unit == "":
		var val := _val(key, "—", HudTheme.mono(22, 300), 22, HudTheme.TEXT)
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		v.add_child(val)
	else:
		var row := HudTheme.hbox(4, BoxContainer.ALIGNMENT_END)
		v.add_child(row)
		row.add_child(_val(key, "—", HudTheme.mono(22, 300), 22, HudTheme.TEXT))
		var u := HudTheme.label(unit, HudTheme.mono(12, 400), 12, HudTheme.PH)
		u.size_flags_vertical = Control.SIZE_SHRINK_END
		row.add_child(HudTheme.pad(u, 0, 0, 0, 3))
	return v


## 刷新 DSN 测站三行。三行只建一次，之后只改文字和配色 ——
## 播放状态下 _refresh 是每帧调的，每帧重建节点纯属浪费。
func set_stations(rows: Array) -> void:
	if _station_widgets.is_empty():
		for _i in rows.size():
			_station_widgets.append(_build_station_row())
	for i in mini(rows.size(), _station_widgets.size()):
		var st: Dictionary = rows[i]
		var wg: Dictionary = _station_widgets[i]
		var ok: bool = bool(st["visible"])
		var fg: Color = HudTheme.PH if ok else HudTheme.RED_DIM
		(wg["panel"] as PanelContainer).add_theme_stylebox_override("panel",
			HudTheme.edge(Color(0.31, 1.0, 0.82, 0.09), HudTheme.PH, 2, 0, 0, 0,
				Vector4(10, 7, 10, 7)) if ok
			else HudTheme.edge(Color(1.0, 0.37, 0.37, 0.04), HudTheme.RED_BORDER, 2, 0, 0, 0,
				Vector4(10, 7, 10, 7)))
		var mark: Label = wg["mark"]
		mark.text = "●" if ok else "○"
		mark.add_theme_color_override("font_color",
			HudTheme.PH if ok else HudTheme.RED_DIM2)
		mark.modulate.a = 1.0
		wg["blink"] = ok
		var nm: Label = wg["name"]
		nm.text = String(st["name"])
		nm.add_theme_color_override("font_color", HudTheme.BRIGHT if ok else HudTheme.DIM)
		var cd: Label = wg["code"]
		cd.text = String(st["code"])
		cd.add_theme_color_override("font_color", HudTheme.DIM3 if ok else HudTheme.MUTED2)
		var deg: Label = wg["deg"]
		deg.text = _typo_minus("%+.1f°" % float(st["culmination_deg"]))
		deg.add_theme_color_override("font_color", fg)
		var state: Label = wg["state"]
		state.text = "可跟踪" if ok else "地平线以下"
		state.add_theme_color_override("font_color", fg)


func _build_station_row() -> Dictionary:
	var pc := PanelContainer.new()
	pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_station_rows.add_child(pc)
	var row := HudTheme.hbox(12)
	pc.add_child(row)
	var mark := HudTheme.label("○", HudTheme.mono(10, 400), 10, HudTheme.RED_DIM2)
	row.add_child(mark)
	var name_row := HudTheme.hbox(6)
	name_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_row)
	var nm := HudTheme.label("", HudTheme.mono(12, 400), 12, HudTheme.DIM)
	name_row.add_child(nm)
	var cd := HudTheme.label("", HudTheme.mono(9, 400), 9, HudTheme.MUTED2)
	name_row.add_child(cd)
	var deg := HudTheme.label("", HudTheme.mono(13, 400), 13, HudTheme.RED_DIM)
	row.add_child(deg)
	var state := HudTheme.label("", HudTheme.mono(9, 400, 0.12), 9, HudTheme.RED_DIM)
	row.add_child(state)
	return {"panel": pc, "mark": mark, "name": nm, "code": cd, "deg": deg,
		"state": state, "blink": false}


static func _typo_minus(t: String) -> String:
	return t.replace("-", "\u2212")


# ------------------------------------------------------------
#  02 CRAFT · 左栏（部件契约）
# ------------------------------------------------------------
func _build_left_craft() -> void:
	var col := _column(400, 16, false)
	_left_craft = col

	var block := HudTheme.vbox(8)
	col.add_child(block)
	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", HudTheme.edge(
		Color(0, 0, 0, 0), HudTheme.LINE, 0, 0, 0, 1, Vector4(0, 0, 0, 6)))
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	block.add_child(wrap)
	var hrow := HudTheme.hbox(10)
	wrap.add_child(hrow)
	hrow.add_child(HudTheme.label("部件契约", HudTheme.sans(14, 400, 0.20), 14, HudTheme.TEXT))
	hrow.add_child(HudTheme.label("COMPONENT CONTRACT", HudTheme.mono(10, 400, 0.18),
		10, HudTheme.MUTED2))

	block.add_child(HudTheme.label("COMPONENT ID", HudTheme.mono(11, 400, 0.14),
		11, HudTheme.MUTED))
	block.add_child(_val("comp_id", "—", HudTheme.mono(20, 400), 20, HudTheme.BRIGHT))
	block.add_child(HudTheme.pad(HudTheme.label("归属判据 ATTRIBUTION",
		HudTheme.mono(11, 400, 0.14), 11, HudTheme.MUTED), 0, 6))
	_lbl_attr = HudTheme.para("—", HudTheme.sans(12, 400), 12, HudTheme.TEXT2, 400, 8)
	block.add_child(_lbl_attr)
	_lbl_alias = HudTheme.para("", HudTheme.sans(11, 400), 11, HudTheme.AMBER_DIM, 400, 6)
	_lbl_alias.visible = false
	block.add_child(_lbl_alias)

	# ---- 无遥测 ----
	var tel := PanelContainer.new()
	tel.add_theme_stylebox_override("panel", HudTheme.flat(
		Color(1.0, 0.37, 0.37, 0.05), Color(1.0, 0.37, 0.37, 0.3), 1,
		Vector4(14, 12, 14, 12)))
	tel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(tel)
	var tv := HudTheme.vbox(6)
	tel.add_child(tv)
	var tt := CornerTicks.new()
	tt.color = HudTheme.RED
	tt.both = false
	tel.add_child(tt)
	var tb := HudTheme.badge("✕ 无遥测 NO TELEMETRY", HudTheme.RED_BRIGHT,
		HudTheme.RED, Color(1.0, 0.37, 0.37, 0.12))
	tb.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	tv.add_child(tb)
	tv.add_child(HudTheme.para(
		"NASA 不提供 Voyager 2 的公开工程遥测，所以此处没有该部件的温度／电压读数 —— 没有就是没有。",
		HudTheme.sans(12, 400), 12, HudTheme.RED_TEXT, 372, 8))

	# ---- 唱片上真实存在的物理信号 ----
	var sig := HudTheme.vbox(9)
	col.add_child(sig)
	sig.add_child(HudTheme.label("唱片上真实存在的物理信号",
		HudTheme.mono(10, 400, 0.18), 10, HudTheme.MUTED))
	sig.add_child(_signal_button("▶", "1000 Hz 参考校准音", "2.5 s · 22.05 kHz",
		false, func() -> void: tone_pressed.emit()))
	sig.add_child(_signal_button("▶", "图像扫描线编码", "48 × 96 · 700–3000 Hz",
		false, func() -> void: scan_pressed.emit()))
	sig.add_child(_signal_button("⟳", "转起来", "16⅔ rpm 真实转速",
		true, func() -> void: spin_pressed.emit()))


func _signal_button(icon: String, title: String, meta: String, gold: bool,
		cb: Callable) -> HudClickPanel:
	var p := HudClickPanel.new()
	if gold:
		p.setup(
			HudTheme.flat(Color(0.79, 0.64, 0.15, 0.08), Color(0.79, 0.64, 0.15, 0.4), 1,
				Vector4(12, 9, 12, 9)),
			HudTheme.flat(Color(0.79, 0.64, 0.15, 0.16), Color(0.79, 0.64, 0.15, 0.4), 1,
				Vector4(12, 9, 12, 9)))
	else:
		p.setup(
			HudTheme.flat(HudTheme.PH_FILL_SOFT, HudTheme.LINE, 1, Vector4(12, 9, 12, 9)),
			HudTheme.flat(Color(0.31, 1.0, 0.82, 0.14), HudTheme.LINE, 1,
				Vector4(12, 9, 12, 9)))
	p.pressed.connect(cb)
	var row := HudTheme.hbox(11)
	p.add_child(row)
	row.add_child(HudTheme.label(icon, HudTheme.mono(13, 400), 13,
		HudTheme.GOLD_BRIGHT if gold else HudTheme.PH))
	var t := HudTheme.label(title, HudTheme.sans(13, 400), 13,
		HudTheme.GOLD_PALE if gold else HudTheme.BRIGHT)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(t)
	row.add_child(HudTheme.label(meta, HudTheme.mono(9, 400, 0.12), 9,
		HudTheme.AMBER_DIM if gold else HudTheme.DIM3))
	return p


# ------------------------------------------------------------
#  02 CRAFT · 右栏（金唱片载荷）
# ------------------------------------------------------------
func _build_right_craft() -> void:
	var col := _column(RIGHT_W, 14, true)
	_right_craft = col

	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", HudTheme.edge(
		Color(0, 0, 0, 0), Color(0.79, 0.64, 0.15, 0.35), 0, 0, 0, 1,
		Vector4(0, 0, 0, 6)))
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(wrap)
	var hrow := HudTheme.hbox(10)
	wrap.add_child(hrow)
	hrow.add_child(HudTheme.label("旅行者金唱片", HudTheme.sans(14, 400, 0.20),
		14, HudTheme.GOLD_PALE))
	hrow.add_child(HudTheme.label("PAYLOAD MANIFEST", HudTheme.mono(10, 400, 0.18),
		10, HudTheme.AMBER_DIM2))

	# 四格统计
	var outer := PanelContainer.new()
	outer.add_theme_stylebox_override("panel",
		HudTheme.flat(Color(0.79, 0.64, 0.15, 0.24)))
	outer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(outer)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 1)
	grid.add_theme_constant_override("v_separation", 1)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outer.add_child(grid)
	var spec := GoldenRecord.SPEC
	var cells := [
		[str(int(spec["images"])), "张图像"],
		[str(int(spec["languages"])), "种语言问候"],
		["%d" % int(spec["music_tracks"]), "首乐曲 / %d 分" % int(spec["music_minutes"])],
		[str(int(spec["sounds_minutes"])), "分钟地球之声"],
	]
	for c in cells:
		var cell := PanelContainer.new()
		cell.add_theme_stylebox_override("panel", HudTheme.flat(
			HudTheme.SCREEN_BG, Color(0, 0, 0, 0), 0, Vector4(10, 9, 10, 9)))
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		grid.add_child(cell)
		var v := HudTheme.vbox(3)
		cell.add_child(v)
		v.add_child(HudTheme.label(String(c[0]), HudTheme.mono(26, 300), 26,
			HudTheme.GOLD_PALE))
		v.add_child(HudTheme.label(String(c[1]), HudTheme.sans(10, 400), 10,
			HudTheme.AMBER_DIM2))

	col.add_child(HudTheme.para(
		"封面蚀刻图案为 NASA 模型自带真实贴图：左上播放示意 · 右上二进制时基 · 中间图像光栅 · 左下 14 颗脉冲星定位图 · 右下氢原子跃迁。%s。"
			% String(spec["clock"]),
		HudTheme.sans(11, 400), 11, HudTheme.DIM3, RIGHT_W, 8))

	# 载荷分区
	_record_sections = HudTheme.vbox(10)
	col.add_child(_record_sections)
	var idx := 0
	for sec in GoldenRecord.CONTENTS:
		var gold := idx == 3
		var sv := HudTheme.vbox(4)
		_record_sections.add_child(sv)
		var trow := HudTheme.hbox(8)
		sv.add_child(trow)
		var sq := ColorRect.new()
		sq.color = HudTheme.AMBER if gold else HudTheme.PH
		sq.custom_minimum_size = Vector2(HudTheme.dp(5), HudTheme.dp(5))
		sq.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		trow.add_child(sq)
		trow.add_child(HudTheme.label(String(sec["section"]),
			HudTheme.sans(12, 400, 0.14), 12,
			HudTheme.GOLD_PALE if gold else HudTheme.TEXT))
		var items := PackedStringArray()
		for it in sec["items"]:
			items.append(String(it))
		sv.add_child(HudTheme.pad(HudTheme.para(" · ".join(items),
			HudTheme.sans(11, 400), 11, HudTheme.DIM, RIGHT_W - 13, 9), 13))
		idx += 1

	# 版权说明
	var note := PanelContainer.new()
	note.add_theme_stylebox_override("panel", HudTheme.edge(
		Color(1.0, 0.72, 0.30, 0.06), HudTheme.AMBER, 2, 0, 0, 0,
		Vector4(12, 10, 12, 10)))
	note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(note)
	var nv := HudTheme.vbox(5)
	note.add_child(nv)
	nv.add_child(HudTheme.label("⚠ 为什么这里没有音乐", HudTheme.mono(9, 700, 0.16),
		9, HudTheme.AMBER_BRIGHT))
	nv.add_child(HudTheme.para(
		"那 27 首绝大多数是受版权保护的商业录音，NASA 当年只取得一次性搭载授权，并未置于公有领域。所以本项目不打包任何录音，只合成唱片上真实存在的物理信号。",
		HudTheme.sans(11, 400), 11, HudTheme.AMBER_DIM, RIGHT_W - 26, 8))


# ------------------------------------------------------------
#  底栏
# ------------------------------------------------------------
func _build_bar(jd_min: float, jd_max: float, events: Array, focus_items: Array,
		focus_count_text: String) -> void:
	_bar = Control.new()
	HudTheme.anchor(_bar, 0, 1, 1, 1, 0, -HudTheme.dp(BAR_H_SYSTEM))
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bar)

	_bar_bg = _gradient(Color(0.008, 0.035, 0.043, 0.1), Color(0.008, 0.078, 0.067, 0.86), 0)
	_bar.add_child(_bar_bg)
	var border := ColorRect.new()
	border.color = Color(0.49, 1.0, 0.83, 0.20)
	HudTheme.anchor(border, 0, 0, 1, 0, 0, 0, 0, HudTheme.dp(1))
	border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.add_child(border)

	# 时间轴
	_timeline_group = Control.new()
	HudTheme.fill(_timeline_group, HudTheme.dp(PAD_X), 0, -HudTheme.dp(PAD_X), 0)
	_timeline_group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.add_child(_timeline_group)
	timeline = HudTimeline.new()
	HudTheme.fill(timeline)
	timeline.min_value = jd_min
	timeline.max_value = jd_max
	timeline.value = jd_min
	timeline.events = events
	_timeline_group.add_child(timeline)

	# 控制行
	_bar_row = HudTheme.hbox(10)
	HudTheme.anchor(_bar_row, 0, 1, 1, 1, HudTheme.dp(PAD_X), -HudTheme.dp(34),
		-HudTheme.dp(PAD_X), -HudTheme.dp(12))
	_bar.add_child(_bar_row)

	# 播放
	var play := HudClickPanel.new()
	play.setup(
		HudTheme.flat(Color(0.31, 1.0, 0.82, 0.12), HudTheme.PH, 1, Vector4(14, 6, 14, 6)),
		HudTheme.flat(Color(0.31, 1.0, 0.82, 0.22), HudTheme.PH, 1, Vector4(14, 6, 14, 6)))
	play.pressed.connect(func() -> void: play_pressed.emit())
	_bar_row.add_child(play)
	var prow := HudTheme.hbox(9)
	play.add_child(prow)
	prow.add_child(HudTheme.label("▶", HudTheme.mono(13, 400), 13, HudTheme.PH))
	_play_lbl = HudTheme.label("播放", HudTheme.sans(13, 400), 13, HudTheme.BRIGHT)
	prow.add_child(_play_lbl)
	prow.add_child(_val("play_speed", "60 天/秒", HudTheme.mono(10, 400), 10, HudTheme.DIM3))

	# 视图分段
	var seg_wrap := PanelContainer.new()
	seg_wrap.add_theme_stylebox_override("panel",
		HudTheme.flat(Color(0, 0, 0, 0), HudTheme.LINE, 1))
	seg_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar_row.add_child(seg_wrap)
	var seg := HudTheme.hbox(0)
	seg_wrap.add_child(seg)
	_seg_system = HudClickPanel.new()
	_seg_system.pressed.connect(func() -> void: mode_pressed.emit(false))
	_seg_system_lbl = HudTheme.label("SYSTEM 太阳系", HudTheme.mono(11, 400, 0.14),
		11, HudTheme.BRIGHT)
	_seg_system.add_child(_seg_system_lbl)
	seg.add_child(_seg_system)
	_seg_craft = HudClickPanel.new()
	_seg_craft.pressed.connect(func() -> void: mode_pressed.emit(true))
	_seg_craft_lbl = HudTheme.label("CRAFT 特写", HudTheme.mono(11, 400, 0.14),
		11, HudTheme.DIM3)
	_seg_craft.add_child(_seg_craft_lbl)
	seg.add_child(_seg_craft)

	_bar_row.add_child(HudTheme.pad(_vrule(22), 0, 6))

	# 相机锁定
	_lbl_lock_cap = HudTheme.label("相机锁定 LOCK", HudTheme.mono(10, 400, 0.16),
		10, HudTheme.MUTED)
	_lbl_lock_cap.name = "LockCap"
	_bar_row.add_child(_lbl_lock_cap)
	var lock := PanelContainer.new()
	lock.add_theme_stylebox_override("panel",
		HudTheme.flat(Color(0, 0, 0, 0), HudTheme.LINE, 1, Vector4(12, 3, 12, 3)))
	lock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar_row.add_child(lock)
	var lrow := HudTheme.hbox(12)
	lock.add_child(lrow)
	btn_focus = OptionButton.new()
	btn_focus.fit_to_longest_item = false
	btn_focus.clip_text = true
	btn_focus.custom_minimum_size = Vector2(HudTheme.dp(84), 0)
	_style_option(btn_focus)
	for it in focus_items:
		btn_focus.add_item(String(it["label"]))
		btn_focus.set_item_metadata(btn_focus.item_count - 1, String(it["meta"]))
	lrow.add_child(btn_focus)
	lrow.add_child(HudTheme.label("▼ " + focus_count_text, HudTheme.mono(9, 400), 9,
		HudTheme.DIM3))

	# 界面倍率。见 HudTheme.scale：倍率是乘进字号和布局像素的，所以换档
	# 会重建整层 HUD（twin.gd._rebuild_hud），不是每帧能调的东西。
	btn_ui_scale = _scale_picker(_bar_row, "界面", [1.0, 1.5], UI_SCALE_TIP,
		func(v: float) -> void: ui_scale_picked.emit(v))

	# 窗口装不下当前倍率时直说 —— HUD 是按 1600×900 排的，倍率 s 就需要
	# 约 1600s × 900s 的窗口，否则两栏会盖到底栏上。
	_lbl_too_small = HudTheme.label("", HudTheme.mono(10, 400, 0.14), 10,
		HudTheme.AMBER_BRIGHT)
	_lbl_too_small.visible = false
	_lbl_too_small.name = "TooSmall"
	_bar_row.add_child(_lbl_too_small)

	_bar_row.add_child(HudTheme.spacer())

	# 数据来源图例。窄窗口下换紧凑版，再窄就整块收掉 —— 但"每个数字都带
	# 来源标注"是项目第一纪律，能留就留，宁可牺牲字数不牺牲这条信息。
	_legend = _build_legend([
		["▪", HudTheme.PH], ["轨迹 = JPL HORIZONS 真实定轨（target −32）", HudTheme.MUTED],
		["▪", HudTheme.AMBER], ["RTG = 物理模型推演", HudTheme.MUTED],
		["▪", HudTheme.PH], ["DSN = 60 秒实时", HudTheme.MUTED],
	])
	_legend_compact = _build_legend([
		["▪", HudTheme.PH], ["轨迹 = 实测定轨", HudTheme.MUTED],
		["▪", HudTheme.AMBER], ["RTG = 推演", HudTheme.MUTED],
		["▪", HudTheme.PH], ["DSN = 实时", HudTheme.MUTED],
	])
	_legend_compact.visible = false
	_legend.name = "Legend"
	_legend_compact.name = "LegendCompact"

	# CRAFT 模式下的操作提示（替换图例）
	_craft_hint = HudTheme.label("右键点选部件 · RIGHT-CLICK TO PICK · 三角网格精确拾取",
		HudTheme.mono(10, 400, 0.14), 10, HudTheme.MUTED)
	_craft_hint.visible = false
	_craft_hint.name = "CraftHint"
	_bar_row.add_child(_craft_hint)


func _build_legend(items: Array) -> HBoxContainer:
	var box := HudTheme.hbox(8)
	var f := HudTheme.mono(10, 400, 0.14)
	for it in items:
		box.add_child(HudTheme.label(String(it[0]), f, 10, it[1]))
	_bar_row.add_child(box)
	return box


func _build_touch_controls() -> void:
	if not DisplayServer.is_touchscreen_available() and not OS.has_feature("mobile"):
		return
	# 这组快捷键只在真机出现，独立压在底栏右侧，避免挤动桌面设计稿的控件。
	_touch_controls = HudTheme.hbox(6)
	_touch_controls.name = "TouchControls"
	_touch_controls.custom_minimum_size = Vector2(HudTheme.dp(274), HudTheme.dp(44))
	HudTheme.anchor(_touch_controls, 1, 1, 1, 1,
		-HudTheme.dp(PAD_X + 274), -HudTheme.dp(56), -HudTheme.dp(PAD_X), -HudTheme.dp(12))
	add_child(_touch_controls)
	_touch_controls.add_child(_touch_button("播/停", func() -> void: play_pressed.emit()))
	_touch_controls.add_child(_touch_button("旅行者", func() -> void: focus_probe_pressed.emit()))
	_touch_controls.add_child(_touch_button("太阳", func() -> void: focus_sun_pressed.emit()))
	_touch_controls.add_child(_touch_button("视图", func() -> void:
		mode_pressed.emit(not _craft_mode)))


func _touch_button(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(HudTheme.dp(64), HudTheme.dp(44))
	button.add_theme_stylebox_override("normal",
		HudTheme.flat(HudTheme.PH_FILL_SOFT, HudTheme.LINE, 1, Vector4(8, 4, 8, 4)))
	button.add_theme_stylebox_override("hover",
		HudTheme.flat(HudTheme.PH_FILL, HudTheme.PH, 1, Vector4(8, 4, 8, 4)))
	button.add_theme_stylebox_override("pressed",
		HudTheme.flat(HudTheme.PH_FILL_STRONG, HudTheme.PH, 1, Vector4(8, 4, 8, 4)))
	button.add_theme_stylebox_override("focus",
		HudTheme.flat(HudTheme.PH_FILL_SOFT, HudTheme.PH, 1, Vector4(8, 4, 8, 4)))
	button.add_theme_font_override("font", HudTheme.sans(12, 400))
	button.add_theme_font_size_override("font_size", HudTheme.fs(12))
	button.add_theme_color_override("font_color", HudTheme.TEXT)
	button.add_theme_color_override("font_hover_color", HudTheme.BRIGHT)
	button.add_theme_color_override("font_pressed_color", HudTheme.BRIGHT)
	button.add_theme_color_override("font_focus_color", HudTheme.BRIGHT)
	button.pressed.connect(action)
	return button


## 底栏这一行在窄窗口（4:3、竖屏、或界面缩放调大之后）装不下。
##
## 不拍阈值，直接量：从最全的形态开始，只要 HBox 的最小宽度超过可用宽度，
## 就按优先级降一级再量一次。这样换字体、换语言、加控件都不用回来改数字。
## 降级顺序：图例长版 → 紧凑版 → 收掉图例 → 收掉"相机锁定"字样。
## 控件本身（播放、视图、相机锁定）永远不动。
func _layout_bar_row() -> void:
	if _legend == null:
		return
	_legend.visible = not _craft_mode
	_legend_compact.visible = false
	_craft_hint.visible = _craft_mode
	_lbl_lock_cap.visible = true

	var avail := size.x - HudTheme.dp(PAD_X) * 2.0
	if _touch_controls != null:
		# 真机快捷键占了底栏右侧后，不再让只读提示与它叠在同一块触摸区域。
		_legend.visible = false
		_legend_compact.visible = false
		_craft_hint.visible = false
		avail -= _touch_controls.custom_minimum_size.x + HudTheme.dp(10)
		if bar_row_min_width() > avail:
			_lbl_lock_cap.visible = false
		return
	var step := 0
	while step < 4 and bar_row_min_width() > avail:
		step += 1
		match step:
			1:
				_legend.visible = false
				_legend_compact.visible = not _craft_mode
			2:
				_legend_compact.visible = false
			3:
				_lbl_lock_cap.visible = false
			4:
				_craft_hint.visible = false


## 当前倍率下窗口够不够放整套 HUD。
func _check_fits() -> void:
	if _lbl_too_small == null:
		return
	var need := Vector2(HudTheme.dp(1600), HudTheme.dp(900))
	var fits := size.x >= need.x - 1.0 and size.y >= need.y - 1.0
	_lbl_too_small.visible = not fits
	if not fits:
		_lbl_too_small.text = "⚠ 窗口偏小，%d%% 需要 %d×%d" % [
			int(round(HudTheme.scale * 100.0)), int(need.x), int(need.y)]


## 自检/诊断用：底栏那一行每个可见部件占多少宽。
func bar_row_breakdown() -> String:
	var parts := PackedStringArray()
	for child in _bar_row.get_children():
		var ctl := child as Control
		if ctl == null or not ctl.visible:
			continue
		if ctl.size_flags_horizontal & Control.SIZE_EXPAND:
			continue
		parts.append("%s=%d" % [ctl.name, int(ctl.get_combined_minimum_size().x)])
	return " ".join(parts)


## 底栏那一行当前形态需要的最小宽度。自检和降级逻辑都用它。
##
## 自己按可见子控件求和，不用 _bar_row.get_combined_minimum_size() ——
## 改完 visible 之后容器的最小尺寸是**下一帧**才更新的，同一帧里读到的是旧
## 值，降级循环会因此多降一级（1600 宽也把长图例收掉了，就是这么来的）。
func bar_row_min_width() -> float:
	if _bar_row == null:
		return 0.0
	var total := 0.0
	var n := 0
	for child in _bar_row.get_children():
		var ctl := child as Control
		if ctl == null or not ctl.visible:
			continue
		if ctl.size_flags_horizontal & Control.SIZE_EXPAND:
			continue        # 弹性占位不占最小宽度
		total += ctl.get_combined_minimum_size().x
		n += 1
	if n > 1:
		total += float(_bar_row.get_theme_constant("separation")) * float(n - 1)
	return total


const UI_SCALE_TIP := "界面倍率。按 1.5 倍字号重新栅格化字体并重排布局，\n所以放大后文字仍然是原生锐利的（不是把画面拉伸）。\n1.5 倍需要窗口约 2400×1350 才装得下整套 HUD。"


## "界面 [100% ▾]" 这种小方框下拉。样式跟相机锁定那个保持一致。
func _scale_picker(parent: Node, caption: String, values: Array, tip: String,
		on_pick: Callable) -> OptionButton:
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel",
		HudTheme.flat(Color(0, 0, 0, 0), HudTheme.LINE, 1, Vector4(10, 3, 8, 3)))
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.tooltip_text = tip
	parent.add_child(box)
	var row := HudTheme.hbox(8)
	box.add_child(row)
	row.add_child(HudTheme.label(caption, HudTheme.sans(12, 400), 12, HudTheme.DIM3))
	var ob := OptionButton.new()
	ob.fit_to_longest_item = false
	ob.clip_text = true
	ob.custom_minimum_size = Vector2(HudTheme.dp(50), 0)
	ob.tooltip_text = tip
	_style_option(ob)
	for v in values:
		ob.add_item("%d%%" % int(round(float(v) * 100.0)))
		ob.set_item_metadata(ob.item_count - 1, float(v))
	ob.item_selected.connect(func(i: int) -> void:
		on_pick.call(float(ob.get_item_metadata(i))))
	row.add_child(ob)
	row.add_child(HudTheme.label("▾", HudTheme.mono(9, 400), 9, HudTheme.DIM3))
	return ob


## 把界面倍率下拉对齐到实际生效的值。
func set_ui_scale_selection(v: float) -> void:
	if btn_ui_scale == null:
		return
	for i in btn_ui_scale.item_count:
		if is_equal_approx(float(btn_ui_scale.get_item_metadata(i)), v):
			btn_ui_scale.selected = i
			return


func _style_option(ob: OptionButton) -> void:
	var empty := HudTheme.flat(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, Vector4(0, 2, 4, 2))
	for s in ["normal", "hover", "pressed", "focus", "disabled"]:
		ob.add_theme_stylebox_override(s, empty)
	ob.add_theme_font_override("font", HudTheme.sans(12, 400))
	ob.add_theme_font_size_override("font_size", 12)
	ob.add_theme_color_override("font_color", HudTheme.TEXT)
	ob.add_theme_color_override("font_hover_color", HudTheme.BRIGHT)
	ob.add_theme_color_override("font_focus_color", HudTheme.BRIGHT)
	ob.add_theme_color_override("font_pressed_color", HudTheme.BRIGHT)
	ob.add_theme_icon_override("arrow", _blank_tex())
	ob.flat = true
	var pop := ob.get_popup()
	pop.add_theme_stylebox_override("panel",
		HudTheme.flat(Color(0.008, 0.035, 0.043, 0.97), HudTheme.LINE, 1, Vector4(4, 4, 4, 4)))
	pop.add_theme_stylebox_override("hover", HudTheme.flat(HudTheme.PH_FILL_STRONG))
	pop.add_theme_font_override("font", HudTheme.sans(12, 400))
	pop.add_theme_font_size_override("font_size", 12)
	pop.add_theme_color_override("font_color", HudTheme.TEXT)
	pop.add_theme_color_override("font_hover_color", HudTheme.BRIGHT)


func _build_brackets() -> void:
	var specs := [[1, 1], [-1, 1], [1, -1], [-1, -1]]
	for s in specs:
		var b := Bracket.new()
		b.hx = int(s[0])
		b.vy = int(s[1])
		b.size = Vector2(HudTheme.dp(20), HudTheme.dp(20))
		add_child(b)
		_brackets.append(b)
	_layout_brackets()
	resized.connect(_layout_brackets)


func _layout_brackets() -> void:
	if _brackets.is_empty():
		return
	var bar_h := HudTheme.dp(BAR_H_SYSTEM if not _craft_mode else BAR_H_CRAFT)
	var top := HudTheme.dp(66)
	var bottom := size.y - bar_h - HudTheme.dp(14)
	var xs := [HudTheme.dp(14), size.x - HudTheme.dp(34)]
	var ys := [top, bottom]
	for b in _brackets:
		var br: Bracket = b
		br.position = Vector2(xs[0] if br.hx > 0 else xs[1], ys[0] if br.vy > 0 else ys[1])


# ============================================================
#  对外接口
# ============================================================

func set_mode(craft: bool) -> void:
	_craft_mode = craft
	_left_system.visible = not craft
	_right_system.visible = not craft
	_left_craft.visible = craft
	_right_craft.visible = craft and _right_craft.get_meta("record_on", false)
	_rail_dsn.visible = not craft
	_rail_selected.visible = craft
	_bar.offset_top = -HudTheme.dp(BAR_H_CRAFT if craft else BAR_H_SYSTEM)
	_timeline_group.visible = not craft
	for b in _brackets:
		(b as Control).visible = not craft
	_layout_bar_row()
	_seg_system_lbl.add_theme_color_override("font_color",
		HudTheme.BRIGHT if not craft else HudTheme.DIM3)
	_seg_craft_lbl.add_theme_color_override("font_color",
		HudTheme.BRIGHT if craft else HudTheme.DIM3)
	_seg_system.setup(HudTheme.flat(
		HudTheme.PH_FILL_STRONG if not craft else Color(0, 0, 0, 0),
		Color(0, 0, 0, 0), 0, Vector4(14, 7, 14, 7)))
	_seg_craft.setup(HudTheme.flat(
		HudTheme.PH_FILL_STRONG if craft else Color(0, 0, 0, 0),
		Color(0, 0, 0, 0), 0, Vector4(14, 7, 14, 7)))
	annotations.visible = not craft
	backdrop.visible = not craft
	if _scrim_right != null:
		_scrim_right.visible = _right_system.visible or _right_craft.visible
	_layout_brackets()


## 自检用：底栏那一行里某块内容当前是否显示（窄窗口降级的验收点）。
func bar_item_visible(which: String) -> bool:
	match which:
		"legend": return _legend != null and _legend.visible
		"legend_compact": return _legend_compact != null and _legend_compact.visible
		"craft_hint": return _craft_hint != null and _craft_hint.visible
		"lock_cap": return _lbl_lock_cap != null and _lbl_lock_cap.visible
		"too_small": return _lbl_too_small != null and _lbl_too_small.visible
	return false


## 自检用：某一栏的实际尺寸（验证倍率有没有真的落到布局上）。
func column_size(which: String) -> Vector2:
	match which:
		"left_system": return _left_system.size
		"right_system": return _right_system.size
		"left_craft": return _left_craft.size
		"right_craft": return _right_craft.size
	return Vector2.ZERO


## 自检用：某一屏是否在显示。
func panel_visible(which: String) -> bool:
	match which:
		"left_system": return _left_system.visible
		"right_system": return _right_system.visible
		"left_craft": return _left_craft.visible
		"right_craft": return _right_craft.visible
		"timeline": return _timeline_group.visible
	return false


func play_label() -> String:
	return _play_lbl.text


## 逃逸徽章的配色跟状态走：达成逃逸是磷光绿，仍在束缚轨道上用琥珀色 ——
## 稿子里只画了逃逸那一种，但 1979 年的探测器还没逃逸，绿色会说谎。
func set_escaping(escaping: bool) -> void:
	if _esc_badge == null:
		return
	var col: Color = HudTheme.PH if escaping else HudTheme.AMBER
	var bg := Color(0.31, 1.0, 0.82, 0.12) if escaping else Color(1.0, 0.72, 0.30, 0.12)
	_esc_badge.add_theme_stylebox_override("panel",
		HudTheme.flat(bg, col, 1, Vector4(8, 3, 8, 3)))
	(_vals["escape"] as Label).add_theme_color_override("font_color", col)


## 尺寸变化后重排跟宽高有关的东西。
func relayout() -> void:
	_layout_brackets()
	_check_fits()
	_layout_bar_row()
	_update_overlay_metrics()


func set_playing(playing: bool) -> void:
	_play_lbl.text = "暂停" if playing else "播放"


func set_dsn(bbcode: String) -> void:
	_lbl_dsn.text = bbcode


func set_bars(fuel: float, conv: float) -> void:
	_fuel_bar.ratio = fuel
	_conv_bar.ratio = conv


func set_focus_note(text: String) -> void:
	_lbl_focus_extra.text = text
	_lbl_focus_extra.visible = text != ""


## 部件契约。alias 为空时不显示那一行。
func set_component(id_text: String, attribution: String, alias: String,
		badge_text: String) -> void:
	set_values({"comp_id": id_text, "sel_name": id_text, "sel_badge": badge_text})
	_lbl_attr.text = attribution
	_lbl_alias.text = alias
	_lbl_alias.visible = alias != ""


func set_record_visible(on: bool) -> void:
	_right_craft.set_meta("record_on", on)
	_right_craft.visible = on and _craft_mode
	if _scrim_right != null:
		_scrim_right.visible = _right_system.visible or _right_craft.visible


## FATAL 屏：数据包没加载出来时的唯一画面。
func build_fatal(message: String) -> void:
	var bg := ColorRect.new()
	bg.color = HudTheme.RED_BG
	HudTheme.fill(bg)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var glow := _radial(Color(0.35, 0.08, 0.09, 0.34), Color(0.04, 0.012, 0.016, 0.0))
	add_child(glow)

	var grid := HudBackdrop.new()
	grid.line_color = Color(1.0, 0.37, 0.37, 0.05)
	grid.dot_color = Color(0, 0, 0, 0)
	HudTheme.fill(grid)
	add_child(grid)

	for at_top in [true, false]:
		var s := Stripes.new()
		if at_top:
			HudTheme.anchor(s, 0, 0, 1, 0, 0, 0, 0, HudTheme.dp(6))
		else:
			HudTheme.anchor(s, 0, 1, 1, 1, 0, -HudTheme.dp(6))
		s.modulate.a = 0.75
		add_child(s)

	var center := HudTheme.vbox(22)
	HudTheme.anchor(center, 0.5, 0.5, 0.5, 0.5)
	center.custom_minimum_size = Vector2(HudTheme.dp(840), 0)
	center.grow_horizontal = Control.GROW_DIRECTION_BOTH
	center.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(center)

	var head := HudTheme.hbox(14)
	center.add_child(head)
	var fb := PanelContainer.new()
	fb.add_theme_stylebox_override("panel", HudTheme.flat(
		Color(1.0, 0.37, 0.37, 0.14), HudTheme.RED, 1, Vector4(10, 4, 10, 4)))
	fb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fr := HudTheme.hbox(7)
	fb.add_child(fr)
	var fdot := ColorRect.new()
	fdot.color = HudTheme.RED
	fdot.custom_minimum_size = Vector2(HudTheme.dp(6), HudTheme.dp(6))
	fdot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_blink(fdot, 0.8)
	fr.add_child(fdot)
	fr.add_child(HudTheme.label("FATAL", HudTheme.mono(11, 700, 0.20), 11,
		HudTheme.RED_BRIGHT))
	head.add_child(fb)
	head.add_child(HudTheme.label("BUNDLE LOAD FAILED · 孪生体未启动",
		HudTheme.mono(11, 400, 0.20), 11, Color("#8a5c5c")))

	center.add_child(HudTheme.label("数据包加载失败", HudTheme.sans(40, 300, 0.06),
		40, Color("#ffdada")))

	var errbox := PanelContainer.new()
	errbox.add_theme_stylebox_override("panel", HudTheme.edge(
		Color(1.0, 0.37, 0.37, 0.06), HudTheme.RED, 2, 0, 0, 0, Vector4(16, 14, 16, 14)))
	errbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	errbox.add_child(HudTheme.para(message, HudTheme.mono(14, 400), 14,
		HudTheme.RED_BRIGHT, 800))
	center.add_child(errbox)

	var steps := HudTheme.vbox(10)
	center.add_child(steps)
	steps.add_child(HudTheme.label("先运行 RUN FIRST", HudTheme.mono(10, 400, 0.20),
		10, Color("#6f5050")))
	var list := HudTheme.vbox(1)
	var list_wrap := PanelContainer.new()
	list_wrap.add_theme_stylebox_override("panel",
		HudTheme.flat(Color(1.0, 0.37, 0.37, 0.16)))
	list_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	list_wrap.add_child(list)
	steps.add_child(list_wrap)
	var cmds := [
		"go run ./cmd/ingest",
		"blender --background --factory-startup --python tools/model/assign.py -- --mode export",
		"go run ./cmd/export",
	]
	var i := 0
	for c in cmds:
		i += 1
		var rowp := PanelContainer.new()
		rowp.add_theme_stylebox_override("panel", HudTheme.flat(
			HudTheme.RED_BG, Color(0, 0, 0, 0), 0, Vector4(14, 11, 14, 11)))
		rowp.mouse_filter = Control.MOUSE_FILTER_IGNORE
		list.add_child(rowp)
		var r := HudTheme.hbox(14)
		rowp.add_child(r)
		r.add_child(HudTheme.label("%02d" % i, HudTheme.mono(13, 400), 13,
			Color("#6f5050")))
		r.add_child(HudTheme.label(String(c), HudTheme.mono(13, 400), 13,
			Color("#d6c8c8")))
	_build_overlay(HudTheme.RED, 0.8, 0.0, 0.0)
