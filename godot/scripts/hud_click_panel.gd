## 可点击的方框（稿子里的按钮、分段控件、下拉外壳都是这个形状）。
##
## 用 PanelContainer 而不是 Button，因为稿子里的按钮内部是混排的：
## "▶ 播放" 是 13px 中文，右边 "60 天/秒" 是 10px 等宽灰字，Button 的
## 单一 text 塞不进去。
class_name HudClickPanel
extends PanelContainer

signal pressed

var normal_style: StyleBox = null
var hover_style: StyleBox = null
var enabled := true


func setup(normal: StyleBox, hover: StyleBox = null) -> void:
	normal_style = normal
	hover_style = hover
	add_theme_stylebox_override("panel", normal_style)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_ENTER and hover_style != null and enabled:
		add_theme_stylebox_override("panel", hover_style)
	elif what == NOTIFICATION_MOUSE_EXIT and normal_style != null:
		add_theme_stylebox_override("panel", normal_style)


func _gui_input(event: InputEvent) -> void:
	if not enabled:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			pressed.emit()
			accept_event()
