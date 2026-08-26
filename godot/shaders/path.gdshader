// 轨迹线。UV.x = 沿线的归一化位置（0 起点，1 终点）。
//
// 两种用法：
//   行星轨道 —— 冷色细线，缓慢流动的能量脉冲
//   探测器航迹 —— 更亮更粗，脉冲更快，并且沿线做色相渐变，末端（当前位置）
//                 最亮，往回逐渐衰减，视觉上「拖着一条尾巴」
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec3 color_a : source_color = vec3(0.20, 0.55, 0.95);
uniform vec3 color_b : source_color = vec3(0.85, 0.25, 0.95);
uniform float base_alpha = 0.35;
uniform float pulse_speed = 0.18;
uniform float pulse_count = 3.0;
uniform float pulse_gain = 1.6;
uniform float pulse_sharp = 26.0;
// >0 时末端更亮、往回衰减（用于「已飞过的航迹」）
uniform float trail_falloff = 0.0;
// 带宽。以「屏幕高度的比例」计，所以远近粗细一致。
uniform float width_screen = 0.0016;

varying float v_t;

void vertex() {
	// 面向相机的带状几何。
	//
	// Godot 里线段没有宽度（大多数平台上 line width 无效），1 像素的线
	// 谈不上任何视觉表现。这里把路径做成三角带：每个路径点吐两个顶点，
	// 在顶点着色器里沿「切线 × 视线」方向撑开，于是带子恒定正对相机。
	//
	// NORMAL 存的是路径切线，UV.y 是 ±1 的展开方向，UV.x 是沿线位置。
	v_t = UV.x;
	vec3 wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 tangent = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 to_cam = wpos - cam;
	float dist = length(to_cam);
	vec3 view_dir = to_cam / max(dist, 1e-6);
	vec3 side = cross(tangent, view_dir);
	float sl = length(side);
	if (sl > 1e-6) {
		side /= sl;
		// 宽度按距离线性放大 => 屏幕上恒定粗细
		wpos += side * (UV.y * width_screen * dist);
	}
	VERTEX = (inverse(MODEL_MATRIX) * vec4(wpos, 1.0)).xyz;
}

void fragment() {
	float t = v_t;

	// 沿线的色相渐变
	vec3 c = mix(color_a, color_b, t);

	// 流动的能量脉冲
	float phase = fract(t * pulse_count - TIME * pulse_speed);
	float pulse = pow(1.0 - abs(phase * 2.0 - 1.0), pulse_sharp);

	float a = base_alpha;
	if (trail_falloff > 0.001) {
		// 末端（t=1，也就是探测器当前位置）最亮
		a *= mix(0.10, 1.0, pow(t, trail_falloff));
		c = mix(c * 0.65, c, pow(t, trail_falloff * 0.6));
	}

	vec3 outc = c * (a + pulse * pulse_gain);
	ALBEDO = outc;
	EMISSION = outc;
	ALPHA = clamp(a + pulse * 0.9, 0.0, 1.0);
}
