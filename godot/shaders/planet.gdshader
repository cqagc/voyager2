// 行星：自己算太阳光照，不依赖场景灯光。
//
// 为什么不用 OmniLight3D：太阳在原点，而外行星在这个尺度下距原点 1400 个
// 单位，任何带距离衰减的点光源到那里都衰减到零 —— 之前那版正是如此，
// 外行星实际上完全没被照到，看到的全是环境光，所以是一片死板的色块。
//
// 日心系里太阳恒在原点，所以光照方向就是 -normalize(世界坐标)，无衰减。
// 这样还顺带得到了正确的晨昏线：行星会呈现真实的相位。
shader_type spatial;
render_mode unshaded, cull_back;

uniform vec3 base_color : source_color = vec3(0.7, 0.7, 0.7);
uniform vec3 band_tint : source_color = vec3(0.55, 0.40, 0.26);
uniform float band_strength = 0.0;
uniform float band_freq = 9.0;
uniform float ambient = 0.045;
uniform float rim_strength = 0.30;

varying vec3 world_pos;
varying vec3 world_nrm;
varying vec3 obj_nrm;

float hash(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.71, 0.113, 0.419));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(hash(i), hash(i + vec3(1,0,0)), f.x), mix(hash(i + vec3(0,1,0)), hash(i + vec3(1,1,0)), f.x), f.y),
		mix(mix(hash(i + vec3(0,0,1)), hash(i + vec3(1,0,1)), f.x), mix(hash(i + vec3(0,1,1)), hash(i + vec3(1,1,1)), f.x), f.y), f.z);
}

// 沿纬度方向的多倍频噪声，用来生成气态巨行星的纬向条带。
float band_fbm(float y) {
	float v = 0.0;
	float a = 0.55;
	float f = 1.0;
	for (int i = 0; i < 4; i++) {
		v += a * vnoise(vec3(y * f, 0.0, 0.0));
		f *= 2.13;
		a *= 0.52;
	}
	return v;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_nrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	obj_nrm = normalize(VERTEX);
}

void fragment() {
	vec3 L = normalize(-world_pos);
	float ndl = dot(world_nrm, L);
	// 略微柔化的晨昏线
	float lit = smoothstep(-0.12, 0.30, ndl);

	vec3 c = base_color;
	if (band_strength > 0.001) {
		// 气态巨行星的纬向条带。
		//
		// 关键是**扰动纬度**再取噪声：真实的木星条带不是笔直的纬线，而是被
		// 急流搅出波浪和涡旋。直接对 y 取噪声只会得到僵硬的横道。
		float turb = (vnoise(obj_nrm * 5.0) - 0.5) * 0.16
			+ (vnoise(obj_nrm * 13.0) - 0.5) * 0.05;
		float b = band_fbm((obj_nrm.y + turb) * band_freq);
		b = clamp((b - 0.30) * 2.1, 0.0, 1.0);

		// 亮带与暗带用不同色调，而不只是明暗差 —— 真实的带纹本身就有色差。
		vec3 belt = base_color * band_tint * 1.9;
		vec3 zone = base_color * 1.18;
		vec3 banded = mix(belt, zone, b);

		// 极区偏暗
		banded *= mix(0.78, 1.0, 1.0 - pow(abs(obj_nrm.y), 3.0));
		c = mix(base_color, banded, band_strength);
	} else {
		float mottle = vnoise(obj_nrm * 6.0);
		c = mix(c * 0.90, c * 1.08, mottle);
	}

	// 边缘光：昼侧轮廓上的一圈亮边
	float ndv = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float rim = pow(1.0 - ndv, 3.0) * rim_strength * clamp(ndl + 0.35, 0.0, 1.0);

	vec3 outc = c * (ambient + (1.0 - ambient) * lit) + base_color * rim;
	ALBEDO = outc;
	EMISSION = base_color * rim * 0.35;
}
