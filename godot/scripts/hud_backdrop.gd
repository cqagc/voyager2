## 场景层上方的 80px 测量网格 + 交叉点。
##
## 稿子里是两层 background-image：80×80 的细线网格（alpha .045）和偏移
## 40px 的点阵（alpha .16）。3D 场景本身不动，这层只是压在上面的 HUD 网格。
class_name HudBackdrop
extends Control

const CELL := 80.0

var line_color := Color(0.49, 1.0, 0.83, 0.045)
var dot_color := Color(0.49, 1.0, 0.83, 0.16)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	# 网格跟着界面倍率走：稿子里它是 80px，1.5 倍界面下就该是 120px，
	# 否则界面放大而网格不变，密度关系就跟设计稿不一致了。
	var cell := HudTheme.dp(CELL)
	var t := HudTheme.dp(1)
	var x := 0.0
	while x < size.x:
		draw_rect(Rect2(x, 0, t, size.y), line_color, true)
		x += cell
	var y := 0.0
	while y < size.y:
		draw_rect(Rect2(0, y, size.x, t), line_color, true)
		y += cell

	var r := 1.2 * HudTheme.scale
	var dy := cell * 0.5
	while dy < size.y:
		var dx := cell * 0.5
		while dx < size.x:
			draw_circle(Vector2(dx, dy), r, dot_color)
			dx += cell
		dy += cell
