# S16 交付物 — MVP 验收标准评估

> 对应 `task.md` S16。这份文档逐条核对 7 项验收标准，如实标注"已满足/部分满足/仍有缺口"，
> 不为了好看而夸大完成度。S16 第一轮补了一块之前所有阶段都在往后推的拼接层——
> `WorkspaceInitializationCoordinator`（把 S5-S8 的纯函数接成 `InitializationQueue` 的
> `StepExecutor`）和 `WorkspaceChatService`（把 `PromptBuilder`+`LLMService`+`ChatSession`
> 接成真正的"问一个问题"），因为没有这两块胶水代码，16.1/16.5 这两条根本无法验证。第二轮
> 又补上了当时发现的两处纯 UI 缺口：`HomeListView` 的"建 Workspace"入口（16.1）和过期告警的
> UI 提示文案（16.6）——`HomeListViewModel` 把这两件事放在了一起做，因为它们共用同一段
> "为每只自选股加载 Workspace 状态"的逻辑。

---

## 16.1 — 从自选股一键建 Workspace，分步初始化并进度可视化，单步可重试

**状态：已满足，包括 UI 入口。**

- `WorkspaceInitializationCoordinator.startInitialization(code:name:market:queue:)`（S16）是
  "一键建 Workspace"的执行逻辑：创建/复用 `StockWorkspace`、转到 `.initializing`、存盘、丢进
  `InitializationQueue`。
- **UI 入口已补上**：`HomeListView` 现在点一下某只自选股（`onTapGesture`）就会调用
  `HomeListViewModel.openWorkspace(for:)`，没有 Workspace 就新建，已经有就直接导航——用
  `.navigationDestination(item: $selectedCode)` 跳到 `InitProgressView` 观察进度。行内还有
  状态徽标（未建/初始化中/已就绪/部分就绪/已过期/失败，对应不同图标颜色）。
- 分步初始化：S4 的 `InitializationQueue` + S16 的 `stepExecutor()`。
- 进度可视化：S13 的 `InitProgressView`/`InitProgressViewModel`。
- 单步可重试：S4.3 的 `retry(_:)`，S13 的重试按钮。
- 端到端单测（`HomeListViewModelTests`）覆盖了：点击新建、市场无法识别时的错误提示、点击已有
  Workspace 时只导航不重建。

## 16.2 — 端上算出指标与规则评分（0-100）与支撑/阻力位，且与 Python 对拍一致（买卖点由 LLM 生成）

**状态：已满足。**

- `TechnicalIndicators`（S6）、`RuleScoreEngine`（S7）都用真实 pandas 计算结果核对过，多个场景
  （牛/熊/盘整/<60根/边界值）逐字段对拍，误差 <1e-6。
- 支撑/阻力位是 `RuleScoreEngine` 的一部分，同样对拍过，含 MA20 无容忍度、MA10 去重但 MA20
  不去重这些容易出错的细节。
- 买卖点确认没有端上规则实现（S7.4），只有 `stop_loss` 的确定性回退，符合 §0.5-1 的裁决。

## 16.3 — 生成 ContextPack：技术面 available、`levels` available、其余 not_supported，含数据质量分

**状态：已满足。**

- `ContextPackBuilder`（S8，S15.1 扩展了 fetch_failed 区分）在 S16 的端到端测试里被真实的
  `WorkspaceInitializationCoordinator` 调用验证过：全部数据可用时 `technical`/`levels` 确实是
  `available`，`chip/fundamentals/news/capital_flow/events` 确实是 `not_supported`，
  `data_quality.level` 落在 good/usable/limited/poor 四档之内，权重与 Python
  `_build_data_quality` 核对过。
- 断网/半断网场景下（S16 新增的端到端测试）验证了 `fetch_failed` 会正确级联到 `technical`/
  `factors`/`levels`，且 `overall_score` 仍然是一个有定义的数字，不是 nil 或崩溃。

## 16.4 — 每股独立问答，Prompt 如实声明数据边界，历史严格隔离

**状态：已满足。**

- `ChatSession` 隔离（S11）：`StockWorkspace.appendChatMessage`/`replaceChatSession` 强制
  code 一致性检查，端到端测试验证了两只股票的历史存盘/读回/渲染进 Prompt 都不会串。
- `PromptBuilder`（S9，S15.1 扩展）如实声明数据边界：`not_supported`/`fetch_failed`/`partial`/
  `stale` 等 8 种状态现在都有对应中文标签，不是只有"本地不支持"一种有特殊处理。
- `WorkspaceChatService.ask(...)`（S16 新增）把这些串成一个真正能调用的"问一个问题"入口，
  而不是"这几个类型各自都对，但没人真的把它们接在一起过"。

## 16.5 — LLM 直连云端（自带 Key，Keychain），成功完成一次真机问答，且能结合 levels 产出 sniper_points

**状态：代码链路已打通；"真机一次成功问答"本身需要你在 Xcode 里配真实 Key 验证，这个环境做不到。**

