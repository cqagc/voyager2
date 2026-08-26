## 太阳系天体的物理与外观参数。
##
## 数据来源：NASA Planetary Fact Sheet（对轨道倾角 obliquity to orbit）与
## 维基百科 Rings of Saturn（环系半径）。两处倾角慣例不同但已交叉核对一致：
## 维基用「轴倾角 + 逆行」（金星 2.64° 逆行、天王星 82.23° 逆行），NASA 用
## 「对轨道倾角」（177.4° / 97.8°），180 − 2.64 = 177.36、180 − 82.23 = 97.77。
## 这里统一采用**对轨道倾角**，因为它直接就是渲染时自转轴该摆的角度。
##
## 自转周期负号 = 逆行。金星和天王星是逆行的。
class_name BodyData
extends RefCounted

## 对轨道倾角（度）。天王星 97.8° 意味着它基本是躺着转的 —— 这是太阳系里
## 视觉上最反常的一件事，值得如实渲染出来。
const OBLIQUITY := {
	"mercury": 0.034, "venus": 177.4, "earth": 23.44, "mars": 25.19,
	"jupiter": 3.12, "saturn": 26.73, "uranus": 97.77, "neptune": 28.33,
	"io": 0.0, "europa": 0.1, "ganymede": 0.2, "callisto": 0.0,
	"titan": 0.3, "miranda": 0.0, "triton": 0.0,
}

## 恒星自转周期（小时），负号为逆行。
const ROTATION_HOURS := {
	"mercury": 1407.6, "venus": -5832.6, "earth": 23.93, "mars": 24.62,
	"jupiter": 9.93, "saturn": 10.66, "uranus": -17.24, "neptune": 16.11,
	"io": 42.5, "europa": 85.2, "ganymede": 171.7, "callisto": 400.5,
	"titan": 382.7, "miranda": 33.9, "triton": -141.0,
}

## 外观类型，决定用哪套程序化着色。
const KIND := {
	"mercury": "rocky", "venus": "venus", "earth": "earth", "mars": "mars",
	"jupiter": "gas", "saturn": "gas", "uranus": "ice", "neptune": "ice",
	"io": "io", "europa": "europa", "ganymede": "rocky", "callisto": "rocky",
	"titan": "titan", "miranda": "rocky", "triton": "triton",
}

## 大气边缘辉光的颜色与强度。没有大气的天体强度为 0。
const ATMOSPHERE := {
	"venus": {"color": Color(1.0, 0.86, 0.55), "power": 0.85},
	"earth": {"color": Color(0.42, 0.68, 1.0), "power": 0.95},
	"mars": {"color": Color(1.0, 0.68, 0.52), "power": 0.35},
	"jupiter": {"color": Color(1.0, 0.82, 0.62), "power": 0.55},
	"saturn": {"color": Color(1.0, 0.90, 0.70), "power": 0.45},
	"uranus": {"color": Color(0.62, 0.92, 0.96), "power": 0.60},
	"neptune": {"color": Color(0.42, 0.60, 1.0), "power": 0.65},
	"titan": {"color": Color(1.0, 0.72, 0.35), "power": 0.75},
}

## 土星环系。半径以土星赤道半径（60,300 km）为单位。
##
## 数据（km，距土星中心）：
##   C 环   74,658 – 92,000        B 环   92,000 – 117,580
##   卡西尼缝 117,580 – 122,170     A 环   122,170 – 136,775
##   恩克缝  133,589 – 133,914      基勒缝  136,470 – 136,512
const SATURN_RADIUS_KM := 60300.0
const RING_INNER := 74658.0 / SATURN_RADIUS_KM   # ≈ 1.238
const RING_OUTER := 136775.0 / SATURN_RADIUS_KM  # ≈ 2.268

## 每道环/缝的归一化位置（相对 RING_INNER..RING_OUTER 区间），供着色器分段。
static func ring_bands() -> Dictionary:
	var lo := RING_INNER
	var hi := RING_OUTER
	var f := func(km: float) -> float:
		return (km / SATURN_RADIUS_KM - lo) / (hi - lo)
	return {
		"c_end": f.call(92000.0),
		"b_end": f.call(117580.0),
		"cassini_end": f.call(122170.0),
		"encke_lo": f.call(133589.0),
		"encke_hi": f.call(133914.0),
		"keeler_lo": f.call(136470.0),
		"keeler_hi": f.call(136512.0),
	}
