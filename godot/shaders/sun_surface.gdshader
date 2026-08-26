// 太阳表面：米粒组织 + 黑子 + 临边昏暗 + 对流运动。
//
// 全程程序化，不用贴图 —— 这是业界渲染恒星的标准做法：多层不同频率的
// FBM 噪声在球面局部坐标里流动，模拟对流元胞的翻涌；低频噪声压暗成黑子；
// 再按视线与法线的夹角做临边昏暗，让圆盘边缘变暗变红。
//
// 临边昏暗不是美术效果，是真实的物理现象：视线越靠近日面边缘，穿过的
// 光球层越斜，看到的是温度更低的高层，所以更暗更红。少了它，太阳就是
// 一个死板的色盘 —— 之前那版正是如此。
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

uniform vec3 core_color : source_color = vec3(1.0, 0.98, 0.86);
uniform vec3 mid_color : source_color = vec3(1.0, 0.66, 0.22);
uniform vec3 edge_color : source_color = vec3(0.86, 0.26, 0.05);
uniform float flow_speed = 0.035;
uniform float granule_scale = 9.0;
uniform float spot_scale = 1.7;
uniform float intensity = 2.6;

varying vec3 obj_pos;

float hash(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.1, 0.2, 0.3));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash(i + vec3(0.0, 0.0, 0.0));
	float n100 = hash(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash(i + vec3(1.0, 1.0, 1.0));
	return mix(
		mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
		mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

float fbm(vec3 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * vnoise(p);
		p *= 2.03;
		a *= 0.5;
	}
	return v;
}

void vertex() {
	obj_pos = normalize(VERTEX);
}

void fragment() {
	float t = TIME * flow_speed;
	vec3 p = obj_pos;

	// 两层反向流动的米粒组织，避免看出单向平移
	float g1 = fbm(p * granule_scale + vec3(0.0, t, 0.0));
	float g2 = fbm(p * granule_scale * 2.1 - vec3(t * 0.7, 0.0, t * 0.4));
	float gran = mix(g1, g2, 0.45);

	// 黑子：低频噪声的低谷压暗
	float spots = fbm(p * spot_scale + vec3(t * 0.15));
	float spot_mask = smoothstep(0.30, 0.46, spots);

	// 临边昏暗
	float ndv = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float limb = pow(ndv, 0.42);

	vec3 c = mix(edge_color, mid_color, clamp(gran * 1.5, 0.0, 1.0));
	c = mix(c, core_color, pow(clamp(gran, 0.0, 1.0), 2.2));
	c = mix(c * 0.32, c, spot_mask);
	c = mix(edge_color * 0.55, c, limb);

	ALBEDO = c;
	EMISSION = c * intensity * (0.45 + 0.55 * limb);
}
