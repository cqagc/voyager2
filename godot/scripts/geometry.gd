## 测控几何与链路预算。全部由星历推导，没有一个数字是编的。
##
## 这些才是任务运控真正盯的量。「距日」对科学有意义，但对运控没用：
## 指令和遥测走的是地球↔探测器这条线，所以距离、距离变化率（多普勒）、
## 赤经赤纬（往哪儿指天线）、以及链路预算才是命脉。
class_name Geometry
extends RefCounted

const AU_KM := 149597870.7
const C_KM_S := 299792.458
## 太阳引力常数 km^3/s^2
const MU_SUN := 1.32712440018e11
## J2000 黄赤交角
const OBLIQUITY_DEG := 23.4392911
## Voyager 2 的 X 波段下行频率（Hz）
const X_BAND_HZ := 8.420e9
## 行波管放大器输出功率（W）。公开数据约 18 W。
const TWTA_W := 18.0
## 高增益天线 X 波段增益（dBi），3.7 m 碟。
const HGA_GAIN_DBI := 48.0
## DSN 70 米站 X 波段接收增益（dBi）。
const DSN_70M_GAIN_DBI := 74.0
## Voyager 2 穿越日球层顶时的距日距离（AU），2018-11-05。
const HELIOPAUSE_AU := 119.0

## DSN 三大深空网测站的纬度。天线仰角下限取 10°。
const DSN_STATIONS := [
	{"name": "金石 Goldstone", "code": "DSS-14/24/26", "lat": 35.43},
	{"name": "马德里 Madrid", "code": "DSS-53/63/65", "lat": 40.43},
	{"name": "堪培拉 Canberra", "code": "DSS-34/43", "lat": -35.40},
]
const MIN_ELEVATION_DEG := 10.0


static func _sub(a: Array, b: Array) -> Array:
	return [float(a[0]) - float(b[0]), float(a[1]) - float(b[1]), float(a[2]) - float(b[2])]

static func _dot(a: Array, b: Array) -> float:
	return float(a[0]) * float(b[0]) + float(a[1]) * float(b[1]) + float(a[2]) * float(b[2])

static func _norm(a: Array) -> float:
	return sqrt(_dot(a, a))

static func _angle_deg(a: Array, b: Array) -> float:
	var d := _norm(a) * _norm(b)
	if d <= 0.0:
		return 0.0
	return rad_to_deg(acos(clampf(_dot(a, b) / d, -1.0, 1.0)))


## 黄道 J2000 -> 赤道 J2000。赤经赤纬是「天线往哪儿指」的答案，
## 而星历给的是黄道坐标，必须先转过去。
static func ecliptic_to_equatorial(v: Array) -> Array:
	var e := deg_to_rad(OBLIQUITY_DEG)
	var y := float(v[1]) * cos(e) - float(v[2]) * sin(e)
	var z := float(v[1]) * sin(e) + float(v[2]) * cos(e)
	return [float(v[0]), y, z]


## 一次算齐所有测控量。probe / earth 均为 {pos, vel}（日心黄道 J2000，km / km/s）。
static func tracking(probe: Dictionary, earth: Dictionary) -> Dictionary:
	var r_vec := _sub(probe["pos"], earth["pos"])
	var v_vec := _sub(probe["vel"], earth["vel"])
	var range_km := _norm(r_vec)

	# 距离变化率就是多普勒观测量本身。DSN 测的就是这个。
	var range_rate := 0.0
	if range_km > 0.0:
		range_rate = _dot(r_vec, v_vec) / range_km

	var eq := ecliptic_to_equatorial(r_vec)
	var eq_r := _norm(eq)
	var dec := 0.0
	var ra := 0.0
	if eq_r > 0.0:
		dec = rad_to_deg(asin(clampf(float(eq[2]) / eq_r, -1.0, 1.0)))
		ra = rad_to_deg(atan2(float(eq[1]), float(eq[0])))
		if ra < 0.0:
			ra += 360.0

	# SEP：以地球为顶点的太阳-地球-探测器夹角。接近 0° 意味着太阳合，
	# 探测器躲到太阳背后，链路被太阳射电噪声压住。
	var earth_to_sun := [-float(earth["pos"][0]), -float(earth["pos"][1]), -float(earth["pos"][2])]
	var sep := _angle_deg(earth_to_sun, r_vec)

	# SPE：以探测器为顶点的太阳-探测器-地球夹角。高增益天线对地指向时，
	# 这个角就是天线轴线与太阳方向的夹角。
	var probe_to_sun := [-float(probe["pos"][0]), -float(probe["pos"][1]), -float(probe["pos"][2])]
	var probe_to_earth := [-float(r_vec[0]), -float(r_vec[1]), -float(r_vec[2])]
	var spe := _angle_deg(probe_to_sun, probe_to_earth)

	return {
		"range_km": range_km,
		"range_au": range_km / AU_KM,
		"range_rate_kms": range_rate,
		"owlt_sec": range_km / C_KM_S,
		"rtlt_sec": 2.0 * range_km / C_KM_S,
		"ra_deg": ra,
		"dec_deg": dec,
		"sep_deg": sep,
		"spe_deg": spe,
		# X 波段多普勒频移。负值表示远离（红移）。
		"doppler_hz": -range_rate / C_KM_S * X_BAND_HZ,
	}


