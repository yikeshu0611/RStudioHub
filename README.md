# RStudioHub

macOS 上的 RStudio 多实例管理工具。在 Dock 保留一个 **RStudioHub** 图标，统一管理多个 RStudio 窗口，并隐藏各 RStudio 实例在 Dock 上的图标。

## 为什么需要 RStudioHub？

在 macOS 上，每开一个 RStudio 就会在 Dock 多一个图标，切换实例不方便。RStudioHub 提供：

- **Dock 统一入口**：只保留 Hub 图标，RStudio 实例隐藏在后台
- **实例列表**：查看、切换、关闭各个 RStudio 进程
- **历史项目 / 历史文件**：快速重新打开最近用过的项目和脚本
- **一键新建**：新建 R 会话、新建 Rproj 项目

## 主要功能

| 操作 | 说明 |
|------|------|
| **左键点击 Dock 图标** | 聚焦最近使用的 RStudio；若无运行中的实例则自动新建 |
| **右键 Dock 图标** | 打开完整功能菜单 |
| **全局快捷键** | 弹出图形菜单（可在菜单内设置） |
| **实例列表** | 点击名称切换实例，点击右侧 ✕ 关闭 |
| **历史项目** | 左键：关闭当前 RStudio 后打开；右键 ↗：新窗口打开 |
| **历史文件** | 悬停显示完整路径，点击打开文件 |
| **新建 R** | 启动新的 RStudio 实例并自动置前 |
| **新建 Rproj** | 通过 RStudio 命令面板打开「Create a New Project」 |
| **Tools 菜单** | 顶部菜单栏：Browse Addins、快捷键、代码片段、Global Options |
| **检查更新** | 顶部菜单栏 **RStudioHub → 更新** |

## 安装

1. 前往 [Releases](https://github.com/yikeshu0611/RStudioHub/releases) 下载最新 `RStudioHub-x.x.xx.dmg`
2. 打开 DMG，将 **RStudioHub** 拖入「应用程序」文件夹
3. 首次启动时授予 **辅助功能** 权限（用于列出和切换 RStudio 窗口）

要求：

- macOS 12.0 或更高版本
- RStudio 安装在 `/Applications/RStudio.app`

## 使用提示

- **通过 Hub 新建 RStudio**（菜单中的「新建 R」），新实例会自动注入 Dock 隐藏组件，体验最佳
- 若 Dock 中仍出现 RStudio 图标，请用 Hub 的「新建 R」重新打开实例
- 左键点击 Hub 不会弹出菜单，只会聚焦 RStudio；菜单请用 **右键** 或 **快捷键**
- 日志位置：`~/Library/Application Support/RStudioHub/logs/`

## 从源码构建

```bash
cd RStudioHub
./build.sh
open build/RStudioHub.app
```

## 已知限制

- 无法将多个 RStudio Dock 图标完全合并为一个（macOS 无公开 API）
- RStudio 使用 Accessory 策略隐藏 Dock 时，顶部菜单栏在使用 RStudio 时应正常显示
- 历史文件路径依赖 RStudio 的 `file_mru` 列表

## 许可证

Copyright © 2026 ZhangJing. All rights reserved.
