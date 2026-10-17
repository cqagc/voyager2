// 太阳表面：米粒组织 + 黑子 + 临边昏暗 + 对流运动。
//
// 底色走真实光球贴图（Solar System Scope 2K，SDO/HMI 影像调色而来），
// 米粒组织与黑子仍然程序化叠在上面 —— 贴图是一张静止的快照，恒星表面
// 必须在动，否则近距离看就是一张贴纸。贴图缺失时（use_tex=false）整个
// 外观退回纯程序化，与加贴图前一致。
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
// 黑子的空间频率与阈值。
//
// 原值 spot_scale=1.7 + smoothstep(0.30,0.46) 是**错的量级**：fbm 的分布
// 中心在 0.5 附近，这个阈值会把日面近一半染暗，而 1.7 的频率意味着斑块
// 有整个半球那么大 —— 截图里就是几块棕色"大陆"，不是黑子。真实黑子是
// 稀疏的小点，本影直径约日面的 1/50 量级。
// 现在大尺度明暗交给真实光球贴图，程序化这层只负责小而稀的黑子。
uniform float spot_scale = 5.5;
uniform float spot_lo = 0.10;
uniform float spot_hi = 0.21;
uniform float intensity = 2.6;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
uniform bool use_tex = false;
// 贴图占比。只取贴图的**亮度起伏**，而且要先按均值归一化 —— 直接乘原图有
// 两个问题：贴图本身是橙色（RGB 均值 0.948/0.533/0.157），乘在已经是橙色的
// 程序化底色上等于把色相叠两遍；而它的亮度 p5..p95 = 0.35..0.79（2.2 倍
// 跨度），乘完日面会出现几块大暗斑，像烂橘子（第一版就是这样）。
// 归一化后 tex_mix=0.60 把起伏压到 0.78..1.27：看得出大尺度结构，又不成斑。
// 0.35 试过，和完全不贴图的截图几乎无差别 —— 那就是没意义的复杂度。
uniform float tex_mix = 0.60;
// 贴图的 RGB 均值（实测 0.546），用来把亮度归一化到 1 附近。
uniform float tex_mean = 0.546;

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
	float spot_mask = smoothstep(spot_lo, spot_hi, spots);

	// 临边昏暗
	float ndv = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float limb = pow(ndv, 0.42);

	vec3 c = mix(edge_color, mid_color, clamp(gran * 1.5, 0.0, 1.0));
	c = mix(c, core_color, pow(clamp(gran, 0.0, 1.0), 2.2));
	if (use_tex) {
		// 只取亮度、只做乘性调制：贴图给大尺度的明暗分布，
		// 程序化那层继续提供正在翻涌的细节和颜色。
		vec3 tc = texture(albedo_tex, UV).rgb;
		float t = (tc.r + tc.g + tc.b) / (3.0 * tex_mean);
		c *= mix(1.0, t, tex_mix);
	}
	c = mix(c * 0.32, c, spot_mask);
	c = mix(edge_color * 0.55, c, limb);

	ALBEDO = c;
	EMISSION = c * intensity * (0.45 + 0.55 * limb);
}