## 哪些 DSN 测站能看见这个赤纬的目标。
##
## 判据是中天最大高度角 = 90° - |站纬度 - 目标赤纬|，高于仰角下限才够得着。
## Voyager 2 赤纬约 -60°，算下来只有堪培拉能看见（金石 -5°、马德里 -10°，
## 都在地平线以下）—— 这正是 DSN 面板上「当前未跟踪」是常态而非故障的原因：
## 一天只有堪培拉那几个小时的窗口。
static func visible_stations(dec_deg: float) -> Array:
	var out := []
	for s in DSN_STATIONS:
		var culmination := 90.0 - absf(float(s["lat"]) - dec_deg)
		out.append({
			"name": s["name"], "code": s["code"],
			"culmination_deg": culmination,
			"visible": culmination > MIN_ELEVATION_DEG,
		})
	return out


## 下行链路预算。自由空间路径损耗随距离平方增长，这是数据率一路降到
## 160 bps 的物理原因。
static func link_budget(range_km: float) -> Dictionary:
	if range_km <= 0.0:
		return {"fspl_db": 0.0, "rx_dbm": 0.0, "rx_dbw": 0.0}
	var lambda_m := C_KM_S * 1000.0 / X_BAND_HZ
	var range_m := range_km * 1000.0
	var fspl := 20.0 * (log(4.0 * PI * range_m / lambda_m) / log(10.0))
	var tx_dbw := 10.0 * (log(TWTA_W) / log(10.0))
	var rx_dbw := tx_dbw + HGA_GAIN_DBI + DSN_70M_GAIN_DBI - fspl
	return {
		"fspl_db": fspl,
		"rx_dbw": rx_dbw,
		"rx_dbm": rx_dbw + 30.0,
	}


## 日心轨道能量：还在束缚轨道上，还是已经逃逸？
static func orbit(probe: Dictionary) -> Dictionary:
	var r := _norm(probe["pos"])
	var v := _norm(probe["vel"])
	if r <= 0.0:
		return {"v_inf_kms": 0.0, "escaping": false, "v_escape_kms": 0.0, "r_au": 0.0}
	var v_esc := sqrt(2.0 * MU_SUN / r)
	var energy := v * v - 2.0 * MU_SUN / r
	return {
		"r_au": r / AU_KM,
		"speed_kms": v,
		"v_escape_kms": v_esc,
		"escaping": energy > 0.0,
		# 双曲剩余速度：耗尽太阳引力后仍保留的速度。
		"v_inf_kms": sqrt(maxf(energy, 0.0)),
		"beyond_heliopause": r / AU_KM > HELIOPAUSE_AU,
	}


## 从探测器看太阳的视角直径（角分）。
static func sun_angular_diameter_arcmin(r_km: float) -> float:
	if r_km <= 0.0:
		return 0.0
	return rad_to_deg(2.0 * atan(696000.0 / r_km)) * 60.0


## 离探测器最近的天体及距离。飞掠期间这一项最有看头。
static func nearest_body(probe_pos: Array, bodies: Array, state_fn: Callable, jd: float) -> Dictionary:
	var best := {"name": "", "label": "", "distance_km": INF}
	for b in bodies:
		if bool(b["is_spacecraft"]):
			continue
		var st: Dictionary = state_fn.call(String(b["name"]), jd)
		if not bool(st["in_range"]):
			continue
		var d := _norm(_sub(probe_pos, st["pos"]))
		if d < float(best["distance_km"]):
			best = {"name": String(b["name"]), "label": String(b["label"]),
				"distance_km": d, "radius_km": float(b["mean_radius_km"])}
	return best
