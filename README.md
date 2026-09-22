# Codex Quota Menu Bar

一个 macOS 13+ 的原生 SwiftUI 菜单栏工具。它没有 Dock 图标和常驻主窗口；菜单栏显示剩余额度和重置倒计时，点击可查看详情。

这是社区维护的非官方项目，与 OpenAI 无隶属关系。

## 使用前准备

- macOS 13 或更新版本。
- 已安装并登录的 Codex CLI，用于读取本机账号额度。
- 从源码构建需要完整的 Xcode；仓库已包含 Xcode 工程，XcodeGen 仅在重新生成工程时需要。

## 下载安装

从 [GitHub Releases](https://github.com/xixiba-ai/codex-quota-menubar/releases) 下载通用 DMG，支持 Apple Silicon 和 Intel Mac。打开磁盘映像后，将 **Codex Quota.app** 拖入 **Applications** 文件夹。

当前安装包为预览版，**没有 Apple Developer ID 签名、未经过 Apple 公证**，首次打开可能被 macOS 拦截。安装步骤、系统提示说明和 SHA-256 校验方法见 [安装说明](docs/INSTALL.md)。首次预览版尚未在所有支持的系统和硬件上验证。

项目结构、启动方式、部署注意事项和维护清单见 [交接文档](docs/HANDOFF.md)。日常验证可直接执行 `./scripts/verify.sh`。

## 新手引导与帮助

首次启动会自动显示帮助窗口，关闭后不再自动弹出；可随时从菜单栏的“新手引导与帮助…”重新打开。

- **快速上手**：连接状态与重试、菜单栏数值示例、默认设置说明。
- **功能说明**：额度读取与计划请求的区别、第三方重置概率、会话搜索与清理，可直接打开会话列表。
- **常见问题**：CLI 连接、额度显示、自动刷新、会话查找与帮助入口。

帮助窗口中的“检查连接”只刷新额度数据。计划执行的“自动刷新额度”会发起实际 Codex 请求，可能消耗少量额度，不保证重置额度。

## 构建

该项目使用 XcodeGen 描述工程。若已安装 XcodeGen，执行 `xcodegen generate` 后在 Xcode 中打开 `CodexQuotaMenuBar.xcodeproj`，或执行：

```sh
./scripts/verify.sh

# 生成发布构建
xcodebuild -project CodexQuotaMenuBar.xcodeproj -scheme CodexQuotaMenuBar -configuration Release build
```

## 数据源

默认直接连接本机已登录的 Codex CLI（`codex app-server --stdio`），读取当前额度并在额度变化时更新菜单栏。它不会读取或保存 Codex/ChatGPT 登录凭证；认证仍由 Codex CLI 自身处理。

菜单中的“定位 Codex 会话…”会读取本机已保存的 CLI 和 VS Code 会话。可按标题、首条任务、项目目录或 Session ID 搜索，并可筛选项目与最近 7 天；选中会话后可复制 `codex resume` 续接命令，或在 Finder 打开该会话的项目目录。读取列表不会恢复、中断或修改会话本身。

会话面板还支持单条“终止并删除会话”，以及按最后活跃时间批量删除会话（默认 7 天前）。删除会永久移除会话记录及其派生会话，不能恢复；批量删除会自动跳过仍在运行的会话，并在操作前显示影响数量并要求确认。

该本地 app-server 协议目前标为 experimental；Codex CLI 更新后，应用可能需要随之适配。若本机 CLI 不在默认位置，可配置路径：

```sh
defaults write com.example.CodexQuotaMenuBar codexExecutablePath "$HOME/.local/bin/codex"
```

如需改用你自己的 HTTPS 额度服务，配置 `usageEndpoint` 后会优先使用远程数据源：

配置键：

```sh
defaults write com.example.CodexQuotaMenuBar usageEndpoint 'https://your-authorized-service.example/usage'
defaults write com.example.CodexQuotaMenuBar usageEndpointBearerToken 'YOUR_TOKEN'
```

端点需要返回 ISO-8601 日期：

```json
{
  "shortTerm": { "remainingPercent": 65, "resetsAt": "2026-07-10T17:56:00Z" },
  "longTerm": { "remainingPercent": 55, "resetsAt": "2026-07-13T00:00:00Z" },
  "updatedAt": "2026-07-10T09:00:00Z",
  "sourceDescription": "Codex"
}
```

移除 `usageEndpoint` 会恢复本地 Codex CLI 数据源。应用仍每 60 秒主动校验一次，也会在本地 CLI 推送额度变动时立即更新；详情面板支持手动刷新。

## 第三方重置概率

菜单中的“重置概率预测”是独立开关，默认关闭。开启后会立即请求一次 [willcodexquotareset.com](https://www.willcodexquotareset.com/)，并在每次主动额度刷新时同步更新，包括手动刷新、每 60 秒校验，以及计划触发和额度重置重试。本机 CLI 的被动额度推送不会产生额外请求。

菜单显示服务返回的 48 小时重置概率、数据更新时间和第三方来源。预测请求不携带 Codex 登录凭据，失败也不会影响额度读取；如果已有成功结果，临时失败时会保留并标记为可能过期。关闭开关会取消进行中的预测请求。

## 自动刷新额度

状态栏菜单中的“自动刷新额度”可直接开启或关闭此功能。默认在每天 05:30、10:30、15:30 和 20:30 发起一次最小化的本机 Codex CLI 请求；它与原有的额度读取进程相互独立，不会改变额度读取的 60 秒刷新频率。点击“修改触发时间…”可用 24 小时制设置一个或多个时间，例如 `06:00、12:30、18:00`；保存后会立即重新安排下一次触发。

菜单同时显示当前状态、最近一次触发时间及下一次计划触发时间。应用会保存开关、最近结果和已处理的时间窗口；如果电脑休眠或关机后错过计划点，重新启动或唤醒时只对当前最新的遗漏窗口补偿一次，不会重复执行同一窗口。

调度检查、触发原因、结果和错误会写入 macOS Unified Logging（子系统为 `com.example.CodexQuotaMenuBar`，分类为 `AutoRefresh`），可在“控制台”中查看。

## 许可证

采用 [MIT License](LICENSE)。源码和安装包均附带许可证。
