## 赛博朋克 HUD 的配色与字体中枢。
##
## 所有数值直接对齐 Claude Design 的 `赛博朋克 HUD.dc.html`：那份稿子里
## 每个颜色、字号、字间距都是显式写死的行内样式，这里就照抄成常量，
## 避免各处再各自"估一个差不多的绿"。
##
## 字体：稿子用 JetBrains Mono（等宽数值）+ Noto Sans SC（中文正文）。
## 两个都随仓库带进来了，等宽字体挂上中文回退，这样 "20.01 小时" 这种
## 中英混排不会掉字。
class_name HudTheme
extends RefCounted

# ---- 磷光绿主色 ----
const PH := Color("#7dffd4")           # 主磷光色
const BRIGHT := Color("#eafff8")       # 高亮白
const TEXT := Color("#d6e6e2")         # 正文
const TEXT2 := Color("#a8c0bb")        # 次正文
const TEXT3 := Color("#a3bdb7")        # 三级
const DIM := Color("#9ab0ac")
const DIM2 := Color("#8fa9a3")
const DIM3 := Color("#82a29b")
const MUTED := Color("#748d87")
const MUTED2 := Color("#66807a")

# ---- 琥珀色（推演数据／RTG） ----
const AMBER := Color("#ffb84d")
const AMBER_BRIGHT := Color("#ffcf8f")
const AMBER_TEXT := Color("#d8bb84")
const AMBER_DIM := Color("#c3aa77")
const AMBER_DIM2 := Color("#ad9463")

# ---- 红色（无遥测／不可见／致命错误） ----
const RED := Color("#ff5f5f")
const RED_BRIGHT := Color("#ff9a9a")
const RED_TEXT := Color("#c79a9a")
const RED_DIM := Color("#b48282")
const RED_DIM2 := Color("#a06a6a")
const RED_BORDER := Color("#4a3030")
const RED_BG := Color("#0a0304")

# ---- 金色（金唱片） ----
const GOLD := Color("#c9a227")
const GOLD_BRIGHT := Color("#e8c968")
const GOLD_PALE := Color("#f0dfa8")

# ---- 底色与描边 ----
const SCREEN_BG := Color("#02090b")
# 稿子是 rgba(2,20,17,.72)。真机顶栏可能压在探测器模型这种亮区上，抬到 .88
# 才压得住 —— 反正它下面本来就是"导轨"，不是要透出画面的地方。
const RAIL_BG := Color(0.008, 0.078, 0.067, 0.88)
const HAIRLINE := Color(0.49, 1.0, 0.83, 0.16)      # rgba(125,255,212,.16)
const LINE := Color(0.49, 1.0, 0.83, 0.28)          # rgba(125,255,212,.28)
const LINE_SOFT := Color(0.49, 1.0, 0.83, 0.14)     # rgba(125,255,212,.14)
const PH_FILL := Color(0.31, 1.0, 0.82, 0.10)       # rgba(80,255,210,.10)
const PH_FILL_SOFT := Color(0.31, 1.0, 0.82, 0.06)
const PH_FILL_STRONG := Color(0.31, 1.0, 0.82, 0.16)

## 字重补偿与描边。
##
## 设计稿是在纯黑底上排的，300 字重 + #4d635f 这类暗灰在纸面上很干净；但真机
## 背景是太阳、星云、行星这种亮区，同一套值直接看不见。两个应对：
##   · 字重整体上浮一档（300→400、400→500），笔画变实；
##   · 所有文字加一圈深色描边，任何背景上都能读出字形。
## 描边比"给每块文字铺不透明底"更贴设计稿 —— HUD 仍然是浮在画面上的。
const WEIGHT_BOOST := 100
const OUTLINE_PX := 3
const OUTLINE_COLOR := Color(0.004, 0.024, 0.027, 0.85)

const FONT_DIR := "res://assets/fonts/"
const SANS_PATH := FONT_DIR + "NotoSansSC.ttf"
const MONO_PATHS := {
	300: FONT_DIR + "JetBrainsMono-Light.ttf",
	400: FONT_DIR + "JetBrainsMono-Regular.ttf",
	500: FONT_DIR + "JetBrainsMono-Medium.ttf",
	700: FONT_DIR + "JetBrainsMono-Bold.ttf",
}

