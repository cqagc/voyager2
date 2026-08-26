// 行星/卫星的程序化外观。一套着色器按 kind 分支，覆盖太阳系里各类地貌。
//
// 光照：**自己算，不用场景灯光**。太阳恒在日心系原点，方向就是
// -normalize(世界坐标)，无距离衰减。用 OmniLight3D 是不行的 —— 外行星在
// 1400 个单位外，任何带衰减的点光源到那里都归零。
shader_type spatial;
render_mode unshaded, cull_back;

// 0 rocky 1 venus 2 earth 3 mars 4 gas 5 ice 6 io 7 europa 8 titan 9 triton
uniform int kind = 0;
uniform vec3 base_color : source_color = vec3(0.7, 0.7, 0.7);
uniform vec3 band_tint : source_color = vec3(0.55, 0.40, 0.26);
uniform float band_freq = 9.0;
uniform vec3 atmo_color : source_color = vec3(0.4, 0.7, 1.0);
uniform float atmo_power = 0.0;
uniform float ambient = 0.035;
// 大红斑：经纬度（弧度）与大小。仅木星使用。
uniform float spot_lat = -0.38;
uniform float spot_lon = 1.9;
uniform float spot_size = 0.0;
uniform vec3 spot_color : source_color = vec3(0.78, 0.32, 0.18);

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

float fbm(vec3 p, int oct) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 6; i++) {
		if (i >= oct) { break; }
		v += a * vnoise(p);
		p *= 2.07;
		a *= 0.5;
	}
	return v;
}

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

// 环形山：多尺度的坑洼，用噪声的脊做近似
float craters(vec3 n, float scale) {
	float c = 0.0;
	float amp = 1.0;
	for (int i = 0; i < 3; i++) {
		float d = vnoise(n * scale);
		c += amp * smoothstep(0.62, 0.78, d);
		scale *= 2.4;
		amp *= 0.55;
	}
	return clamp(c, 0.0, 1.0);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_nrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	obj_nrm = normalize(VERTEX);
}

void fragment() {
	vec3 n = obj_nrm;
	float lat = n.y;                 // -1..1
	float alat = abs(lat);
	vec3 c = base_color;

	if (kind == 0) {                 // 岩质：环形山 + 斑驳
		float cr = craters(n, 7.0);
		float mott = fbm(n * 4.0, 4);
		c = base_color * mix(0.72, 1.14, mott);
		c = mix(c, c * 0.55, cr * 0.7);
	} else if (kind == 1) {          // 金星：厚重的硫酸云，几乎无细节
		float sw = fbm(vec3(n.x * 2.2, n.y * 5.0, n.z * 2.2), 4);
		c = base_color * mix(0.92, 1.10, sw);
	} else if (kind == 2) {          // 地球：海陆 + 云 + 极冠
		float land = fbm(n * 2.6, 5);
		float m = smoothstep(0.48, 0.56, land);
		vec3 ocean = vec3(0.05, 0.16, 0.38);
		vec3 soil = mix(vec3(0.20, 0.34, 0.13), vec3(0.52, 0.44, 0.28),
			smoothstep(0.50, 0.68, fbm(n * 6.0, 4)));
		c = mix(ocean, soil, m);
		// 极冠
		c = mix(c, vec3(0.93, 0.95, 0.98), smoothstep(0.78, 0.93, alat));
		// 云带
		float cloud = fbm(vec3(n.x * 3.0, n.y * 6.5, n.z * 3.0), 5);
		c = mix(c, vec3(0.96, 0.97, 1.0), smoothstep(0.52, 0.72, cloud) * 0.72);
	} else if (kind == 3) {          // 火星：铁锈色 + 明显极冠 + 暗区
		float dark = fbm(n * 3.2, 5);
		c = base_color * mix(0.68, 1.12, dark);
		c = mix(c, vec3(0.95, 0.96, 0.98), smoothstep(0.86, 0.97, alat));
	} else if (kind == 4) {          // 气态巨行星：纬向条带
		float turb = (vnoise(n * 5.0) - 0.5) * 0.16 + (vnoise(n * 13.0) - 0.5) * 0.05;
		float b = clamp((band_fbm((lat + turb) * band_freq) - 0.30) * 2.1, 0.0, 1.0);
		c = mix(base_color * band_tint * 1.9, base_color * 1.18, b);
		c *= mix(0.78, 1.0, 1.0 - pow(alat, 3.0));
	} else if (kind == 5) {          // 冰巨星：极淡的条带
		float b = clamp((band_fbm(lat * band_freq) - 0.34) * 1.4, 0.0, 1.0);
		c = mix(base_color * 0.90, base_color * 1.08, b);
	} else if (kind == 6) {          // 木卫一：硫磺色 + 火山黑斑
		float s = fbm(n * 5.0, 5);
		c = mix(vec3(0.92, 0.82, 0.30), vec3(0.86, 0.52, 0.16), s);
		c = mix(c, vec3(0.16, 0.12, 0.08), smoothstep(0.70, 0.80, fbm(n * 9.0, 4)) * 0.85);
	} else if (kind == 7) {          // 木卫二：冰壳 + 线纹
		float lin = abs(sin((n.x * 7.0 + n.y * 3.0 + fbm(n * 3.0, 3) * 6.0) * 3.0));
		c = mix(vec3(0.88, 0.87, 0.83), vec3(0.62, 0.48, 0.38), smoothstep(0.92, 1.0, lin));
	} else if (kind == 8) {          // 土卫六：橙色雾霾，看不见地表
		float h = fbm(vec3(n.x, n.y * 3.0, n.z), 3);
		c = mix(vec3(0.85, 0.55, 0.18), vec3(0.95, 0.72, 0.35), h);
	} else if (kind == 9) {          // 海卫一：粉白 + 甜瓜地形
		float mel = fbm(n * 7.0, 4);
		c = mix(vec3(0.86, 0.82, 0.80), vec3(0.92, 0.78, 0.74), mel);
		c = mix(c, vec3(0.96, 0.96, 0.98), smoothstep(0.70, 0.92, alat));
	}

	// 木星大红斑：按经纬度定位的椭圆涡旋
	if (spot_size > 0.001) {
		float plon = atan(n.z, n.x);
		float plat = asin(clamp(lat, -1.0, 1.0));
		float dlon = plon - spot_lon;
		dlon = atan(sin(dlon), cos(dlon));          // 环绕归一
		float d = length(vec2(dlon * 0.55, (plat - spot_lat) * 1.35)) / spot_size;
		float sp = smoothstep(1.0, 0.35, d);
		// 涡旋内部有旋转纹理
		float swirl = fbm(n * 14.0, 3);
		c = mix(c, spot_color * mix(0.75, 1.25, swirl), sp);
	}

	// 光照
	vec3 L = normalize(-world_pos);
	float ndl = dot(world_nrm, L);
	float lit = smoothstep(-0.12, 0.30, ndl);
	vec3 outc = c * (ambient + (1.0 - ambient) * lit);

	// 大气边缘辉光：只在昼侧轮廓上出现，夜侧只留极淡一线
	float ndv = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float rim = pow(1.0 - ndv, 3.2);
	float day = clamp(ndl + 0.28, 0.0, 1.0);
	vec3 glow = atmo_color * rim * atmo_power * (0.20 + 0.80 * day);
	outc += glow;

	ALBEDO = outc;
	EMISSION = glow * 0.75;
}
