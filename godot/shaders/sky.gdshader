// 天穹：真实银河全天图，按银道 -> 黄道 -> 世界坐标对齐。
//
// 贴图坐标系是**实测**出来的，不是照着惯例猜的（Solar System Scope 没写）：
// 用 8k 图逐列找银道带脊线，脊线恒在 v≈0.5 且行均值在 v=0.5 处尖峰 ->
// 银道面就是贴图赤道，所以是银道坐标而非赤道/黄道坐标。再拿大麦哲伦云
// （l=280.47°, b=-32.89°）和小麦哲伦云（l=302.81°, b=-44.33°）做判向：
//
//   u = 0.5 - l/360,  v = 0.5 + b/180   -> LMC 处亮度 15.6 / SMC 3.4
//   u = 0.5 + l/360,  v = 0.5 - b/180   -> LMC 处亮度  0.4 / SMC 0.0（全图均值 1.2）
//
// 第一组胜出，且差了一个数量级，不是模棱两可的判断。注意 v=0 是**南**银极
// （贴图上方），这个约定反直觉，写死在这里免得下次有人"顺手修正"。
//
// 世界坐标 -> 银道的旋转矩阵由 GDScript 传入三个行向量（见 twin.gd
// _galactic_rows）。不用 mat3 uniform 是因为 Basis 到 mat3 的行列约定
// 有歧义，三个行向量做点积没有任何解释空间。--skytest 自检这条链路。
shader_type sky;

uniform sampler2D panorama : source_color, filter_linear;
// 世界坐标（黄道 J2000，Y 轴为黄北极）-> 银道坐标的旋转矩阵，逐行传入。
uniform vec3 gal_row0 = vec3(1.0, 0.0, 0.0);
uniform vec3 gal_row1 = vec3(0.0, 1.0, 0.0);
uniform vec3 gal_row2 = vec3(0.0, 0.0, 1.0);
// 星空曝光。默认 8 不是随手调的：这张图**极暗** —— 银河带在贴图里只有
// sRGB 19/255（银心区）到 5/255（一般处），背景 1.2/255。经 source_color
// 转线性再过场景的 ACES（tonemap_white=3.0），brightness=1 时银河带只剩
// 2/255，等于没有。按 ACES 反算最终输出：
//
//   brightness   银道带一般处   银心区   最亮星
//        3           2.6          23.5     159
//        8          12.6          58.4     213
//       13          22.8          84.5     236      <- 取这档
//
// 8 和 13 都出图比过：8 时银河只是"隐约有点东西"，13 时星场层次和银河的
// 云絮结构都出来了，而离银道远处的背景仍然是近乎纯黑。再往上就发灰、
// 失去深空的黑。注意最亮的那几颗星线性值会越过
// glow_hdr_threshold(1.05) 而进 bloom —— 这是想要的，恒星本该有光晕。
uniform float brightness = 13.0;
// 银河之外的底色。深空本该是黑的，这里只留一丝冷色免得完全死黑；
// 数值必须远小于银河带的线性值（约 0.054），否则整片天空被抬成灰雾。
uniform vec3 floor_color : source_color = vec3(0.0016, 0.0018, 0.0030);
// 抖动强度，单位是"源图的一个 8bit 台阶"。
//
// 为什么必须有：这张图极暗（见上），银河带在源图里只占 sRGB 5..19/255 十几
// 个整数级。乘 brightness=13 之后，源图里 1/255 的台阶在屏幕上变成约 13/255
// 的台阶 —— 星云的平滑过渡就被劈成一圈圈可见的色阶。8bit 源里不存在的中间
// 值不可能凭空补出来，所以改成在源台阶所在的空间加 ±半个台阶的噪声，让每个
// 像素随机落到相邻两级之一，肉眼积分出中间色。这是标准做法，代价是极细的
// 颗粒（远小于本来就有的星点噪声）。
//
// 噪声锁在贴图坐标上而不是屏幕坐标：转视角时颗粒跟着天穹走，不会"爬行"。
uniform float dither_steps = 1.0;

const float PI_F = 3.14159265358979;

// source_color 采样时已经做过 sRGB -> 线性，抖动要加在**源台阶所在的空间**，
// 所以先转回 sRGB、抖完再转回线性。用标准 sRGB 分段曲线，不用 pow(2.2) 近似
// —— 近似在极暗端偏差最大，而这张图整个都在极暗端。
vec3 lin_to_srgb(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055,
		step(vec3(0.0031308), c));
}

vec3 srgb_to_lin(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)),
		step(vec3(0.04045), c));
}

float hash12(vec2 p) {
	vec3 q = fract(vec3(p.xyx) * vec3(443.897, 441.423, 437.195));
	q += dot(q, q.yzx + 19.19);
	return fract((q.x + q.y) * q.z);
}

void sky() {
	vec3 d = normalize(EYEDIR);
	vec3 g = normalize(vec3(dot(gal_row0, d), dot(gal_row1, d), dot(gal_row2, d)));

	float l = atan(g.y, g.x);                       // 银经，-PI..PI
	float b = asin(clamp(g.z, -1.0, 1.0));          // 银纬，-PI/2..PI/2
	vec2 uv = vec2(fract(0.5 - l / (2.0 * PI_F)), 0.5 + b / PI_F);

	vec3 t = texture(panorama, uv).rgb;
	if (dither_steps > 0.0) {
		float n = hash12(uv * vec2(8192.0, 4096.0));
		vec3 s = lin_to_srgb(t) + (n - 0.5) * (dither_steps / 255.0);
		t = srgb_to_lin(s);
	}
	COLOR = max(t * brightness, floor_color);
}
