# Godot 4.7 iOS 图标清单

## 母版

- 来源：`godot/icon.icns` 中的 `icon_512x512@2x.png`。
- 母版真实分辨率：1024×1024。
- 未进行放大；其余尺寸均由该 1024×1024 母版等比例缩小生成。
- `icon_1024x1024.png` 已转换为不含 Alpha 通道的不透明 PNG。

## 导出预设对应关系

| 文件 | 实际尺寸 | Godot iOS 导出预设选项键名 |
| --- | --- | --- |
| `icon_1024x1024.png` | 1024×1024 | `icons/icon_1024x1024`、`icons/app_store_1024x1024` |
| `icon_40x40.png` | 40×40 | `icons/notification_40x40` |
| `icon_58x58.png` | 58×58 | `icons/settings_58x58` |
| `icon_60x60.png` | 60×60 | `icons/notification_60x60` |
| `icon_76x76.png` | 76×76 | `icons/notification_76x76` |
| `icon_80x80.png` | 80×80 | `icons/spotlight_80x80` |
| `icon_87x87.png` | 87×87 | `icons/settings_87x87` |
| `icon_114x114.png` | 114×114 | `icons/notification_114x114` |
| `icon_120x120.png` | 120×120 | `icons/spotlight_120x120`、`icons/iphone_120x120` |
| `icon_128x128.png` | 128×128 | `icons/ios_128x128` |
| `icon_136x136.png` | 136×136 | `icons/ios_136x136` |
| `icon_152x152.png` | 152×152 | `icons/ipad_152x152` |
| `icon_167x167.png` | 167×167 | `icons/ipad_167x167` |
| `icon_180x180.png` | 180×180 | `icons/iphone_180x180` |
| `icon_192x192.png` | 192×192 | `icons/ios_192x192` |

Godot 4.7 还提供带 `_dark` 和 `_tinted` 后缀的可选外观键；现有素材没有对应的深色或着色设计，因此未复制普通图标冒充这些变体。
