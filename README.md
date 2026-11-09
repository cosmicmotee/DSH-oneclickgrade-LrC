# 一键调色 · Lightroom Classic 插件

版本 1.2.1 ｜ 适配 Lightroom Classic 12.4（SDK 12） ｜ 本项目由 DeepSeek 辅助生成

选中一张或多张照片，一键完成：

1. **基础面板**：高光 -100、阴影 +100、白色色阶 -100、黑色色阶 +100（照片保持彩色）
2. **色调曲线**：点曲线；按亮度直方图的分位（默认两端各裁 0.2%）确定端点——右上输入 = 高光分位 + 5（输出 255），左下输入 = 阴影分位 - 5（输出 0）
3. 全程不切换处理方式：黑白只是**分析模型**，不会真的把照片转成黑白再转回来

## 安装

把 `OneClickGrade.lrplugin` 整个文件夹复制到：

```
C:\Users\<用户名>\AppData\Roaming\Adobe\Lightroom\Modules\
```

重启 Lightroom Classic。菜单「文件 > 增效工具额外功能」或「增效工具」下会出现：

- 一键调色
- 一键调色·设置…
- 一键调色·诊断…

也可以在「文件 > 增效工具管理器」里点「添加」，选择插件文件夹。

## 使用

1. 在 Library 或 Develop 模块选中一张或多张照片
2. 菜单执行「一键调色」
3. 进度条走完两步后照片即完成调色，历史记录中会留下两条（一键调色·基础 / 一键调色·曲线）

## 设置

「一键调色 · 设置…」可修改：

| 设置 | 默认值 | 说明 |
| --- | --- | --- |
| 剪切判定模式 | auto | auto=导出 TIFF 自动求端点；fixed=用固定端点 |
| 端点统计 | percentile | percentile=按直方图分位；extremes=绝对极值 |
| 两端各裁掉 | 0.2% | percentile 模式下每端丢弃的像素比例，调大可更贴手工 |
| 端点边距 margin | 5 | 端点外扩的输入值 |
| 固定高光端点 | 240 | fixed 模式使用 |
| 固定阴影端点 | 15 | fixed 模式使用 |
| 分析长边 longEdge | 800 | 导出临时 TIFF 的尺寸（800 足够做直方图，渲染更快） |
| 缓存目录 tempDir | `D:\cache\LrC` | 临时 TIFF 存放位置 |
| 用后删除 | 开 | 流程结束后递归删除临时目录 |
| 历史记录名 | 一键调色 | 写入 develop history 的名称前缀 |

## 原理

1. 通过 `photo:applyDevelopSettings` 写入四项基础参数（照片保持彩色）
2. 用 `LrExportSession` 导出 8bit 无压缩 TIFF（sRGB、长边 800），纯 Lua 解析 TIFF 像素，按**亮度（luma）**统计最小/最大值——这等价于从黑白视角看这张基础调整后的照片
3. 端点：右上输入 = max + 5（≤255），左下输入 = min − 5（≥0）；中间保持线性（若原曲线是自定义曲线，则保留其中间点并按新区间重映射）
4. 写入 `ToneCurvePV2012` + `ToneCurveName2012 = "Custom"`
5. 删除临时文件（不涉及黑白/彩色切换）

## 已知限制

- Lightroom SDK 的 `showClipping()` 只能打开剪切显示，**无法查询「是否剪切」**，所以用「导出后亮度极值」作为剪切点的近似（这也是 auto 模式的含义）。
- 插件无法嵌入 Develop 模块右侧面板，只能通过菜单 / 对话框 / 预设工作。
- 导出 TIFF 始终是 RGB（黑白照片也会按 RGB 渲染），解析时按亮度处理。
- 每张照片需要额外导出一次 TIFF（实测约 0.3 秒/张，5 张全程约 2 秒）；临时文件默认写入 `D:\cache\LrC` 并在结束后删除。
- LrC 13.0+ 的点曲线改用 `ExtendedToneCurvePV2012`，本插件按 12.4 的 `ToneCurvePV2012` 编写，13+ 上需要小改（诊断菜单可协助确认键名）。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `Info.lua` | 插件清单与菜单注册 |
| `Grade.lua` | 主命令：基础影调 → 分析曲线 |
| `Core.lua` | develop settings、导出、临时目录等公共逻辑 |
| `Curve.lua` | 曲线构造与端点计算 |
| `TiffReader.lua` | 纯 Lua baseline TIFF 解析（8/16bit，灰度/RGB） |
| `Settings.lua` | 设置持久化（LrPrefs） |
| `SettingsDialog.lua` | 设置对话框 |
| `Diagnose.lua` | 诊断：打印 develop settings 与建议曲线 |

## 卸载

删除 `Modules\OneClickGrade.lrplugin` 文件夹，重启 Lightroom。
