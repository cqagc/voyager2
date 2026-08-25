## 极简折线图。用来把 49 年的变化画成一条可读的曲线，并标出当前时刻。
class_name Sparkline
extends Control

var samples: PackedFloat32Array = PackedFloat32Array()
var marker_ratio := 0.0
var line_color := Color(0.55, 0.78, 1.0)
var fill_color := Color(0.30, 0.52, 0.85, 0.22)
var marker_color := Color(1.0, 0.55, 0.25)
var caption := ""
var value_text := ""

func set_series(values: PackedFloat32Array, at_ratio: float) -> void:
	samples = values
	marker_ratio = clampf(at_ratio, 0.0, 1.0)
	queue_redraw()

func _draw() -> void:
	var w := size.x
	var h := size.y
	draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.03), true)
	if samples.size() < 2:
		return

	var lo := samples[0]
	var hi := samples[0]
	for v in samples:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	var span := maxf(hi - lo, 1e-9)

	var pts := PackedVector2Array()
	for i in samples.size():
		var x := w * float(i) / float(samples.size() - 1)
		var y := h - (samples[i] - lo) / span * (h - 2.0) - 1.0
		pts.append(Vector2(x, y))

	# 填充
	var poly := PackedVector2Array(pts)
	poly.append(Vector2(w, h))
	poly.append(Vector2(0, h))
	draw_colored_polygon(poly, fill_color)
	draw_polyline(pts, line_color, 1.6, true)

	# 当前时刻标记
	var mx := w * marker_ratio
	draw_line(Vector2(mx, 0), Vector2(mx, h), Color(1, 1, 1, 0.18), 1.0)
	var idx := clampi(int(round(marker_ratio * float(samples.size() - 1))), 0, samples.size() - 1)
	draw_circle(pts[idx], 3.0, marker_color)

	if caption != "":
		draw_string(get_theme_default_font(), Vector2(5, 13),
			caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.62, 0.70, 0.82))
	if value_text != "":
		draw_string(get_theme_default_font(), Vector2(5, h - 5),
			value_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.88, 0.92, 1.0))
