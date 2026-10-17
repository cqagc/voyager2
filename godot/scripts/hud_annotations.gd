## 贴在 3D 画面上的屏幕空间标注：探测器十字准星、地球菱标、两者之间的下行链路线。
##
## 位置来自相机的 unproject_position（真 3D 位置投影下来），所以镜头一动标注
## 就跟着动 —— 稿子里那几个写死的 left/top 在这里换成真实投影。
class_name HudAnnotations
extends Control

var probe_pos := Vector2.ZERO
var probe_on := false
var earth_pos := Vector2.ZERO
var earth_on := false

var probe_name := "VGR-2"
var probe_line2 := ""
var probe_line3 := ""
var earth_label := "EARTH 399"
var link_label := ""

var _t := 0.0
var _f_name: Font
var _f_l2: Font
var _f_l3: Font
var _f_small: Font
var _f_link: Font


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_f_name = HudTheme.mono(15, 400, 0.12)
	_f_l2 = HudTheme.mono(11, 400, 0.10)
	_f_l3 = HudTheme.mono(10, 400, 0.10)
	_f_small = HudTheme.mono(10, 400, 0.12)
	_f_link = HudTheme.mono(11, 400, 0.14)


func _process(delta: float) -> void:
	if not visible:
		return
	_t += delta
	queue_redraw()


func _in_view(p: Vector2) -> bool:
	var m := _s(200)
	return p.x > -m and p.y > -m and p.x < size.x + m and p.y < size.y + m


## 标注文字压在 3D 画面上，背景可能是太阳这种亮区，所以每行字底下垫一小块
## 半透明暗底（外加 HudTheme.draw_text 自带的描边）。
func _plate(font: Font, at: Vector2, txt: String, sz: int, right := false) -> void:
	if txt == "":
		return
	var px := HudTheme.fs(sz)
	var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
	var h := font.get_height(px)
	var mx := _s(4)
	var my := _s(2)
	var x := at.x - w if right else at.x
	draw_rect(Rect2(x - mx, at.y - my, w + mx * 2.0, h + my * 2.0),
		Color(0.008, 0.031, 0.035, 0.55), true)


func _right_text(font: Font, right_x: float, top: float, txt: String,
		sz: int, col: Color) -> void:
	_plate(font, Vector2(right_x, top), txt, sz, true)
	HudTheme.draw_text(self, font, Vector2(right_x, top), txt, sz, col, true)


## 设计稿长度 -> 当前界面倍率下的长度。
func _s(v: float) -> float:
	return HudTheme.dp(v)


func _draw() -> void:
	# ---- 下行链路线 ----
	if probe_on and earth_on and _in_view(probe_pos) and _in_view(earth_pos):
		var a := earth_pos
		var b := probe_pos
		var segs := 64
		var lw := _s(1)
		for i in segs:
			var t0 := float(i) / float(segs)
			var t1 := float(i + 1) / float(segs)
			var alpha := lerpf(0.55, 0.12, t0)
			draw_line(a.lerp(b, t0), a.lerp(b, t1), Color(HudTheme.PH, alpha), lw)
		# 2.6s 一趟的扫掠亮段
		var total := a.distance_to(b)
		if total > _s(80):
			var seg := _s(5)
			var head := fmod(_t / 2.6, 1.0) * (total + _s(60)) - _s(60)
			var dir := (b - a) / total
			for k in 12:
				var d0 := head + float(k) * seg
				if d0 < 0.0 or d0 > total:
					continue
				var f := 1.0 - absf(float(k) - 6.0) / 6.0
				draw_line(a + dir * d0, a + dir * minf(d0 + seg, total),
					Color(HudTheme.BRIGHT, 0.85 * f), lw)
		if link_label != "":
			var mid := a.lerp(b, 0.42)
			var n := Vector2(-(b - a).y, (b - a).x).normalized()
			var lp := mid + n * -_s(18)
			_plate(_f_link, lp, link_label, 11)
			HudTheme.draw_text(self, _f_link, lp, link_label, 11,
				Color(HudTheme.PH, 0.95))

	# ---- 地球菱标 ----
	if earth_on and _in_view(earth_pos):
		var e := earth_pos
		var r := _s(5.6)
		var d := PackedVector2Array([
			e + Vector2(0, -r), e + Vector2(r, 0),
			e + Vector2(0, r), e + Vector2(-r, 0), e + Vector2(0, -r)])
		draw_polyline(d, Color(HudTheme.PH, 0.8), _s(1))
		var ep := Vector2(e.x + _s(14), e.y - _s(8))
		_plate(_f_small, ep, earth_label, 10)
		HudTheme.draw_text(self, _f_small, ep, earth_label, 10, HudTheme.TEXT3)

	# ---- 探测器十字准星 ----
	if not probe_on or not _in_view(probe_pos):
		return
	var p := probe_pos

	# ringOut：3.2s 一轮，半径 45 → 198，透明度 .8 → 0
	var rt := fmod(_t / 3.2, 1.0)
	draw_arc(p, lerpf(_s(45), _s(198), rt), 0.0, TAU, 72,
		Color(0.49, 1.0, 0.83, 0.22 * (1.0 - rt)), _s(1), true)

	# spinSlow：24s 转一圈的 68×68 方框
	var ang := fmod(_t / 24.0, 1.0) * TAU
	var quad := PackedVector2Array()
	for i in 5:
		var a2 := ang + TAU * float(i % 4) / 4.0 + PI / 4.0
		quad.append(p + Vector2(cos(a2), sin(a2)) * _s(48.08))
	draw_polyline(quad, Color(HudTheme.PH, 0.5), _s(1), true)

	# 十字刻线：内侧留 24px 空档
	var arm := _s(40)
	var gap := _s(24)
	var t := _s(1)
	draw_rect(Rect2(p.x - gap - arm, p.y, arm, t), HudTheme.PH, true)
	draw_rect(Rect2(p.x + gap, p.y, arm, t), HudTheme.PH, true)
	draw_rect(Rect2(p.x, p.y - gap - arm, t, arm), HudTheme.PH, true)
	draw_rect(Rect2(p.x, p.y + gap, t, arm), HudTheme.PH, true)

	# 中心点 + 光晕
	var g := _s(8)
	var c := _s(3)
	draw_rect(Rect2(p.x - g, p.y - g, g * 2.0, g * 2.0), Color(HudTheme.PH, 0.18), true)
	draw_rect(Rect2(p.x - c, p.y - c, c * 2.0, c * 2.0), HudTheme.BRIGHT, true)

	# 右对齐的三行标签，落在准星左侧
	var right_x := p.x - _s(76)
	var top := p.y - _s(30)
	_right_text(_f_name, right_x, top, probe_name, 15, HudTheme.BRIGHT)
	_right_text(_f_l2, right_x, top + _s(21), probe_line2, 11, HudTheme.PH)
	_right_text(_f_l3, right_x, top + _s(38), probe_line3, 10, HudTheme.MUTED)
