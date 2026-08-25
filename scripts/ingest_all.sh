#!/usr/bin/env bash
# 按实测确定的分级采样策略，把 Voyager 2 数字孪生的全部星历落库。
#
# 采样策略不是拍脑袋定的，是量出来的（见 docs/architecture.md 第 4 节
# 与 internal/store/accuracy_test.go）：
#
#   巡航段 1 天    -> Hermite 插值误差 0.0005 km（50 公分）
#   飞掠段 6 小时  -> 误差 33480 km，超过海王星半径，探测器会渲染到错误一侧
#   飞掠段 30 分钟 -> 误差 170 km  ✅
#
# 飞掠段误差大不是插值器的毛病：引力弹弓处速度矢量是尖点，导数不连续，
# 任何多项式插值都达不到全阶收敛。唯一的解法是原生密采。
#
# 幂等：state_vectors 主键是 (body_id, jdtdb) 且走 UPSERT，重复运行安全，
# 细粒度窗口只是往已有的日级基线里补点。
set -euo pipefail

DB="${DB:-data/voyager2.db}"
BIN="go run ./cmd/ingest"
STOP="${STOP:-$(date +%F)}"

echo "==> 阶段 1/2：巡航基线，全天体，1 天步长"
$BIN -db "$DB" -start 1977-08-20 -stop "$STOP" -step '1 d'

# 四次引力助推。每个窗口取 ±10 天，足够覆盖速度矢量急转的全过程。
# 日期为 Voyager 2 的最近接近时刻。
echo "==> 阶段 2/2：四次飞掠窗口加密，30 分钟步长"
refine() {
  local label="$1" start="$2" stop="$3"
  echo "    -- $label  $start .. $stop"
  # 只加密与该次飞掠相关的天体，避免无意义的请求。
  $BIN -db "$DB" -start "$start" -stop "$stop" -step '30 m' -bodies "$4"
}

refine "木星 1979-07-09" 1979-06-29 1979-07-19 \
       voyager2,jupiter,io,europa,ganymede,callisto
refine "土星 1981-08-26" 1981-08-16 1981-09-05 \
       voyager2,saturn,titan
refine "天王星 1986-01-24" 1986-01-14 1986-02-03 \
       voyager2,uranus,miranda
refine "海王星 1989-08-25" 1989-08-15 1989-09-04 \
       voyager2,neptune,triton

echo "==> 覆盖情况"
sqlite3 "$DB" "SELECT b.name, COUNT(*) AS samples,
  printf('%.1f', MIN(sv.jdtdb)) AS jd_min,
  printf('%.1f', MAX(sv.jdtdb)) AS jd_max
  FROM state_vectors sv JOIN bodies b ON b.id = sv.body_id
  GROUP BY b.name ORDER BY samples DESC;"
