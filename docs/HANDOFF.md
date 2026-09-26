# Codex Quota Menu Bar — 交接文档

[English](HANDOFF.en.md) | **简体中文**

## 先做这三件事

```sh
cd /path/to/codex-quota-menubar
./scripts/verify.sh
xcodebuild -project CodexQuotaMenuBar.xcodeproj -scheme CodexQuotaMenuBar -configuration Debug -derivedDataPath /private/tmp/CodexQuotaMenuBarDerivedData build
open "/private/tmp/CodexQuotaMenuBarDerivedData/Build/Products/Debug/Codex Quota.app"
```

上述验证会运行单元测试。应用是 macOS 13+ 的菜单栏程序，没有 Dock 图标或主窗口。

## 目录与职责

| 路径 | 内容 |
| --- | --- |
| `Sources/CodexQuotaMenuBarApp.swift` | AppKit 菜单栏入口、菜单交互、触发时间编辑弹窗。 |
| `Sources/QuotaStore.swift` | 额度刷新状态、60 秒轮询与手动刷新。 |
| `Sources/UsageDataSource.swift` | 本机 Codex CLI app-server 与可选 HTTPS 数据源。 |
| `Sources/QuotaViews.swift` | 菜单栏额度展示。 |
| `Sources/QuotaHelpView.swift` | 首次启动引导、功能说明、常见问题与连接检查。 |
| `Sources/AutoRefreshScheduler.swift` | 自动刷新排程、持久化、休眠/时钟变更补偿。 |
| `Sources/CodexCLIRefreshTrigger.swift` | 计划到点时调用本机 Codex CLI。 |
| `Sources/CodexTerminalResumeLauncher.swift` | 将选中会话交给终端续接、安全引用 shell 参数及管理私有临时脚本。 |
| `Sources/ResetForecast.swift` | 可选第三方重置概率请求、校验、合并并发与独立持久化开关。 |
| `Tests/AutoRefreshSchedulerTests.swift` | 排程、开关、补偿、自定义时间与旧配置兼容测试。 |
| `Resources/` | App Icon 与状态栏图标资源。 |
| `distribution/releases/` | 按版本保存的 DMG、安装说明、许可证和校验文件；不进入 Git。 |
| `scripts/package-release.sh` | 从已提交源码在独立目录构建、检查并制作预览版 DMG。 |
| `project.yml` | XcodeGen 工程描述；修改目标、文件归属或构建设置时优先改这里。 |
| `CodexQuotaMenuBar.xcodeproj/` | 已生成的 Xcode 工程。修改 `project.yml` 后执行 `xcodegen generate` 更新。 |

## 运行架构

```text
菜单栏 UI
 ├─ QuotaStore ──> UsageDataSource ──> Codex CLI app-server / HTTPS endpoint
 └─ AutoRefreshScheduler ──> CodexCLIRefreshTrigger ──> 本机 Codex CLI
```

- 额度读取每 60 秒校验一次，并监听本机 CLI 推送。
- 第三方重置概率默认关闭；开启时跟随主动额度读取和计划 CLI 触发，被动推送不触发请求。
- 自动刷新与额度读取独立：仅在用户设定的时间点执行最小化 CLI 请求。
- 自动刷新默认时间为 `05:30, 10:30, 15:30, 20:30`，可通过菜单的“修改触发时间…”改为一个或多个 24 小时制时间。
- 开关、触发时间、上次结果和已处理窗口保存在 `UserDefaults` 的 `autoRefreshState` 键下。
- 休眠、启动、系统时钟变更后，只补偿当前最新的一个漏掉窗口；同一窗口不会重复触发。

## 常用操作

### 帮助窗口

首次启动显示“新手引导与帮助”，展示后通过 `UserDefaults` 的 `hasShownGettingStarted` 保存已展示状态。关闭窗口不退出应用；菜单入口可重新打开同一个窗口，不重复创建。帮助页复用 `QuotaStore` 显示连接状态和手动刷新，不修改自动刷新或预测开关。

验证时检查首次显示、关闭后从菜单重开、再次启动不自动弹出，以及三个帮助主题、连接失败提示和打开会话列表。若需要重新验证首次启动，可退出应用后执行 `defaults delete com.example.CodexQuotaMenuBar hasShownGettingStarted`。

### 测试与构建

```sh
./scripts/verify.sh

xcodebuild -project CodexQuotaMenuBar.xcodeproj \
  -scheme CodexQuotaMenuBar \
  -configuration Release \
  -derivedDataPath /private/tmp/CodexQuotaMenuBarDerivedData \
  build
```

### 本机安装最新构建

先退出正在运行的应用，然后将构建产物复制到 `/Applications`：

```sh
pkill -f "Codex Quota.app/Contents/MacOS/Codex Quota" || true
ditto "/private/tmp/CodexQuotaMenuBarDerivedData/Build/Products/Debug/Codex Quota.app" "/Applications/Codex Quota.app"
open "/Applications/Codex Quota.app"
```

旧工作区的 `distribution/staging/Codex Quota.app` 也可能被 LaunchServices 发现。它与 `/Applications/Codex Quota.app` 共用 bundle ID；启动时使用明确的绝对路径。正式打包使用下方的隔离流程，不复用旧暂存目录。

### 制作预览版安装包

先完成测试并提交工作区改动，再运行：

```sh
./scripts/package-release.sh 1.0.0-preview.4 4
```

脚本要求完整 Xcode；需要选择特定 Xcode 时，通过 `DEVELOPER_DIR` 指定。它导出当前提交，在独立临时目录构建 arm64 / x86_64 Release，校验版本与包内容，加入 MIT 许可证和安装说明，并生成 DMG 和 SHA-256 校验文件。已有同版本输出时会停止，避免覆盖。

