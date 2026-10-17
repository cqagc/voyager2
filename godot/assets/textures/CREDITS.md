# 天体贴图来源

本目录下全部 `.jpg` / `.png` 来自 **Solar System Scope**（INOVE, s.r.o.）：

- 出处：https://www.solarsystemscope.com/textures/
- 许可：**Creative Commons Attribution 4.0 International (CC BY 4.0)**
  https://creativecommons.org/licenses/by/4.0/
- 原作说明：贴图基于 NASA 的地形与影像数据，色调参照 Messenger、Viking、
  Cassini 与哈勃空间望远镜的真彩照片调整。

## 署名（CC BY 4.0 要求，分发本项目时必须保留）

> Solar System textures by Solar System Scope (https://www.solarsystemscope.com/),
> based on NASA elevation and imagery data. Licensed under CC BY 4.0.

## 清单

| 文件 | 用途 |
|---|---|
| `2k_sun.jpg` | 太阳光球底色（与 `sun_surface.gdshader` 的程序化对流叠加） |
| `2k_mercury.jpg` | 水星 |
| `2k_venus_atmosphere.jpg` | 金星（**用大气而非表面**：可见光下看到的就是硫酸云顶） |
| `2k_venus_surface.jpg` | 金星表面（麦哲伦号雷达测高，当前未使用，留作备选） |
| `2k_earth_daymap.jpg` | 地球昼面 |
| `2k_earth_nightmap.jpg` | 地球夜面城市灯光 |
| `2k_earth_clouds.jpg` | 地球云层 |
| `2k_moon.jpg` | 月球 |
| `2k_mars.jpg` | 火星 |
| `2k_jupiter.jpg` | 木星 |
| `2k_saturn.jpg` | 土星 |
| `2k_saturn_ring_alpha.png` | 土星环**沿半径的色彩**（不取 alpha，见下） |
| `2k_uranus.jpg` | 天王星 |
| `2k_neptune.jpg` | 海王星 |
| `2k_stars_milky_way.jpg` | 银河全天图 2K（备选，当前用 8K） |
| `8k_stars_milky_way.jpg` | 天穹 |

## 两条必须知道的约定

**1. 土星环只取颜色，不取 alpha。** 环带边界与不透明度来自
`internal/bodies` 的实测数据（C/B/A 环与卡西尼、恩克、基勒缝的真实 km
边界），那是本项目的真相源。贴图的 alpha 是第三方的美术再加工，混用等于
让同一个量有两个来源。已验证两者径向跨度一致：贴图 alpha 在 u≈0.70 处的
低谷（卡西尼缝）对上按真实数据算的 0.691。

**2. 这套图没有木卫一/二/三/四、土卫六、天卫五、海卫一。** 这七颗仍走
`planet.gdshader` 的程序化分支，所以那些分支不能删。

## 银河贴图的坐标系是实测确定的

Solar System Scope 没有说明 `stars_milky_way` 用的是哪个坐标系。实测结论：
**银道坐标**，`u = 0.5 - l/360`，`v = 0.5 + b/180`（v=0 是**南**银极）。
判据是大/小麦哲伦云的落点亮度差了一个数量级。完整推导见
`godot/shaders/sky.gdshader`，正确性由 `--skytest` 守住。
