## 星历数据层：加载 cmd/export 产出的数据包，并按需插值取状态。
##
## 精度说明（重要）：GDScript 的 float 是 64 位双精度，但 Vector3 的分量在官方
## 标准构建里是 float32。所以位置一律以裸 float 数组形式保存和运算，只有在
## 减掉相机原点、进入局部坐标系之后才转成 Vector3。这样就在需要的地方拿到了
## 完整双精度，不必自编译 precision=double 的引擎。
##
## 实测依据：float32 的量化误差约 1826 km 且与缩放无关。在全太阳系视图里
## 相当于 0.0000 像素，在外太阳系 0.0002 像素，但在探测器特写（视野 15 万 km）
## 会达到 13.2 像素 —— 所以特写必须走相机相对坐标。
class_name Ephemeris
extends RefCounted

const MAGIC := "V2TWIN01"
const DOUBLES_PER_SAMPLE := 7
const BYTES_PER_SAMPLE := DOUBLES_PER_SAMPLE * 8

var metadata: Dictionary = {}
var bodies: Array = []
var body_by_name: Dictionary = {}
var components: Array = []
var power_curve: Array = []
var events: Array = []
## 天体外观与物理参数，来自 Go 侧 internal/bodies（不在 GDScript 里另存一份）。
var profiles: Dictionary = {}
## 卫星轨道要素，来自 Go 侧 internal/orbit。只有几何可信，相位不可信。
var satellites: Dictionary = {}
var ring_render_floor_km := 260.0
var au_km: float = 149597870.7

var _blob: PackedByteArray = PackedByteArray()
var _loaded := false

func is_loaded() -> bool:
	return _loaded

## 加载数据包。失败时返回错误说明，成功返回空字符串。
func load_bundle(meta_path: String, bin_path: String) -> String:
	var mf := FileAccess.open(meta_path, FileAccess.READ)
	if mf == null:
		return "打不开 %s（先运行 go run ./cmd/export）" % meta_path
	var parsed: Variant = JSON.parse_string(mf.get_as_text())
	mf.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return "%s 不是合法 JSON" % meta_path
	metadata = parsed

	var bf := FileAccess.open(bin_path, FileAccess.READ)
	if bf == null:
		return "打不开 %s" % bin_path
	_blob = bf.get_buffer(bf.get_length())
	bf.close()

	if _blob.size() < MAGIC.length():
		return "%s 太小，不是有效的星历容器" % bin_path
	var magic := _blob.slice(0, MAGIC.length()).get_string_from_ascii()
	if magic != MAGIC:
		return "星历魔数不匹配：期望 %s，实际 %s" % [MAGIC, magic]

	bodies = metadata.get("bodies", [])
	components = metadata.get("components", [])
	power_curve = metadata.get("power_curve", [])
	events = metadata.get("events", [])
	for pr in metadata.get("profiles", []):
		profiles[pr["name"]] = pr
	for sa in metadata.get("satellites", []):
		satellites[sa["name"]] = sa
	ring_render_floor_km = float(metadata.get("ring_render_floor_km", 260.0))
	au_km = float(metadata.get("au_km", au_km))
	for b in bodies:
		body_by_name[b["name"]] = b

	# 校验每个天体的样本块都真的在文件里，避免运行到一半才炸。
	for b in bodies:
		var need: int = int(b["byte_offset"]) + int(b["samples"]) * BYTES_PER_SAMPLE
		if need > _blob.size():
			return "天体 %s 的样本块越界（需要 %d 字节，文件只有 %d）" % [b["name"], need, _blob.size()]

	_loaded = true
	return ""

func _sample_jd(offset: int, index: int) -> float:
	return _blob.decode_double(offset + index * BYTES_PER_SAMPLE)

## 二分查找：返回 jd 落在 [i, i+1] 区间的 i。
func _find_index(offset: int, count: int, jd: float) -> int:
	var lo := 0
	var hi := count - 1
	while hi - lo > 1:
		var mid := (lo + hi) / 2
		if _sample_jd(offset, mid) <= jd:
			lo = mid
		else:
			hi = mid
	return lo

