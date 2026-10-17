// CRT 覆盖层：扫描线 + 噪点 + 暗角 + 自上而下的扫掠光带。
//
// 对应设计稿 `赛博朋克 HUD.dc.html` 里那几层 pointer-events:none 的叠加 div：
//   · repeating-linear-gradient 扫描线（1px 亮 / 2px 暗），scanDrift 1.4s steps(6) 位移 6px
//   · grain 噪点，opacity 在 .045 ↔ .085 之间跳，0.9s steps(3)
//   · box-shadow: inset 0 0 200px rgba(0,0,0,.75) 暗角
//   · 顶部 70px 的磷光光带，sweepY 6.5s linear 扫到底
//
// 纯覆盖层，不参与 3D 渲染，星球和天穹一点没碰。
shader_type canvas_item;
render_mode unshaded;

uniform vec2 u_size = vec2(1600.0, 900.0);   // 视口尺寸，由 hud.gd 写入
// 一个画布单位对应的真实渲染像素数，用来把 FRAGCOORD 换回布局坐标空间。
uniform float u_px_per_unit = 1.0;
// 界面倍率。HUD 的字号和布局都乘了这个倍率，CRT 效果也得跟着放大，
// 否则 1.5 倍界面上扫描线还是 3px，看起来比设计稿密一倍。
uniform float u_scale = 1.0;
uniform vec3 u_scan_color : source_color = vec3(0.49, 1.0, 0.83);
uniform float u_scan_alpha = 0.055;
uniform float u_scan_period = 3.0;      // 1px 亮 + 2px 暗
uniform float u_grain = 1.0;
uniform float u_vignette = 0.75;
uniform float u_vignette_px = 200.0;
uniform float u_sweep = 1.0;
uniform float u_sweep_px = 70.0;
uniform bool u_scanlines_on = true;

float hash21(vec2 p) {
	p = fract(p * vec2(233.34, 851.73));
	p += dot(p, p + 23.45);
	return fract(p.x * p.y);
}

void fragment() {
	// 用 FRAGCOORD 而不是 UV：ColorRect 走的是 draw_rect 图元，UV 不可靠，
	// 但 canvas_items 模式下它是真实像素，必须换回画布单位才能和 u_size 及
	// 设计稿里的固定长度处于同一个坐标空间。
	vec2 px = FRAGCOORD.xy / max(u_px_per_unit, 0.001);
	vec4 acc = vec4(0.0);

	// ---- 扫描线 ----
	if (u_scanlines_on) {
		// steps(6) 的抖动：1.4s 内分 6 档，每档 1px（总位移 6px）
		float step_i = floor(mod(TIME / 1.4, 1.0) * 6.0);
		float y = px.y + step_i * u_scale;
		float line = step(mod(y, u_scan_period * u_scale), u_scale);
		float a = u_scan_alpha * line;
		acc.rgb = mix(acc.rgb, u_scan_color, a);
		acc.a = acc.a + a * (1.0 - acc.a);
	}

	// ---- 噪点 ----
	if (u_grain > 0.0) {
		// 稿子是两层 0.5px 的**点阵**（间距 7×11 与 13×5）在闪。
		// 第一版实现成了"按 7×11 的格子取随机数、整格填满"，于是在亮背景
		// （太阳、星云）上就是一片竖着跳的马赛克 —— 格子高 11 宽 7，方向感
		// 也正好是竖的。必须是稀疏的单像素点，不是色块；换随机数的频率也从
		// 0.3s 放慢到 0.5s，免得"跳"。
		float frame = floor(TIME / 0.5);
		vec2 cell = floor(px / max(u_scale, 0.001));
		float n1 = hash21(cell + frame * 13.0);
		float n2 = hash21(cell * 0.37 + frame * 41.0 + 3.7);
		float dots = step(0.988, n1) + step(0.994, n2) * 0.7;
		float amp = mix(0.05, 0.085, abs(sin(TIME * 1.7)));
		float a = clamp(dots, 0.0, 1.0) * amp * u_grain;
		acc.rgb = mix(acc.rgb, vec3(1.0), a);
		acc.a = acc.a + a * (1.0 - acc.a);
	}

	// ---- 暗角 ----
	if (u_vignette > 0.0) {
		float d = min(min(px.x, u_size.x - px.x), min(px.y, u_size.y - px.y));
		float t = clamp(d / (u_vignette_px * u_scale), 0.0, 1.0);
		float a = u_vignette * pow(1.0 - t, 1.7) * 0.9;
		acc.rgb = mix(acc.rgb, vec3(0.0), a / max(acc.a + a, 0.0001));
		acc.a = acc.a + a * (1.0 - acc.a);
	}

	// ---- 顶部扫掠光带 ----
	if (u_sweep > 0.0) {
		float prog = fract(TIME / 6.5);
		// translateY(-110%) → 900%，单位是光带自身高度
		float sweep_h = u_sweep_px * u_scale;
		float top = (-1.1 + prog * 10.1) * sweep_h;
		float rel = (px.y - top) / sweep_h;
		if (rel >= 0.0 && rel <= 1.0) {
			float a = 0.05 * (1.0 - rel) * u_sweep;
			acc.rgb = mix(acc.rgb, u_scan_color, a / max(acc.a + a, 0.0001));
			acc.a = acc.a + a * (1.0 - acc.a);
		}
	}

	// 暗角是一条 200px 的平滑 alpha 渐变，落到 8bit 缓冲里同样会出台阶。
	// 加半个色阶的抖动，和天穹那边一个道理（见 sky.gdshader）。
	acc.a += (hash21(px + floor(TIME * 3.0)) - 0.5) / 255.0;
	COLOR = vec4(acc.rgb, clamp(acc.a, 0.0, 1.0));
}
