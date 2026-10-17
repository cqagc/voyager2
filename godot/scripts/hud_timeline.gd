## 底部时间轴。全自绘，对齐设计稿的刻度、飞掠窗口括号、事件标记和 NOW 游标。
##
## 稿子里的百分比（木 2.29% / 海 14.59% / 日球层顶 50.03% / NOW 59.51%）不是
## 拍脑袋的，就是 (jd - jd_min) / (jd_max - jd_min)。所以这里全部按真实 JD 算，
## 换个时间跨度也自洽。
class_name HudTimeline
extends Control

signal value_changed(v: float)

const TRACK_Y := 66.0
const FLYBY_KEYS := ["jupiter", "saturn", "uranus", "neptune"]
const FLYBY_CHAR := {"jupiter": "木", "saturn": "土", "uranus": "天", "neptune": "海"}

var min_value := 0.0
var max_value := 1.0
var step := 0.01
var value := 0.0:
	set(v):
		value = clampf(v, min_value, max_value)
		queue_redraw()

## [{jd, date, label, focus}]，直接来自星历元数据。
var events: Array = []

var _f_tick: Font
var _f_date: Font
var _f_note: Font
var _f_now: Font
var _f_cn: Font
var _dragging := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_f_tick = HudTheme.mono(9, 400, 0.0)
	_f_date = HudTheme.mono(10, 400, 0.0)
	_f_note = HudTheme.mono(9, 400, 0.14)
	_f_now = HudTheme.mono(11, 400, 0.10)
	_f_cn = HudTheme.sans(10, 400, 0.0)


func _ratio_of(jd: float) -> float:
	return clampf((jd - min_value) / maxf(1e-9, max_value - min_value), 0.0, 1.0)


func _x_of(jd: float) -> float:
	return roundf(_ratio_of(jd) * size.x)


func _event_jd(focus_or_date: String) -> float:
	for e in events:
		if String(e.get("focus", "")) == focus_or_date or String(e.get("date", "")) == focus_or_date:
			return float(e["jd"])
	return NAN


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		# 只有轨道那一条带子接受拖动，别把整条底栏都变成拖动区。
		if mb.pressed and mb.position.y > _y(40) and mb.position.y < _y(104):
			_dragging = true
			_seek_to(mb.position.x)
			accept_event()
		elif not mb.pressed and _dragging:
			_dragging = false
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		_seek_to((event as InputEventMouseMotion).position.x)
		accept_event()


func _seek_to(x: float) -> void:
	var r := clampf(x / maxf(1.0, size.x), 0.0, 1.0)
	var v := lerpf(min_value, max_value, r)
	value = v
	value_changed.emit(v)


## 设计稿的 y（或任意长度）-> 当前倍率下的实际值。
## _draw 里所有写死的数都是设计稿的，一律过这个函数。
func _y(v: float) -> float:
	return HudTheme.dp(v)


