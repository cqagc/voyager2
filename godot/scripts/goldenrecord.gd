## 金唱片的真实内容与可程序化合成的音频。
##
## 为什么不打包唱片上的音乐：那 27 首曲目绝大多数是受版权保护的商业录音
## （Bach、Beethoven、Chuck Berry、Blind Willie Johnson 等），NASA 当年只
## 取得了一次性搭载授权，并未把录音置于公有领域 —— NASA 自己的图库都因为
## 版权只能展示 116 张图像中的一部分。所以这里不打包任何录音。
##
## 但唱片上有一部分内容是**物理编码**、可以如实合成的：
##   - 1000 Hz 参考校准音（唱片自带，用于校正转速）
##   - 116 张图像的模拟扫描线编码（每张图按行扫描成音频波形）
## 这两样是真实存在于唱片上的信号，合成它们不涉及任何版权。
class_name GoldenRecord
extends RefCounted

## 唱片的技术规格，均为公开事实。
const SPEC := {
	"diameter_in": 12.0,
	"material": "镀金铜盘",
	"rpm": "16⅔ 转/分（比黑胶慢一半，为了塞进更多内容）",
	"images": 116,
	"languages": 55,
	"music_tracks": 27,
	"music_minutes": 90,
	"sounds_minutes": 12,
	"clock": "封面电镀铀-238，半衰期 44.68 亿年，充当放射性时钟",
	"launched": "1977-08-20（旅行者 2 号）",
}

## 唱片内容分类。曲目名是公开事实，列出标题不涉及版权。
const CONTENTS := [
	{
		"section": "图像（116 张，模拟编码）",
		"note": "以扫描线方式编码成音频波形。封面刻着解码说明。",
		"items": [
			"太阳系与行星尺度图", "人类解剖与 DNA 结构",
			"地球地貌、动植物", "人类的进食、学习、劳作",
			"建筑、交通、望远镜",
		],
	},
	{
		"section": "问候语（55 种语言）",
		"note": "含汉语普通话、粤语、闽南语、吴语 —— 中文占了 4 种。",
		"items": [
			"普通话：各位朋友，你们好，祝你们大家好",
			"粤语 / 闽南语 / 吴语",
			"古苏美尔语、赫梯语（已消亡的语言）",
			"世界语",
		],
	},
	{
		"section": "地球之声（12 分钟蒙太奇）",
		"note": "纯自然与人类活动录音，NASA 自制。",
		"items": [
			"火山、地震、雷雨、海浪", "蟋蟀、青蛙、鸟鸣、鲸歌",
			"心跳、笑声、脚步、亲吻", "母亲与婴儿、EEG 脑电",
			"工具、火车、拖拉机、土星五号点火", "脉冲星",
		],
	},
	{
		"section": "音乐（27 首，约 90 分钟）",
		"note": "⚠ 受版权保护的商业录音，本项目不打包音频，仅列出曲目。",
		"items": [
			"巴赫《勃兰登堡协奏曲》第二号 第一乐章",
			"贝多芬《第五交响曲》第一乐章",
			"莫扎特《魔笛》夜后咏叹调",
			"Chuck Berry《Johnny B. Goode》",
			"Blind Willie Johnson《Dark Was the Night, Cold Was the Ground》",
			"中国古琴曲《流水》（管平湖演奏）",
			"印度拉格《Jaat Kahan Ho》",
			"格鲁吉亚合唱《Chakrulo》",
			"日本尺八《鹤之巢笼》",
			"秘鲁排箫、纳瓦霍夜歌、澳洲原住民歌谣、塞内加尔打击乐",
		],
	},
	{
		"section": "书面致辞",
		"note": "",
		"items": [
			"美国总统卡特：这是一个小小的、遥远的世界的礼物",
			"联合国秘书长瓦尔德海姆",
		],
	},
]

const SAMPLE_RATE := 22050.0

## 合成 1000 Hz 参考校准音。唱片上真实存在，用于校正播放转速。
## 带缓入缓出，避免咔哒声。
static func calibration_tone(seconds: float = 2.0) -> PackedVector2Array:
	var n := int(SAMPLE_RATE * seconds)
	var out := PackedVector2Array()
	out.resize(n)
	var fade := int(SAMPLE_RATE * 0.02)
	for i in n:
		var t := float(i) / SAMPLE_RATE
		var a := 0.30 * sin(TAU * 1000.0 * t)
		if i < fade:
			a *= float(i) / float(fade)
		elif i > n - fade:
			a *= float(n - i) / float(fade)
		out[i] = Vector2(a, a)
	return out


## 把一幅图像按唱片的方式编码成音频：逐行扫描，行内亮度调制载波幅度，
## 每行结束插入同步脉冲。这就是那 116 张图在唱片上的物理形态。
##
## 传入的 image 会被降采样到 rows × cols。
static func encode_image_scanlines(image: Image, rows: int = 48, cols: int = 96,
		line_seconds: float = 0.035) -> PackedVector2Array:
	var out := PackedVector2Array()
	if image == null or image.is_empty():
		return out
	var img := image.duplicate() as Image
	img.resize(cols, rows, Image.INTERPOLATE_BILINEAR)

	var samples_per_line := int(SAMPLE_RATE * line_seconds)
	var sync_samples := int(SAMPLE_RATE * 0.004)
	var phase := 0.0

	for r in rows:
		# 行同步脉冲：一段固定低频，模拟唱片上的行起始标记。
		for i in sync_samples:
			var a := 0.22 * sin(phase)
			phase += TAU * 480.0 / SAMPLE_RATE
			out.append(Vector2(a, a))
		for i in samples_per_line:
			var col := clampi(int(float(i) / float(samples_per_line) * float(cols)), 0, cols - 1)
			var lum := img.get_pixel(col, r).get_luminance()
			# 亮度调制载波频率，听起来就是那种扫描线的“啾啾”声。
			var freq := 700.0 + lum * 2300.0
			var a := 0.26 * sin(phase)
			phase += TAU * freq / SAMPLE_RATE
			out.append(Vector2(a, a))
	return out