## OpenType "wght" 轴的 tag。用字面量而不是 TextServer.name_to_tag()，
## 因为后者是接口实例方法，静态上下文里拿不到。
const TAG_WGHT := 0x77676874

## 界面倍率。1.0 = 设计稿原尺寸（1600×900 基准）。
##
## 关键点：这个倍率是**乘进字号和布局像素**的，不是给画布加 transform。
## Godot 的字体按字号栅格化进位图图集，缩放画布只会把字形贴图放大糊掉；
## 而按 1.5 倍字号重新栅格化出来的字是原生锐利的。代价是改倍率必须重建
## 整层 HUD（字体资源和布局参数都要重算），所以这不是能每帧调的东西。
static var scale := 1.0

## 布局像素：设计稿的 px -> 当前倍率下的 px。取整避免半像素模糊。
static func dp(v: float) -> float:
	return round(v * scale)


## 字号。至少 1，否则 1.5 倍以下的极小字号会归零。
static func fs(v: int) -> int:
	return maxi(1, int(round(float(v) * scale)))


## 换倍率。字体缓存必须清掉 —— 缓存键是按设计字号存的，倍率变了同一个键
## 对应的实际字号就变了。
static func set_scale(v: float) -> void:
	if is_equal_approx(scale, v):
		return
	scale = v
	_cache.clear()


static var _cache := {}
static var _sans_base: FontFile = null
static var _mono_base := {}


static func _sans_file() -> FontFile:
	if _sans_base == null:
		_sans_base = load(SANS_PATH)
	return _sans_base


static func _mono_file(weight: int) -> FontFile:
	var w := _nearest_mono_weight(weight)
	if not _mono_base.has(w):
		_mono_base[w] = load(String(MONO_PATHS[w]))
	return _mono_base[w]


## 上浮一档字重。700 已经够粗，不再加。
static func _boosted(weight: int) -> int:
	if weight >= 700:
		return weight
	return clampi(weight + WEIGHT_BOOST, 100, 900)


static func _nearest_mono_weight(weight: int) -> int:
	# JetBrains Mono 这里只带了四档，取最近的一档。
	var best := 400
	var best_d := 9999
	for w in MONO_PATHS.keys():
		var d: int = absi(int(w) - weight)
		if d < best_d:
			best_d = d
			best = int(w)
	return best


## 等宽字体（数值、代号、英文标签）。ls_em 是 CSS letter-spacing 的 em 值。
static func mono(size: int, weight: int = 400, ls_em: float = 0.0) -> Font:
	weight = _boosted(weight)
	var key := "m%d_%d_%.3f" % [size, weight, ls_em]
	if _cache.has(key):
		return _cache[key]
	var fv := FontVariation.new()
	fv.base_font = _mono_file(weight)
	# 等宽字没有中文，挂上 Noto Sans SC 回退，"20.01 小时" 才不会掉字。
	fv.fallbacks = [_sans_file()]
	fv.spacing_glyph = int(round(float(fs(size)) * ls_em))
	_cache[key] = fv
	return fv


## 中文正文字体（Noto Sans SC 可变字重）。
static func sans(size: int, weight: int = 400, ls_em: float = 0.0) -> Font:
	weight = _boosted(weight)
	var key := "s%d_%d_%.3f" % [size, weight, ls_em]
	if _cache.has(key):
		return _cache[key]
	var fv := FontVariation.new()
	fv.base_font = _sans_file()
	fv.variation_opentype = {TAG_WGHT: weight}
	fv.spacing_glyph = int(round(float(fs(size)) * ls_em))
	_cache[key] = fv
	return fv