## 取某天体在 jd 时刻的状态。返回 {pos: [x,y,z] km, vel: [vx,vy,vz] km/s,
## in_range: bool}。区间外不外推，in_range 为 false 并夹取到端点。
func state_at(body_name: String, jd: float) -> Dictionary:
	var out := {"pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0], "in_range": false}
	if not _loaded or not body_by_name.has(body_name):
		return out
	var b: Dictionary = body_by_name[body_name]
	var count: int = int(b["samples"])
	var offset: int = int(b["byte_offset"])
	if count == 0:
		return out

	var jd_min: float = _sample_jd(offset, 0)
	var jd_max: float = _sample_jd(offset, count - 1)
	var clamped := clampf(jd, jd_min, jd_max)
	out["in_range"] = absf(clamped - jd) < 1e-9

	if count == 1:
		_read_into(offset, 0, out)
		return out

	var i := _find_index(offset, count, clamped)
	var j := mini(i + 1, count - 1)
	if i == j:
		_read_into(offset, i, out)
		return out

	var base_i := offset + i * BYTES_PER_SAMPLE
	var base_j := offset + j * BYTES_PER_SAMPLE
	var t0 := _blob.decode_double(base_i)
	var t1 := _blob.decode_double(base_j)
	var h := t1 - t0
	if h <= 0.0:
		_read_into(offset, i, out)
		return out

	# 三次 Hermite。速度是 km/s，而区间以「天」为单位，切向量必须乘 86400
	# 换算到秒 —— 漏掉这一步误差会大到离谱。与 internal/store 的实现一致。
	var s := (clamped - t0) / h
	var hd := h * 86400.0
	var s2 := s * s
	var s3 := s2 * s
	var h00 := 2.0 * s3 - 3.0 * s2 + 1.0
	var h10 := s3 - 2.0 * s2 + s
	var h01 := -2.0 * s3 + 3.0 * s2
	var h11 := s3 - s2

	var pos := []
	var vel := []
	for k in 3:
		var p0 := _blob.decode_double(base_i + (1 + k) * 8)
		var v0 := _blob.decode_double(base_i + (4 + k) * 8)
		var p1 := _blob.decode_double(base_j + (1 + k) * 8)
		var v1 := _blob.decode_double(base_j + (4 + k) * 8)
		pos.append(h00 * p0 + h10 * hd * v0 + h01 * p1 + h11 * hd * v1)
		vel.append(lerpf(v0, v1, s))
	out["pos"] = pos
	out["vel"] = vel
	return out

func _read_into(offset: int, index: int, out: Dictionary) -> void:
	var base := offset + index * BYTES_PER_SAMPLE
	out["pos"] = [
		_blob.decode_double(base + 8), _blob.decode_double(base + 16), _blob.decode_double(base + 24)
	]
	out["vel"] = [
		_blob.decode_double(base + 32), _blob.decode_double(base + 40), _blob.decode_double(base + 48)
	]

## 时间轴应当采用的跨度。
##
## 必须取**主角**（voyager2）的覆盖范围，不能取所有天体的并集：行星星历比
## 航天器多出半天左右，用并集会让默认时刻就落在 voyager2 的覆盖之外，
## 于是一进场就亮红字「超出星历覆盖范围」、探测器标记还被隐藏。
func jd_span() -> Array:
	if body_by_name.has("voyager2"):
		var v: Dictionary = body_by_name["voyager2"]
		return [float(v["jd_min"]), float(v["jd_max"])]
	var lo := INF
	var hi := -INF
	for b in bodies:
		lo = minf(lo, float(b["jd_min"]))
		hi = maxf(hi, float(b["jd_max"]))
	return [lo, hi]

## RTG 建模功率（瓦）。这是 internal/power 导出的曲线，不是这里重新算的
## —— 物理模型只有一个真相源，前端不许悄悄漂移。
func power_at(jd: float) -> Dictionary:
	var out := {"watts": 0.0, "fuel_fraction": 1.0, "converter_fraction": 1.0}
	if power_curve.is_empty():
		return out
	if jd <= float(power_curve[0]["jd"]):
		return {"watts": float(power_curve[0]["watts"]),
			"fuel_fraction": float(power_curve[0]["fuel_fraction"]),
			"converter_fraction": float(power_curve[0]["converter_fraction"])}
	var last: Dictionary = power_curve[power_curve.size() - 1]
	if jd >= float(last["jd"]):
		return {"watts": float(last["watts"]),
			"fuel_fraction": float(last["fuel_fraction"]),
			"converter_fraction": float(last["converter_fraction"])}
	var lo := 0
	var hi := power_curve.size() - 1
	while hi - lo > 1:
		var mid := (lo + hi) / 2
		if float(power_curve[mid]["jd"]) <= jd:
			lo = mid
		else:
			hi = mid
	var a: Dictionary = power_curve[lo]
	var b: Dictionary = power_curve[hi]
	var f := (jd - float(a["jd"])) / maxf(1e-9, float(b["jd"]) - float(a["jd"]))
	return {
		"watts": lerpf(float(a["watts"]), float(b["watts"]), f),
		"fuel_fraction": lerpf(float(a["fuel_fraction"]), float(b["fuel_fraction"]), f),
		"converter_fraction": lerpf(float(a["converter_fraction"]), float(b["converter_fraction"]), f),
	}


## 某天体在 jd 附近的相邻样本间隔（天）。
##
## 用来判断星历能不能表示这个卫星的公转：木卫一 1.77 天一圈，日采样只有
## 0.56 个样本每圈，插出来是混叠的垃圾。低于约 8 个样本每圈就不该把它的
## 位置当真。
func sample_spacing_days(body_name: String, jd: float) -> float:
	if not body_by_name.has(body_name):
		return INF
	var b: Dictionary = body_by_name[body_name]
	var count: int = int(b["samples"])
	var offset: int = int(b["byte_offset"])
	if count < 2:
		return INF
	var lo := _sample_jd(offset, 0)
	var hi := _sample_jd(offset, count - 1)
	var clamped := clampf(jd, lo, hi)
	var i := _find_index(offset, count, clamped)
	var j := mini(i + 1, count - 1)
	if i == j:
		return INF
	return absf(_sample_jd(offset, j) - _sample_jd(offset, i))


## 该卫星在此刻能否用星历定位。
func satellite_position_is_resolved(body_name: String, jd: float) -> bool:
	if not satellites.has(body_name):
		return true
	var period := float(satellites[body_name]["period_days"])
	if period <= 0.0:
		return true
	var gap := sample_spacing_days(body_name, jd)
	if gap == INF:
		return false
	return period / gap >= 8.0


## 卫星轨道要素解 —— 只用来画轨道环。
##
## 与 Go 侧 internal/orbit 的实现必须一致；GDScript 这份是为了逐帧计算，
## 一致性由 --orbittest 自检对着 Go 生成的基准值校验。
## 返回 [x, y, z]（公里，黄道 J2000），**不是 Vector3**。
##
## Vector3 的分量在官方标准构建里是 float32，40 万公里量级上分辨率约 0.03 km。
## 跨语言契约自检一开始就是因为这个报出约 0.014 km 的偏差 —— 那不是算法不
## 一致，是把 double 塞进 float32 丢的精度。星历那边一直用裸 Array 保持
## double，这里当初漏了。
func satellite_offset_km(body_name: String, jd: float, parent_obliquity_deg: float) -> Array:
	if not satellites.has(body_name):
		return [0.0, 0.0, 0.0]
	var e: Dictionary = satellites[body_name]
	var period := float(e["period_days"])
	if period <= 0.0:
		return [0.0, 0.0, 0.0]
	var ecc := float(e["ecc"])
	var n := TAU / period
	var m: float = deg_to_rad(float(e["mean_anom_deg"])) + n * (jd - float(e["epoch_jd"]))
	m = fposmod(m, TAU)

	# 牛顿迭代解开普勒方程 E - e·sinE = M
	var ea := m
	for _i in 32:
		var f := ea - ecc * sin(ea) - m
		var fp := 1.0 - ecc * cos(ea)
		if absf(fp) < 1e-15:
			break
		var d := f / fp
		ea -= d
		if absf(d) < 1e-14:
			break

	var a := float(e["semi_major_km"])
	var xv := a * (cos(ea) - ecc)
	var yv := a * sqrt(1.0 - ecc * ecc) * sin(ea)

	var w := deg_to_rad(float(e["arg_peri_deg"]))
	var inc := deg_to_rad(float(e["inc_deg"]))
	var om := deg_to_rad(float(e["node_deg"]))
	var x1 := xv * cos(w) - yv * sin(w)
	var y1 := xv * sin(w) + yv * cos(w)
	var y2 := y1 * cos(inc)
	var z2 := y1 * sin(inc)
	var px := x1 * cos(om) - y2 * sin(om)
	var py := x1 * sin(om) + y2 * cos(om)
	var pz := z2

	# 母星赤道面 -> 黄道 J2000
	var t := deg_to_rad(parent_obliquity_deg)
	return [px, py * cos(t) - pz * sin(t), py * sin(t) + pz * cos(t)]
