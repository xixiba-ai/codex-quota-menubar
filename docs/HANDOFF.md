# Codex Quota Menu Bar — 交接文档

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
| `Sources/ResetForecast.swift` | 可选第三方重置概率请求、校验、合并并发与独立持久化开关。 |
| `Tests/AutoRefreshSchedulerTests.swift` | 排程、开关、补偿、自定义时间与旧配置兼容测试。 |
| `Resources/` | App Icon 与状态栏图标资源。 |
| `distribution/` | 已发布的 DMG；`staging/` 是可再生成的打包临时目录。 |
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
- 自动刷新默认时间为 `05:30、10:30、15:30、20:30`，可通过菜单的“修改触发时间…”改为一个或多个 24 小时制时间。
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

工作区的 `distribution/staging/Codex Quota.app` 也可能被 LaunchServices 发现。它与 `/Applications/Codex Quota.app` 共用 bundle ID；调试或交付前应同步更新它，且启动时使用明确的绝对路径，不要只按 bundle ID 或应用名查找。

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
- 工程当前关闭代码签名（见 `project.yml`）；正式分发前需要补充签名、公证和可重复的 DMG 打包流程。
- `distribution/Codex Quota.dmg` 是现有发布物；它不会随源码构建自动更新，发布前需单独重新制作并验证。
