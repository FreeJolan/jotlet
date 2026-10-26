# 0.2.1 测试记录

2026-10-13，当前 Apple Silicon Mac 构建。所有窗口与键盘操作均在 Tart 客机执行，启动使用 `--no-graphics --no-clipboard --no-audio`，控制台为后台的 Codex 内置浏览器与本机回环地址上的 noVNC。测试结束后客机已关闭。

## 自动检查

- 28 项单元测试通过，日志在 `.build/tart-setup/unit-021.log`。
- 47 项原生检查通过，覆盖编辑器、系统剪贴板、图片、撤销和保存。
- 44 项窗口检查通过，日志及截图在 `.build/tart-runs/run.fxug2U/artifacts`，启动日志在 `.build/tart-setup/release-021.log`。

新增检查包括设置打开、隐藏 Dock 与恢复、偏好保存、置顶便签上方的设置面板、菜单栏模式的便签编辑、整张便签收起、最近收起恢复、连续两次快捷键操作、原尺寸和置顶保留、旧版折叠状态迁移，以及窗口循环和反向循环。截图生成计入检查数量，外观仍需逐张查看。

## 虚拟机桌面的实际操作

手动结果在 `.build/tart-runs/run.hHiUOX/artifacts`。

正常模式下，`⌘Tab` 显示 Jotlet；开启隐藏 Dock 后，Dock 中没有 Jotlet，应用切换列表也不再列出它。截图分别为 `manual-dock-shown-switcher.png` 和 `manual-dock-hidden-switcher.png`。

隐藏 Dock 后，系统原本的同应用窗口循环没有继续工作。应用增加了便签窗口的快捷键处理，实际发送 `⌘` + 反引号后，三张便签按 A → B → C → A 切换，窗口的 key 状态记录在 `manual-cycle.json`。设置面板与浮动列表不参与便签循环；只循环当前桌面的可见、未最小化便签。

实际发送 `⌥⌘K` 后，一张便签完全隐藏，另外三张保持可见。再次发送后，刚收起的便签重新成为 key 窗口，记录在 `manual-hide-restore.json`。

通过菜单栏右键打开设置，并实际切换 Dock 开关。正常退出后重启，隐藏偏好仍保留，便签仍可编辑。`⌘,` 可以打开设置，浅色与深色控件已查看，深色截图为 `manual-settings-dark.png`。

## 边界

隐藏 Dock 使用 macOS 的 accessory 应用模式，应用自己的顶端菜单也会消失。列表、工具栏和菜单栏图标继续提供入口，剪贴板格式沿用已有实现。

Tart 实验性 VNC 的修饰键映射存在差异，键盘组合通过控制台按钮发送完整修饰键。构建使用独立路径并复制到客机，避免共享目录缓存旧文件。

检查环境为 macOS 26.6.2（25G83），一块虚拟显示器。没有把这些结果扩展为所有 macOS 版本、多显示器、全屏或跨桌面组合均已验证。
