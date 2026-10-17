# 字体来源

HUD 的排版直接对齐 Claude Design 的设计稿（`赛博朋克 HUD.dc.html`），稿子里
指定了两款字体，都随仓库带进来，避免在不同机器上退化成系统默认字。

| 文件 | 字体 | 许可 | 用途 |
|---|---|---|---|
| `JetBrainsMono-{Light,Regular,Medium,Bold}.ttf` | JetBrains Mono | **SIL Open Font License 1.1** | 全部数值、代号、英文标签 |
| `NotoSansSC.ttf` | Noto Sans SC（可变字重 VF） | **SIL Open Font License 1.1** | 中文正文，同时作等宽字体的中文回退 |

- JetBrains Mono：https://github.com/JetBrains/JetBrainsMono
  © 2020 The JetBrains Mono Project Authors
- Noto Sans SC：https://github.com/notofonts/noto-cjk
  © 2014-2021 Adobe（Source Han Sans / Noto Sans CJK 项目）

OFL 允许随作品分发与嵌入，要求保留版权与许可声明 —— 本文件即为该声明。

## 两个实现约定

**1. 等宽字体挂了中文回退。** JetBrains Mono 没有汉字，而稿子里大量出现
"20.01 小时"、"OWLT 单程光时" 这种中英混排。`HudTheme.mono()` 给每个
`FontVariation` 设了 `fallbacks = [NotoSansSC]`，否则汉字会掉成方框。

**2. 字间距靠 `FontVariation.spacing_glyph`。** Godot 的 Label 没有
letter-spacing。稿子里的 `letter-spacing: .18em` 换算成
`spacing_glyph = round(字号 × em)`，所以字体资源按 (字号, 字重, 字间距)
三元组缓存 —— 见 `HudTheme.mono()` / `HudTheme.sans()`。

**3. 中文用的是可变字重。** Noto Sans SC 这份是 VF，字重通过
`variation_opentype = {0x77676874: 300/400/700}`（`wght` 轴）取，不用为每档
字重各带一个文件。
