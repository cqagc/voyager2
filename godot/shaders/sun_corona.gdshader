// 日冕 + 日珥。一块始终正对相机的公告板，加法混合。
//
// 日冕做成随角度起伏的径向衰减；日珥是同一套角度噪声里被拉长的尖峰
// ——真实日珥就是磁力线把等离子体甩出日面形成的环状/柱状结构，
// 在轮廓上表现为不规则的外伸，所以用角度噪声调制半径是合适的近似。
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec3 corona_color : source_color = vec3(1.0, 0.55, 0.18);
uniform vec3 prom_color : source_color = vec3(1.0, 0.30, 0.10);
uniform float disc_radius = 0.30;
uniform float corona_falloff = 3.2;
uniform float prom_strength = 1.15;
uniform float speed = 0.05;

float hash1(float n) { return fract(sin(n) * 43758.5453123); }

float anoise(float x) {
	float i = floor(x);
	float f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(hash1(i), hash1(i + 1.0), f);
}

float afbm(float x) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * anoise(x);
		x *= 2.07;
		a *= 0.5;
	}
	return v;
}

void vertex() {
	// 公告板：抽掉模型矩阵的旋转，只保留平移，使其恒正对相机。
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
}

void fragment() {
	vec2 d = UV - vec2(0.5);
	float r = length(d) * 2.0;
	if (r > 1.0) { discard; }
	float ang = atan(d.y, d.x);
	float t = TIME * speed;

	// 日冕：径向衰减 + 角度起伏
	float wob = afbm(ang * 3.4 + t * 2.0) * 0.30 + 0.85;
	float corona = pow(clamp(1.0 - (r / wob), 0.0, 1.0), corona_falloff);

	// 日珥：少数几个被拉长的尖峰
	// 两组不同尺度的尖峰：少量大日珥 + 一圈细密的针状结构
	float big = pow(clamp(afbm(ang * 4.0 - t * 2.0), 0.0, 1.0), 6.0);
	float fine = pow(clamp(afbm(ang * 16.0 + t * 5.0), 0.0, 1.0), 4.0) * 0.45;
	float reach = smoothstep(1.0, disc_radius * 1.05, r);
	float prom = (big + fine) * reach * prom_strength;

	// 贴近日面的一圈更亮
	float rim = smoothstep(disc_radius + 0.10, disc_radius, r) * 0.55;

	vec3 c = corona_color * (corona + rim) + prom_color * prom;
	float a = clamp(corona + prom + rim, 0.0, 1.0);
	ALBEDO = c;
	EMISSION = c;
	ALPHA = a;
}
