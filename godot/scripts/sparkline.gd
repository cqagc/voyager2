## 极简折线图。用来把 49 年的变化画成一条可读的曲线，并标出当前时刻。
##
## 样式对齐设计稿：左下两条 1px 描边当坐标轴，曲线下方带一层同色低透明填充，
## 当前时刻是一条 3-3 虚线加一个实心点，说明文字压在左上角。
class_name Sparkline
extends Control

var samples: PackedFloat32Array = PackedFloat32Array()
var marker_ratio := 0.0
var line_color := HudTheme.PH
var fill_color := Color(0.49, 1.0, 0.83, 0.12)
var marker_color := HudTheme.BRIGHT
var dash_color := Color(0.49, 1.0, 0.83, 0.45)
var border_color := HudTheme.LINE
var caption := ""
var caption_color := HudTheme.DIM3
var value_text := ""            # 保留字段，稿子里不显示

const PAD_TOP := 4.0
const PAD_BOTTOM := 7.0

var _font: Font = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = HudTheme.mono(9, 400, 0.14)


func set_series(values: PackedFloat32Array, at_ratio: float) -> void:
	samples = values
	marker_ratio = clampf(at_ratio, 0.0, 1.0)
	queue_redraw()


func _draw() -> void:
	var w := size.x
	var h := size.y
	var t := HudTheme.dp(1)

	# 坐标轴：只有左边和下边，和稿子一样
	draw_rect(Rect2(0.0, 0.0, t, h), border_color, true)
	draw_rect(Rect2(0.0, h - t, w, t), border_color, true)

	if samples.size() >= 2:
		var lo := samples[0]
		var hi := samples[0]
		for v in samples:
			lo = minf(lo, v)
			hi = maxf(hi, v)
		var span := maxf(hi - lo, 1e-9)
		var pad_top := HudTheme.dp(PAD_TOP)
		var usable := maxf(h - pad_top - HudTheme.dp(PAD_BOTTOM), 1.0)

		var pts := PackedVector2Array()
		for i in samples.size():
			var x := w * float(i) / float(samples.size() - 1)
			var y := pad_top + (1.0 - (samples[i] - lo) / span) * usable
			pts.append(Vector2(x, y))

		var poly := PackedVector2Array(pts)
		poly.append(Vector2(w, h))
		poly.append(Vector2(0, h))
		draw_colored_polygon(poly, fill_color)
		draw_polyline(pts, line_color, 1.4 * HudTheme.scale, true)

		# 当前时刻：3-3 虚线 + 实心点
		var mx := roundf(w * marker_ratio)
		var dash := HudTheme.dp(3)
		var yy := 0.0
		while yy < h:
			draw_rect(Rect2(mx, yy, t, minf(dash, h - yy)), dash_color, true)
			yy += dash * 2.0
		var idx := clampi(int(round(marker_ratio * float(samples.size() - 1))),
			0, samples.size() - 1)
		draw_circle(pts[idx], 3.2 * HudTheme.scale, marker_color)

	if caption != "":
		if _font == null:
			_font = HudTheme.mono(9, 400, 0.14)
		HudTheme.draw_text(self, _font, Vector2(HudTheme.dp(8), HudTheme.dp(6)),
			caption, 9, caption_color)
