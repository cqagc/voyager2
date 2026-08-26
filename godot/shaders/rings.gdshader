// 土星环。UV.x = 归一化半径（0 在 C 环内缘，1 在 A 环外缘）。
//
// 各道环与缝的边界由真实数据传入（见 BodyData）：
//   C 环 74,658–92,000 km   B 环 92,000–117,580   卡西尼缝 117,580–122,170
//   A 环 122,170–136,775    恩克缝 133,589–133,914  基勒缝 136,470–136,512
// 全部以土星赤道半径 60,300 km 归一化。
//
// 两个必须做的物理效果：
//   1. 行星在环上投下的影子 —— 环是薄片，土星本体会在背光侧的环面上切出
//      一道清晰的暗带，这是土星影像里最标志性的细节之一。
//   2. 背光透射 —— 从环的暗面看过去，稀疏的 C 环反而更亮（散射），
//      致密的 B 环更暗。所以不能简单地用同一套不透明度。
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_opaque, shadows_disabled;

uniform vec3 ring_color : source_color = vec3(0.86, 0.79, 0.66);
// 环带查找表：一行像素，R 通道 = 该半径处的不透明度。
//
// 用纹理而不是一串 uniform，是为了同一套着色器同时服务土星（6 段）、
// 天王星（13 段）和海王星（5 段）—— 环带数量差得远，写死 uniform 不现实。
uniform sampler2D band_lut : filter_linear, repeat_disable;
// 行星半径（与环网格同一坐标系），用于计算本影
uniform float planet_radius = 1.0;

varying vec3 world_pos;
varying vec3 local_pos;

float hash1(float n) { return fract(sin(n * 127.1) * 43758.5453123); }

float n1(float x) {
	float i = floor(x);
	float f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(hash1(i), hash1(i + 1.0), f);
}

float fine(float x) {
	// 环里密密麻麻的细纹（成千上万条小环）
	float v = 0.0;
	float a = 0.5;
	float f = 60.0;
	for (int i = 0; i < 5; i++) {
		v += a * n1(x * f);
		f *= 2.3;
		a *= 0.55;
	}
	return v;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	local_pos = VERTEX;
}

void fragment() {
	float r = UV.x;

	// 从查找表取该半径处的不透明度
	float opacity = texture(band_lut, vec2(clamp(r, 0.002, 0.998), 0.5)).r;

	// 细纹结构
	float detail = fine(r);
	opacity *= mix(0.72, 1.22, detail);
	// 内外缘柔化
	opacity *= smoothstep(0.0, 0.02, r) * smoothstep(1.0, 0.975, r);

	// 行星本影：环上落在土星圆柱形阴影里的那一段
	vec3 L = normalize(-world_pos);                       // 指向太阳
	// 把环面上这一点分解成「沿日向」与「垂直日向」两部分
	float along = dot(world_pos, -L);                     // >0 表示在背光侧
	vec3 perp = world_pos + L * along;
	float shadow = 1.0;
	if (along > 0.0) {
		shadow = smoothstep(planet_radius * 0.92, planet_radius * 1.08, length(perp));
		shadow = mix(0.18, 1.0, shadow);
	}

	// 背光透射：从暗面看，稀疏环更亮、致密环更暗
	float facing = dot(normalize(NORMAL), normalize(VIEW));
	float backlit = 1.0 - smoothstep(0.0, 0.35, abs(facing));

	// 环本身的受光。
	//
	// 环是无数冰粒，各向散射。太阳越正照环面（|cos| 越大）反射越强；
	// 环面接近侧对太阳时几乎不亮。早先漏了这一项，结果整个环系只剩本影
	// 计算，看起来是一圈灰暗的细线。
	vec3 ring_n = normalize((MODEL_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	float sun_face = abs(dot(ring_n, L));
	float illum = 0.42 + 2.60 * pow(sun_face, 0.55);

	vec3 c = ring_color * mix(0.80, 1.15, detail) * illum;
	c *= shadow;
	c = mix(c, c * (1.0 - opacity * 0.75) * 2.2, backlit * 0.45);

	ALBEDO = c;
	ALPHA = clamp(opacity, 0.0, 1.0);
}
