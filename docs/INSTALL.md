# 安装 Codex Quota 预览版

## 下载与要求

从 [GitHub Releases](https://github.com/xixiba-ai/codex-quota-menubar/releases) 下载 `Codex-Quota-版本号-universal.dmg`。通用安装包同时包含 Apple Silicon 和 Intel 两种架构，最低要求 macOS 13。

使用额度功能前，请先在本机安装并登录 Codex CLI。安装包不包含 Codex CLI，也不包含任何登录凭据。首次公开预览版尚未在所有支持的系统和硬件上验证。

## 安装

1. 如已运行旧版 Codex Quota，先从菜单栏选择“退出”。
2. 打开下载的 DMG，将 **Codex Quota.app** 拖入旁边的 **Applications** 文件夹。
3. 推出磁盘映像，然后从“应用程序”文件夹打开 Codex Quota。
4. 应用位于屏幕顶部菜单栏，没有 Dock 图标；首次启动会显示帮助窗口。

## 首次打开的 macOS 提示

此预览版**没有 Apple Developer ID 签名，也未经过 Apple 公证**。包内的 ad-hoc 签名用于本地完整性校验，不证明开发者身份。macOS 首次打开时可能提示“无法验证开发者”或“Apple 无法检查其是否包含恶意软件”。

确认下载来自本项目并核对文件完整性后，如仍决定使用，可先尝试打开一次应用，再进入 **系统设置 → 隐私与安全性**，找到该应用对应的 **仍要打开 / Open Anyway**，按系统提示确认。部分受组织管理的 Mac 可能不允许此操作。

如系统报告应用已损坏或包含恶意软件，请停止安装，重新核对下载和校验值，并通过项目 Issues 反馈。无需关闭系统整体安全保护。

参见 [Apple：在 Mac 上安全地打开 App](https://support.apple.com/en-gb/102445)。

## 校验下载

每个 Release 附带 `SHA256SUMS.txt`。将 DMG 和该文件放在同一目录，在终端运行：

```sh
shasum -a 256 Codex-Quota-*-universal.dmg
```

将输出与 `SHA256SUMS.txt` 内同名 DMG 对应的值比较。如果已下载 Release 的全部附件，也可以运行 `shasum -a 256 -c SHA256SUMS.txt` 一次性检查。

## 默认行为与隐私

- 默认通过本机已登录的 Codex CLI 读取额度；账号认证由 CLI 处理。
- “自动刷新额度”和“重置概率预测”默认关闭。前者开启后会发起实际 Codex 请求，可能消耗少量额度；后者开启后会访问 willcodexquotareset.com，第三方服务会接收网络请求的一般信息，例如 IP 地址。
- 会话列表在本机显示会话标题、任务预览及项目路径。截图或提交反馈前，请隐去这些信息。
- 会话删除是永久操作；请阅读应用中的确认提示。

## 许可与反馈

本项目采用 **MIT License**，完整许可证同时包含在磁盘映像根目录及应用资源目录中。使用、修改或再分发时请保留版权声明及许可证。

源码：https://github.com/xixiba-ai/codex-quota-menubar

问题反馈：https://github.com/xixiba-ai/codex-quota-menubar/issues
