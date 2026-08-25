# Voyager 2 数字孪生

历史孪生 + 物理模型推演 + 真实星历 + 一条真·实时链路。Godot 4 前端 / Go 后端。

## 这是什么，不是什么

**NASA 不提供 Voyager 2 的任何公开工程遥测**（温度、电压、RTG 功率、推进剂）。
这一点已实测确认，不是没找到，是不存在公开接口。所以这个项目不是实时遥测孪生，而是：

| 层 | 数据性质 |
|---|---|
| 轨迹 | JPL Horizons 真实定轨数据（target `-32`），1977 → 今 |
| RTG 功率 | **物理模型推演**，界面上强制标注「非遥测」 |
| DSN 链路状态 | 真·实时（`eyes.nasa.gov/dsn/data/dsn.xml`，60 秒刷新） |
| 科学仪器数据 | 归档实测，滞后数年（**尚未接入**） |

界面上每个数字都带来源标注。这是本项目的第一纪律 —— 参见
[docs/architecture.md](docs/architecture.md) 第 2 节。

## 启动

```bash
# 1. 抓取星历（分级采样：巡航 1 天 + 四次飞掠窗口 30 分钟）
./scripts/ingest_all.sh          # 首次约 10 分钟，幂等可重跑

# 2. 拆分 NASA 官方模型成语义组件树
#    注意：Blender 必须在宿主机跑，跑不进 Codex 沙箱（Metal 设备为空）
blender --background --factory-startup --python tools/model/assign.py -- \
        --mode export --outdir assets/generated

# 3. 导出 Godot 数据包
go run ./cmd/export

# 4. 启动
/Applications/Godot.app/Contents/MacOS/Godot --path godot
```

### 操作

| 输入 | 作用 |
|---|---|
| 左键拖动 | 旋转视角 |
| 滚轮 | 缩放 |
| `空格` / 播放按钮 | 沿时间轴播放 1977 → 2026 |
| `Tab` / 模式按钮 | 太阳系视图 ⇄ 探测器特写 |
| 特写模式下**右键** | 点选部件，查看 ComponentID、归属判据与置信度 |
| 日期按钮 | 跳到发射 / 四次飞掠 / 穿越日球层顶 |

### 自检（无人值守可用）

```bash
# 渲染六个关键状态的截图，供人工核对
/Applications/Godot.app/Contents/MacOS/Godot --path godot --resolution 1600x900 -- --shots

# 真发一次 DSN 请求，含阳性对照
/Applications/Godot.app/Contents/MacOS/Godot --headless --path godot -- --dsntest

# 命令行工具
go run ./cmd/dsnwatch -once            # Voyager 2 实时链路
go run ./cmd/dsnwatch -once -spacecraft -170   # 阳性对照（JWST）
go test -race ./...
```

## 两个关键工程决策

**双尺度而非双精度引擎。** 早期方案是自编译 `precision=double` 的 Godot。实测后撤销：
float32 的量化误差约 1826 km 且与缩放无关，在全太阳系视图相当于 **0.0000 像素**，
只有探测器特写（视野 15 万 km）才会到 13.2 像素。而 **GDScript 的 `float` 本身就是
64 位双精度**，只有 `Vector3` 分量是 float32 —— 位置全程以裸 double 保存、减掉相机
原点后才转 `Vector3`，就在需要处拿到完整双精度，无需自编译引擎。

**飞掠窗口必须原生密采，不能靠插值。** 实测：飞掠段 6 小时采样的 Hermite 插值误差
33480 km，**超过海王星半径 24764 km** —— 探测器会渲染到星球错误的一侧。原因是引力
弹弓处速度矢量是尖点，导数不连续，任何多项式插值都达不到全阶收敛。策略：巡航 1 天
（误差 50 公分），飞掠窗口 30 分钟（误差 170 km）。已固化为回归测试。

## 尚未开始

- **科学仪器数据**：CDAWeb 的 MAG / PLS / LECP / CRS / PWS 归档数据未接入。
  这是「历史孪生」叙事里缺的关键一层。
- **姿态**：NAIF SPICE CK kernel 未接，飞掠期姿态数据存在但未使用。
- **`cmd/server`**：目前数据走文件包直供 Godot，没有 WebSocket / REST 服务层。
