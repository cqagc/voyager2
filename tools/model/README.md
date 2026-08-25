# Voyager 视觉模型语义拆分

NASA 官方 `Voyager.glb` 只按贴图组织对象，没有 RTG、天线、桁架等语义层级。本工具采用“自动切分与量化，再由人审阅映射”的两阶段流程，不自动猜测零件身份。

## 阶段一：分析

在仓库根目录运行：

```sh
/opt/homebrew/bin/blender --background --python tools/model/split.py -- analyze
```

脚本会按几何松散块拆分 `assets/source/Voyager.glb`，输出：

- `assets/generated/parts_analysis.json`：机器可读的包围盒、质心、网格规模、表面积、包围盒体积、最长轴、扁平度和材质数据。
- `assets/generated/parts_analysis.md`：按包围盒体积降序排列的人类可读表格。

脚本也会临时解压 `Voyager_printable.zip`，测量其中 13 个真实航天器参考件。`pins.stl` 是打印装配榫钉，`stand.stl` 是展示底座，两者不属于真实 Voyager，因此明确排除。打印版与视觉版可能使用不同尺度和朝向；报告只给出整体尺寸比例和中心偏移，不自动对齐。

几何连通性只能回答“哪些三角面连在一起”，不能可靠回答“哪一块是 RTG”。打印版命名也偏向打印装配，不能直接替代人工判断。因此分析阶段只输出客观测量，不产生任何 ComponentID 猜测。

## 人工填写映射

根据分析报告和可视检查编辑 `tools/model/mapping.json` 的 `parts`。键可写稳定名称 `part_0000`，也可写数字索引 `0`；值是 ComponentID：

```json
{
  "parts": {
    "part_0000": "Bus",
    "part_0001": {
      "component": "Instrument_CRS",
      "parent": "ScanPlatform"
    }
  }
}
```

多个松散块可以映射到同一个 ComponentID，`apply` 会保留其原始 UV 和材质并归并。所有松散块都必须映射。`Instrument_*` 可用 `parent` 指定 `ScanPlatform` 或 `ScienceBoom`；`RTG_1`、`RTG_2`、`RTG_3` 固定挂在 `RTGBoom` 下。

`Bus`、`HighGainAntenna` 等 15 个字符串严格取自 `internal/domain/domain.go` 的 `AllComponents`。它们是 Blender 导出节点、Godot 场景树和后端组件状态之间的三方契约，一个字符都不能改变。缺失或出现未知 ComponentID 时，脚本会列出差异并终止。

## 阶段二：应用并导出

人工完成映射后运行：

```sh
/opt/homebrew/bin/blender --background --python tools/model/split.py -- apply
```

输出为 `assets/generated/Voyager2_rigged.glb`。根节点名为 `Voyager2`，导出使用 glTF 二进制格式、Y-up、应用变换，并保留源模型材质与贴图。脚本最后会在终端打印完整节点树。