func _draw() -> void:
	var w := size.x
	var track_y := _y(TRACK_Y)

	# ---- 轨道与已走过的部分 ----
	draw_rect(Rect2(0, track_y, w, _y(2)), HudTheme.LINE_SOFT, true)
	var px := _x_of(value)
	if px > 0.0:
		# 稿子的 box-shadow:0 0 12px 发光，用两层低透明矩形近似
		draw_rect(Rect2(0, track_y - _y(3), px, _y(8)), Color(HudTheme.PH, 0.10), true)
		draw_rect(Rect2(0, track_y - _y(1), px, _y(4)), Color(HudTheme.PH, 0.18), true)
		draw_rect(Rect2(0, track_y, px, _y(2)), HudTheme.PH, true)

	# ---- 十年刻度 ----
	var tick_col := Color(0.49, 1.0, 0.83, 0.3)
	var y0 := JDTime.year_of(min_value)
	var y1 := JDTime.year_of(max_value)
	var year := int(ceil(float(y0) / 10.0) * 10.0)
	while year <= y1:
		var jd := JDTime.jd_of_year(year)
		if jd > min_value and jd < max_value - 1.0:
			var x := _x_of(jd)
			draw_rect(Rect2(x, track_y + _y(2), _y(1), _y(8)), tick_col, true)
			HudTheme.draw_text(self, _f_tick, Vector2(x, track_y + _y(12)),
				str(year), 9, HudTheme.MUTED2)
		year += 10

	# 右端：星历覆盖的终点
	draw_rect(Rect2(w - _y(1), track_y - _y(6), _y(1), _y(14)), tick_col, true)
	var end_txt := str(JDTime.year_of(max_value))
	HudTheme.draw_text(self, _f_note, Vector2(w, track_y + _y(12)), end_txt, 9,
		HudTheme.MUTED, true)

	# ---- 飞掠窗口括号 ----
	var jd_first := _event_jd("jupiter")
	var jd_last := _event_jd("neptune")
	if not is_nan(jd_first) and not is_nan(jd_last):
		var xa := _x_of(jd_first)
		var xb := _x_of(jd_last)
		var bc := Color(1.0, 0.72, 0.30, 0.4)
		draw_rect(Rect2(xa, _y(22), xb - xa, _y(1)), bc, true)
		draw_rect(Rect2(xa, _y(22), _y(1), _y(14)), bc, true)
		draw_rect(Rect2(xb - _y(1), _y(22), _y(1), _y(14)), bc, true)
		HudTheme.draw_text(self, _f_note, Vector2(xb + _y(24), _y(22)),
			"飞掠窗口 · 30 分钟原生密采（巡航段 1 天）", 9, HudTheme.AMBER_DIM)

	# ---- 四次飞掠 ----
	for k in FLYBY_KEYS:
		var jd_f := _event_jd(k)
		if is_nan(jd_f):
			continue
		var x := _x_of(jd_f)
		HudTheme.draw_text(self, _f_cn, Vector2(x, _y(40)), String(FLYBY_CHAR[k]),
			10, HudTheme.AMBER_TEXT)
		draw_rect(Rect2(x, _y(54), _y(1), _y(12)), Color(1.0, 0.72, 0.30, 0.55), true)

	# ---- 发射 / 穿越日球层顶 ----
	for e in events:
		var focus := String(e.get("focus", ""))
		if focus != "":
			continue    # 飞掠已单独画
		var jd_e := float(e["jd"])
		var x := _x_of(jd_e)
		var caption := "发射" if jd_e <= min_value + 1.0 else "穿越日球层顶"
		draw_rect(Rect2(x, track_y, _y(1), _y(9)), HudTheme.PH, true)
		HudTheme.draw_text(self, _f_date, Vector2(x + _y(3), track_y + _y(9)),
			String(e["date"]), 10, HudTheme.TEXT3)
		HudTheme.draw_text(self, _f_cn, Vector2(x + _y(3), track_y + _y(23)),
			caption, 10, HudTheme.DIM3)

	# ---- NOW 游标 ----
	draw_rect(Rect2(px - _y(1), _y(30), _y(3), _y(36)), Color(HudTheme.PH, 0.25), true)
	draw_rect(Rect2(px, _y(30), _y(1), _y(36)), HudTheme.BRIGHT, true)
	var r := _y(7)
	var cy := _y(67)
	var dia := PackedVector2Array([
		Vector2(px, cy - r), Vector2(px + r, cy), Vector2(px, cy + r), Vector2(px - r, cy)])
	draw_colored_polygon(dia, Color(0.008, 0.035, 0.043, 0.9))
	var outline := PackedVector2Array(dia)
	outline.append(dia[0])
	draw_polyline(outline, HudTheme.BRIGHT, HudTheme.dp(1), false)

	var now_txt := "NOW · " + JDTime.format_date_short(value)
	var tw := _f_now.get_string_size(now_txt, HORIZONTAL_ALIGNMENT_LEFT, -1,
		HudTheme.fs(11)).x
	var bx := clampf(px - _y(52), 0.0, w - tw - _y(16))
	var box := Rect2(bx, _y(6), tw + _y(16), _y(22))
	draw_rect(box, Color(0.008, 0.078, 0.067, 0.92), true)
	draw_rect(box, HudTheme.PH, false, HudTheme.dp(1))
	HudTheme.draw_text(self, _f_now, Vector2(bx + _y(8), _y(11)), now_txt, 11,
		HudTheme.BRIGHT)