产物位于 `distribution/releases/版本号/`；构建日志与暂存目录仅保留在本地临时目录。后续新安装包会同时附带 `INSTALL.md` 和 `INSTALL.en.md`。发布前仍应挂载 DMG、检查应用签名和架构、进行启动检查及隐私复核。只将该版本目录中的发行附件上传到对应源码提交的 GitHub Release，并勾选预览版。发布后，用同一份已校验安装包更新本机 `/Applications/Codex Quota.app`，保留旧版备份与现有设置，并检查安装后的构建号和实际运行路径。

已有的 `v1.0.0-preview.1` 安装包附带最初的中文安装说明。文档翻译不会改变已发布二进制及校验值，当前英文安装说明可在线查看。

### 修改数据源

默认读取本机已登录 Codex CLI。可选配置：

```sh
defaults write com.example.CodexQuotaMenuBar codexExecutablePath "$HOME/.local/bin/codex"
defaults write com.example.CodexQuotaMenuBar usageEndpoint 'https://your-authorized-service.example/usage'
defaults write com.example.CodexQuotaMenuBar usageEndpointBearerToken 'YOUR_TOKEN'
```

移除 `usageEndpoint` 后恢复本机 CLI 数据源。不要把令牌写入源码、README 或提交历史。

### 查看自动刷新日志

CLI 错误详情按私密字段记录，避免在默认日志中暴露本机路径或其他敏感信息。

在“控制台”中筛选 subsystem `com.example.CodexQuotaMenuBar`、category `AutoRefresh`，或使用：

```sh
log show --last 1h --predicate 'subsystem == "com.example.CodexQuotaMenuBar" AND category == "AutoRefresh"'
```

## 改动自动刷新时的检查清单

1. 保持 `AutoRefreshState` 的旧配置解码兼容；新增持久化字段必须有默认值。
2. 修改时间计算后，覆盖跨日、相同时间点、休眠唤醒和时钟变更场景。
3. 改动菜单后同时确认“开启自动刷新额度”和“关闭自动刷新额度”两种文本与状态。
4. 执行 `./scripts/verify.sh`。
5. 若部署给本机使用，复制到 `/Applications` 后以绝对路径重新启动。

## 当前已知边界

- 本机 Codex app-server 协议是 experimental；CLI 升级后如无法读取额度，优先检查 `UsageDataSource.swift` 的协议适配。
- 工程当前关闭开发者代码签名（见 `project.yml`）；打包脚本仅添加 ad-hoc 完整性签名。面向正式分发的 Developer ID 签名和 Apple 公证尚未配置。
- 旧的 `distribution/Codex Quota.dmg` 和 `distribution/staging/` 不属于当前发行流程，不应上传。

## 本地化维护

`Sources/Localization.swift` 读取 `appLanguage` 偏好（`system`、`zh-Hans` 或 `en`），并加载 `Resources/en.lproj/Localizable.strings` 和 `Resources/zh-Hans.lproj/Localizable.strings`。跟随系统时按首选语言顺序选择支持的语言，默认回退为英文。切换后菜单、已打开窗口、日期和应用自身的错误提示即时更新，不重启应用，也不发起 Codex 请求。用户会话内容和外部服务消息不翻译。

应用文案使用 `L10n.tr`。插值内容转为编号占位符，两种语言须保留一致的占位符。不要翻译用户内容或改变已持久化的枚举值。`LocalizationTests` 覆盖资源一致性、插值安全、语言偏好持久化、额度错误和时间输入；测试启动不连接真实 CLI 或恢复调度任务。

触发时间仅接受 `HH:mm` 24 小时制，以英文逗号分隔，可在每个时间前后留空白。中英文显示均使用 `, `。旧计划按数值分钟保存，无需迁移。

## 在终端续接会话

会话面板的“在终端续接”使用与额度读取相同的 Codex 可执行文件定位逻辑。它校验项目目录与可执行文件，生成私有、可执行的 `.command` 文件，通过 `NSWorkspace` 明确交给 `com.apple.Terminal` 打开。脚本会在进入项目目录并执行 `codex resume -- SESSION_ID` 前删除自身，不需要 AppleScript 自动化权限。小型复制按钮保留手动操作入口。

验证时使用注入的打开器或本地虚构 CLI，不要仅为验证按钮而打开真实会话。覆盖空格、引号、中文、shell 特殊字符、以连字符开头的 ID、目录或 CLI 缺失、打开失败与临时文件清理。会话 ID 和项目路径不得混入发行附件或准备公开的诊断材料。

## 数据新鲜度、执行结果与更新

`QuotaStore.freshness` 将失败后保留的数据和超过 180 秒的数据标为过期，重试期间保持过期状态，实时更新会清除旧错误。原生菜单每 30 秒以及打开时重新渲染。调度状态仅保留最近一次执行结果、稳定的原因枚举和固定失败类别；新增字段需兼容旧设置。载入时将未完成的执行标为中断。

`AppUpdateChecker` 按 SemVer 比较版本，过滤草稿，并从固定仓库地址生成发布链接。预览版包含预览更新，正式版只接收正式更新。仅手动检查，不会自动安装。打包脚本注入并校验 `CodexQuotaReleaseVersion`，发布时同步项目内的版本默认值。

文档图片由可选的 `DocumentationSnapshots` 测试使用虚构数据渲染真实 SwiftUI 视图。运行 `scripts/verify.sh` 时通过 `TEST_RUNNER_QUOTA_DOC_SNAPSHOTS` 指定绝对输出目录；普通测试跳过导出。不得捕捉真实会话、凭据、个人路径或无关桌面内容。

渲染后执行 `python3 scripts/make-doc-tour.py build/documentation-snapshots docs/images`（需要 Pillow），复制四张公开界面图并生成双语 GIF。提交前逐张检查。