- `LLMAPIKeyStore`（S3.2，Keychain）→ `OpenAICompatibleLLMService`（S10.2）→ `WorkspaceChatService`
  （S16）这条链已经用 mock LLMService 端到端跑通：question 和 answer 都正确记录、
  workspace-not-ready 和 LLM 报错两种失败路径都有明确、可测试的行为。
- system prompt 里已经要求 LLM 结合 `levels` 块产出 `ideal_buy/secondary_buy/stop_loss/
  take_profit`（S9），但"LLM 真的照做了"这件事本身取决于具体接的模型有多听话，没法在没有真实
  API Key 的环境里验证——这条和"真机问答"一样，需要你实际跑一次。
- **诚实提醒**：`OpenAICompatibleLLMService` 走的是 OpenAI 兼容格式，不是 Anthropic 原生格式
  （S10 交付时已经标注过这个决策，这里重复提醒一下，因为它直接决定 16.5 能不能跑通——如果你
  准备用的云端服务不支持这个格式，需要先加一个新的 `LLMService` 实现）。

## 16.6 — 手动刷新 + 过期告警可用；串行/受限并发队列可恢复

**状态：已满足，包括 UI 提示文案。**

- 手动刷新（S12.1）：`InitializationQueue.refresh(_:)` + `StockWorkspace.applyRefreshedPack`；
  S16 的 `WorkspaceInitializationCoordinator` 让"刷新"用的是和"首次初始化"完全同一套
  `stepExecutor`，没有两份不同的管道代码需要分别维护。
- **过期告警 UI 提示文案已补上**：`HomeListViewModel.refreshWorkspaceStates()` 在 Home 页出现
  时对每只已建 Workspace 的自选股调用 `evaluateStaleness`，一旦判定过期就落盘并反映到
  `HomeListView` 的行内——显示"数据过期，建议刷新"字样（橙色 Label + 徽标），并提供滑动刷新的
  操作入口（调用 `refreshWorkspace(for:)`）。这是"过期"判断第一次真正被什么东西调用，之前
  `StalenessEvaluator`/`evaluateStaleness` 只在单测里被手动调用过。
- 队列可恢复（S4.2/S4.3/S15.2）：多股批量场景下的中断-恢复-重试端到端测试已覆盖，包括"恢复
  过程仍遵守并发上限""结果确实落盘不是只在内存里"这两个更细的点。

## 16.7 — 通知/灵动岛显示进度，且未被用作后台计算容器

**状态：本地通知已满足；灵动岛代码存在但置信度低，需要你在 Xcode 里重新验证。**

- 本地通知（S14.1）：`WorkspaceNotificationCenter`，文案纯函数有单测，实际系统调用需要真机。
- 灵动岛（S14.2）：三个文件都写了，但这个沙盒完全没有 ActivityKit/WidgetKit，**从未被编译过**，
  而且 Widget UI 那个文件需要一个新建的 Widget Extension target（纯 Xcode 工程配置，不是加
  源文件能解决的）。这是目前为止风险最高的一块交付，S14 交付时已经用整段文字强调过，这里再次
  提醒，因为它直接影响 16.7 这条验收标准。
- 未被用作后台计算容器：`InitProgressViewModel`/`WorkspaceLiveActivityController` 都只是镜像
  `InitializationQueue` 已有的状态，没有第二套后台计算逻辑，符合 plan.md §12 的边界。

---

## 汇总：仍未覆盖的具体缺口

原来列的 5 点里，前两点（Home 页建 Workspace 入口、过期告警 UI 文案）**这轮已经补上**
（`HomeListView`/`HomeListViewModel` + 对应单测）。剩下 3 点性质不变：

1. ~~Home 页缺"建 Workspace"入口~~ → **已补上**。
2. ~~过期告警 UI 提示文案没做~~ → **已补上**。
3. **灵动岛需要 Xcode 里新建 Widget Extension target**（16.7）——工程配置，非代码问题，本轮未处理。
4. **"真机一次成功问答"和"LLM 确实照 Prompt 指令产出了 sniper_points"** 需要真实 API Key +
   真机验证（16.5）——这条无论如何都不可能在没有真实 LLM 访问权限的环境里自动化验证，性质上
   和"真机观测通知/灵动岛"是同一类，不算是遗漏，是这类验证点本身的固有边界。
5. **交易日历不存在**——`StalenessEvaluator`/`RealtimeOverlay`/`WorkspaceInitializationCoordinator`
   都需要外部传入"是否交易日"，这个日历服务本身在 task.md 里从未被列为任何一个独立任务，目前用的
   是"周一到周五"的粗略近似，法定节假日会判断错误。`HomeListViewModel` 的
   `mostRecentTradingDay()` 用的是同一个简化。

3/4/5 里，3 需要你在 Xcode 侧完成，4 是这类验证点的固有边界，5 是一个已知但刻意搁置的简化，
均不在本轮范围内解决。
