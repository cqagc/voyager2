## 儒略日与日历的换算，以及尺度相关的小工具。
class_name JDTime
extends RefCounted

const UNIX_JD := 2440587.5
const C_KM_S := 299792.458

## 儒略日 -> [年, 月, 日, 时, 分]（公历）。
static func to_calendar(jd: float) -> Array:
	var z := floori(jd + 0.5)
	var f := (jd + 0.5) - float(z)
	var a := z
	if z >= 2299161:
		var alpha := floori((float(z) - 1867216.25) / 36524.25)
		a = z + 1 + alpha - floori(float(alpha) / 4.0)
	var b := a + 1524
	var c := floori((float(b) - 122.1) / 365.25)
	var d := floori(365.25 * float(c))
	var e := floori(float(b - d) / 30.6001)
	var day := b - d - floori(30.6001 * float(e))
	var month := e - 1 if e < 14 else e - 13
	var year := c - 4716 if month > 2 else c - 4715
	var total_minutes := int(round(f * 1440.0))
	return [year, month, day, total_minutes / 60, total_minutes % 60]

static func format_date(jd: float) -> String:
	var c := to_calendar(jd)
	return "%04d-%02d-%02d %02d:%02d UTC" % [c[0], c[1], c[2], c[3], c[4]]

static func format_date_short(jd: float) -> String:
	var c := to_calendar(jd)
	return "%04d-%02d-%02d" % [c[0], c[1], c[2]]

## 单程光时的人类可读形式。缺失数据必须看起来像缺失，不能显示成 0。
static func light_time_text(distance_km: float) -> String:
	if distance_km <= 0.0:
		return "无数据"
	var sec := distance_km / C_KM_S
	if sec < 120.0:
		return "%.1f 秒" % sec
	if sec < 7200.0:
		return "%.1f 分钟" % (sec / 60.0)
	return "%.2f 小时" % (sec / 3600.0)

static func vec_len(v: Array) -> float:
	return sqrt(float(v[0]) * float(v[0]) + float(v[1]) * float(v[1]) + float(v[2]) * float(v[2]))

## 大数值的科学计数法。GDScript 的字符串格式化不支持 %e，只能自己来。
static func sci(value: float, digits: int = 3) -> String:
	if value == 0.0:
		return "0"
	var neg := value < 0.0
	var v := absf(value)
	var exp := floori(log(v) / log(10.0))
	var mant := v / pow(10.0, float(exp))
	# 浮点边界可能把 9.9999 舍成 10.000，规整一下。
	if mant >= 10.0:
		mant /= 10.0
		exp += 1
	var fmt := "%." + str(digits) + "f"
	var out := (fmt % mant) + "e" + ("+" if exp >= 0 else "-") + "%02d" % absi(exp)
	return ("-" if neg else "") + out

## 时长的人类可读形式，按量级自适应单位。
static func duration_text(sec: float) -> String:
	if sec <= 0.0:
		return "无数据"
	if sec < 120.0:
		return "%.1f 秒" % sec
	if sec < 7200.0:
		return "%.1f 分钟" % (sec / 60.0)
	if sec < 172800.0:
		return "%.2f 小时" % (sec / 3600.0)
	return "%.2f 天" % (sec / 86400.0)