## 一行文字。Godot 的 Label 没有 letter-spacing，靠 FontVariation 带进来。
static func label(text: String, font: Font, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", fs(size))
	l.add_theme_color_override("font_color", color)
	l.add_theme_constant_override("outline_size", int(dp(OUTLINE_PX)))
	l.add_theme_color_override("font_outline_color", OUTLINE_COLOR)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## 多行文字（自动换行的说明段）。
static func para(text: String, font: Font, size: int, color: Color,
		width: int, line_spacing: float = 0.0) -> Label:
	var l := label(text, font, size, color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(dp(width), 0)
	if line_spacing != 0.0:
		l.add_theme_constant_override("line_spacing", int(dp(line_spacing)))
	return l


## 自绘控件里画一行字。pos 是 CSS 意义上的左上角（内部换算成基线），
## 字号自动过倍率 —— 自绘控件很容易漏乘，集中到这里。
static func draw_text(ci: CanvasItem, font: Font, pos: Vector2, txt: String,
		size: int, color: Color, align_right := false) -> void:
	var px := fs(size)
	var w := 0.0
	if align_right:
		w = font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
	var at := Vector2(pos.x - w, pos.y + font.get_ascent(px))
	ci.draw_string_outline(font, at, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, px,
		int(dp(OUTLINE_PX)), OUTLINE_COLOR)
	ci.draw_string(font, at, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, px, color)


## 纯色/描边面板样式。pad 顺序：左 上 右 下。
static func flat(bg: Color, border := Color(0, 0, 0, 0), bw: int = 0,
		pad := Vector4(0, 0, 0, 0)) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	if bw > 0:
		sb.border_color = border
		sb.set_border_width_all(maxi(1, int(dp(bw))))
	sb.content_margin_left = dp(pad.x)
	sb.content_margin_top = dp(pad.y)
	sb.content_margin_right = dp(pad.z)
	sb.content_margin_bottom = dp(pad.w)
	sb.corner_radius_top_left = 0
	sb.corner_radius_top_right = 0
	sb.corner_radius_bottom_left = 0
	sb.corner_radius_bottom_right = 0
	sb.anti_aliasing = false
	return sb


## 只有单边描边的样式（稿子里大量用 border-left:2px 这种）。
static func edge(bg: Color, border: Color, left: int = 0, top: int = 0,
		right: int = 0, bottom: int = 0, pad := Vector4(0, 0, 0, 0)) -> StyleBoxFlat:
	var sb := flat(bg, border, 0, pad)
	sb.border_color = border
	sb.border_width_left = 0 if left == 0 else maxi(1, int(dp(left)))
	sb.border_width_top = 0 if top == 0 else maxi(1, int(dp(top)))
	sb.border_width_right = 0 if right == 0 else maxi(1, int(dp(right)))
	sb.border_width_bottom = 0 if bottom == 0 else maxi(1, int(dp(bottom)))
	return sb


## 竖排容器（对应 flex column + gap）。
static func vbox(gap: int) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", int(dp(gap)))
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return v


## 横排容器（对应 flex row + gap）。
static func hbox(gap: int, align := BoxContainer.ALIGNMENT_BEGIN) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", int(dp(gap)))
	h.alignment = align
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return h


## 弹性占位（flex:1）。
static func spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


## 锚点 + 偏移一次写全。
##
## 不用 set_anchors_preset()：那个函数在节点已经进树、且当前 size 为 0 时
## 会"保持现状"把 offset_right 反算成 -父宽，结果控件永远是 0 宽。
## 踩过一次就不碰了 —— 这里全部显式写死。
static func anchor(c: Control, al: float, at: float, ar: float, ab: float,
		ol := 0.0, ot := 0.0, orr := 0.0, ob := 0.0) -> Control:
	c.anchor_left = al
	c.anchor_top = at
	c.anchor_right = ar
	c.anchor_bottom = ab
	c.offset_left = ol
	c.offset_top = ot
	c.offset_right = orr
	c.offset_bottom = ob
	return c


## 铺满父级。
static func fill(c: Control, ol := 0.0, ot := 0.0, orr := 0.0, ob := 0.0) -> Control:
	return anchor(c, 0, 0, 1, 1, ol, ot, orr, ob)


## 徽章（实测 / 推演 / 无遥测 这类小方框标签）。
static func badge(text: String, fg: Color, border: Color, bg: Color,
		size: int = 9, ls_em: float = 0.16, weight: int = 700,
		pad := Vector4(7, 2, 7, 2)) -> PanelContainer:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override("panel", flat(bg, border, 1, pad))
	pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pc.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	pc.add_child(label(text, mono(size, weight, ls_em), size, fg))
	return pc


## 把一个控件塞进带内边距的壳里（用来做 baseline 对齐的 padding-bottom）。
static func pad(child: Control, left: int = 0, top: int = 0,
		right: int = 0, bottom: int = 0) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", int(dp(left)))
	m.add_theme_constant_override("margin_top", int(dp(top)))
	m.add_theme_constant_override("margin_right", int(dp(right)))
	m.add_theme_constant_override("margin_bottom", int(dp(bottom)))
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_child(child)
	return m
