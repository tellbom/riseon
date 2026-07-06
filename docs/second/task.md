# task.md — 本地 iPhone 个股问答 App 开发任务分解

> 配套 `plan.md`。任务按阶段编排，每个任务给出**验证点**。
> 图例：`[ ]` 待办 · `[~]` 进行中 · `[x]` 完成。
> 纪律：网络 I/O 只允许出现在 `QuoteProvider` 与 `LLMService`；`Analytics/` 保持纯函数可单测；不机械翻译 pandas，需按 Swift 重写并对拍数值。

> **v2 已裁决（详见 `plan.md` §0.5）**：
> 1. 买卖点由 **LLM** 生成，端上不做规则买卖点；规则引擎只算**支撑/阻力位**；`stop_loss` 可回退 `support_levels[0]`。→ S7 已重写。
> 2. RSI 统一 **Wilder's EMA**（`stock_analyzer.py` 口径），禁用 `technical_indicators.py` 的简单均值 RSI。→ S6.1 已修订。
> 3. 代码归一化**新建独立函数**，**不复用 `StockSymbol.swift`**。→ S2.3 已重写。
> 4. MVP **跳过成交量叠加**，仅叠加价格，并写 ContextPack warning。→ S5.2 已修订。
> 5. `support_levels` 有**三个**来源（MA5/MA10/MA20，`stock_analyzer.py:461/468/472`），**MA20 分支无 2% 容忍度限制**，只要 `price>=MA20` 即无条件加入——不要只做 MA5/MA10。→ S7.3 已修订。
> 6. `TechnicalIndicators`（S6，`min_periods=1`）与 `RuleScoreEngine`（S7，满窗口+MA60兜底MA20）的 MA 计算**口径不同，禁止共享实现**。RSI 不属于这种情况——两边都只用 Wilder 一种实现，S6/S7 可以共用同一份 Wilder RSI 代码，不需要（也不应该）像 MA 那样分别造两份。→ S6.1 已修订，`TechnicalIndicators.rsiWilder` 是唯一的 RSI 实现。
> 7. 实时覆盖当日日线只处理"已有行覆盖"分支；"当日行尚未出现→追加虚拟行"分支 **MVP 阶段不实现**（需先实测腾讯接口盘中行为），改为写 `intraday_bar_not_yet_available` warning。→ S5.2/S8.2 已修订。

---

## S0 — 代码理解与迁移边界确认 `[x]` 已完成

- [x] **0.1 通读并确认能力来源定位**（对照 `plan.md` §2）：`analysis_service.py`、`core/pipeline.py`、`schemas/analysis_context_pack.py`、`services/analysis_context_builder.py`、`stock_analyzer.py`、`technical_indicators.py`、`factors/quant_factor_context.py`、`llm/*`。
  → 验证：产出一页"可迁移/降级/不迁移"清单，逐条附文件路径，与 `plan.md` §8 一致。 **交付：`S0_能力迁移评估清单.md`。**
- [x] **0.2 锁定端上唯一数据源**：确认腾讯实时（`qt.gtimg.cn`）与日线（`web.ifzq.gtimg.cn/appstock/app/fqkline/get`，`qfq`）字段，与现有 Swift `TencentQuoteProvider`/`TencentMinuteProvider` 对齐。
  → 验证：写下日线返回 `qfqday` 的字段序（date/open/close/high/low/volume/amount），并确认成交量单位（手→股 ×100，见 `tencent_fetcher._lots_to_shares`）。
- [x] **0.3 明确降级块**：新闻/资金流/基本面/筹码/融资在 MVP 一律 `not_supported`；`ChipDistribution` 端上源标注"无法验证"。
  → 验证：文档化降级矩阵，评审通过后再开工。

---

## S1 — iPhone App 基础工程搭建 `[x]` 已完成（含 v2 复审修正）

- [x] **1.1 在现有 RiseOn 工程内新增模块分组**：`Workspace/ Analytics/ Context/ QA/ UI/`（见 `plan.md` §13），不改动现有自选股/Watch 代码。
  → 验证：空实现可编译；现有自选股/行情功能不回归。
- [x] **1.2 复用共享层**：直接依赖现有 `Shared_Models_WatchlistItem.swift`、`Shared_Persistence_WatchlistStore.swift`、`Shared_QuoteProvider_*`。
  → 验证：Home 列表能读出现有自选股。

> S1 交付的占位文件中，`StockWorkspace`/`ContextPack`/`ChatSession`/`RuleScoreEngine` 相关文件已在本轮 S2 开发中就地替换/更新为真实实现或修订后的占位说明（不再单独提交 S1 补丁，见 S2 各任务的"S1 占位文件更新"说明）。

---

## S2 — StockWorkspace 数据模型设计 `[x]` 已完成

- [x] **2.1 定义 `StockWorkspace`**（`code/name/market` + 状态机 `uninitialized/initializing/ready/stale/partial/failed(step)`）。
  → 验证：状态流转单测覆盖所有合法转移。
- [x] **2.2 定义持有物结构**：`ContextPack`、`RuleScore`、`ChatSession`、`meta(snapshotDate, source, quality)`。
  → 验证：`Codable` 往返序列化单测通过。
  → 说明：本任务只定义"持有物"的最小骨架（能挂在 `StockWorkspace` 上、能序列化），不预先实现 S7/S8/S11 才该定义的字段细节（如 `ContextPack.blocks`、`RuleScore` 的枚举分解、`ChatSession` 的摘要压缩）——避免抢跑后续任务。
- [x] **2.3 新建独立代码归一化函数 `ACodeResolver`（不复用 `StockSymbol.swift`）**：镜像 Python `is_bse_code` + `tencent_fetcher._to_tencent_symbol` 语义——
  - BSE 优先：`92/43/81/82/83/87/88` 开头且**非 `900` 开头** → `bj`；
  - 否则 `6/5/9` 开头 → `sh`（注意 `900xxx` 沪 B 股走此分支 → `sh`）；
  - 其余（`0/3` 等）→ `sz`。
  → 验证：`600519→sh600519`、`000001→sz000001`、`300059→sz300059`、`900xxx→sh900xxx`（B股非 bj）、`5xxxxx/9xxxxx→sh`、`920xxx→bj920xxx`、`43xxxx→bj`；并与现有 `StockSymbol.swift`（仅 0/3/4/6/8）差异有回归用例。
  → 说明：S1.1 禁止改动自选股/Watch 代码，故本函数独立存在于 `Workspace/ACodeResolver`，不改 `StockSymbol.swift`。

---

## S3 — 本地存储设计 `[x]` 已完成

- [x] **3.1 实现 `WorkspaceStore`**：每股一份独立记录/文件持久化（隔离），支持增删查、原子写。
  → 验证：建两只股票→互不干扰→重启后仍在。
- [x] **3.2 Key 安全存储**：LLM API Key 存 Keychain（非 UserDefaults）。
  → 验证：卸载/重装后 Key 行为符合预期；日志不打印 Key。

---

## S4 — 股票初始化任务队列 `[x]` 已完成

- [x] **4.1 实现 `InitializationQueue`（actor）**：串行调度 + 并发上限（2–3），任务模型 `InitTask{code, step, retries, status}`。
  → 验证：批量入队 5 只，观测并发不超上限、按序完成。
- [x] **4.2 断点续跑与恢复**：持久化队列状态；App 重启后恢复未完成任务。
  → 验证：初始化中途杀进程→重启→从中断步继续。
- [x] **4.3 失败退避**：单步失败指数退避重试（上限），超限置 `failed(step)`。
  → 验证：模拟网络失败→重试→最终可手动重试成功。

> 范围说明：`InitializationQueue` 只管调度/并发/重试退避/断点恢复，不认识 `StockWorkspace`/
> `ContextPack`，Step A-E 的真实业务逻辑（S5-S8）通过可注入的 `StepExecutor` 接入；真实
> executor 落地时由它自己负责通过 `WorkspaceStore` 读写对应的 `StockWorkspace.state`。

---

## S5 — 日线与行情数据获取 `[x]` 已完成

- [x] **5.1 新增日线 Provider**：在 `TencentMinuteProvider` 同源基础上实现日线（`param={sym},day,{start},{end},{lookback},qfq`），GBK 无关（JSON）。
  → 验证：`600519` 拉到近 120+ 根日线，字段与单位正确（量×100）。
- [x] **5.2 实时覆盖（仅价格，跳过成交量；不追加虚拟行，§0.5-7）**：用现有 `TencentQuoteProvider` 覆盖当日最新根日线的 `close`（及可选 open/high/low）；**不叠加成交量**——`Quote.swift` 无整笔成交量字段、`TencentQuoteProvider` 未解析成交量（仅盘口档位量）。在 ContextPack `warnings` 写入 `intraday_volume_overlay_skipped`。
  **若日线接口当日尚未推送最新一根K线**（即最后一行日期 < 今天，对应 Python `_augment_historical_with_realtime` 的"追加虚拟行"分支）：MVP 阶段**不追加虚拟行**，`daily_bars`/`technical` 继续使用最近一个交易日收盘价，仅 `quote` 块单独展示实时价；在 `warnings` 追加 `intraday_bar_not_yet_available`。追加虚拟行留作 Phase 2 候选项，需先用真机/浏览器实测腾讯日线接口盘中是否已推送当日K线，再决定是否实现（§0.5-7）。
  → 验证：盘中最后一根日线 close 被实时价覆盖；该根 volume 保持日线原值（不被实时覆盖）；非交易时段跳过覆盖；若当日日线行尚不存在，daily_bars/technical 保持昨收，`quote` 块显示实时价，Pack warnings 含 `intraday_bar_not_yet_available`；Pack warnings 含 `intraday_volume_overlay_skipped`。
  → 未来可选（非 MVP）：在 `TencentQuoteProvider` 增解成交量字段并扩展 `Quote`，再启用成交量叠加；实测腾讯接口盘中行为后再决定是否实现追加虚拟行分支。
- [x] **5.3 首连重试**：沿用 `fetchWithRetry`（1s + 单次重试）经验。
  → 验证：首次冷启动拉数不因首连延迟失败。

> 范围说明：
> - `TencentDailyProvider`（S5.1）收 `fullSymbol: String`，不是 `StockSymbol`——避免重新引入
>   `ACodeResolver`（§0.5-3）本来要绕开的 0/3/4/6/8 限制。调用方用 `ACodeResolver.fullSymbol(for:)`
>   解析后传入。
> - S5.2 的覆盖逻辑（`RealtimeOverlay`）是纯函数，产出 `warnings: [String]`，还不是真正写进
>   `ContextPack`（那是 S8.2 的事，`ContextPack.warnings` 字段目前还不存在）。两个 warning key
>   字面量已经提前放进 `ContextPackWarningKey`，S8 落地时直接引用，不会两边各写一份不一致的字符串。
> - S5.1"拉到近 120+ 根日线"这半句验证点是真机/联网验证，本环境没有 `web.ifzq.gtimg.cn` 的网络
>   访问权限，只做了 fixture 级别的解析单测（字段序、量×100、防御式解析），真实拉取需要在 Xcode
>   里手动跑一次确认。

---

## S6 — 轻量因子/指标计算（Analytics，纯函数） `[x]` 已完成

- [x] **6.1 移植技术指标**：等价重写 MA5/10/20/60、MACD(12/26/9)、KDJ(9/3/3)、BOLL(20,2) 采用 `technical_indicators.py` 口径（`calculate_ma` 用 `min_periods=1`，不足周期也出值）；**RSI(6/12/24) 必须采用 `stock_analyzer.py::_calculate_rsi` 的 Wilder's EMA 口径**（`ewm(alpha=1/period, adjust=False)`），**禁用** `technical_indicators.py` 的简单 `rolling().mean()` RSI（§0.5-2；评分 S7 依赖此口径）。**`TechnicalIndicators`（本任务）与 `RuleScoreEngine`（S7.2）的 MA 计算禁止共享实现**：`RuleScoreEngine` 的 MA5/10/20/60 必须走 `stock_analyzer.py::_calculate_mas` 的满窗口口径（`rolling(window=period)`，不足周期为 NaN；MA60 数据<60根时退化为 MA20），与本任务的 `min_periods=1` 口径分别独立实现（§0.5-6）。**RSI 不需要分别实现**——两边都只用 Wilder 一种公式，S7 直接复用本任务的 `rsiWilder` 即可。
  → 验证：MA/MACD/KDJ/BOLL 与 `technical_indicators.py` 逐值对拍（误差<1e-6）；**RSI 与 `stock_analyzer.py::_calculate_rsi` 逐值对拍**（用同段日线，确认与简单均值口径出值不同）；构造 <60 根日线用例，确认 `TechnicalIndicators` 与 `RuleScoreEngine` 的 MA60 分别按各自口径出值且不同。**交付：所有对拍数值来自真实运行 pandas 生成的参考值（本环境有 pandas/numpy），非手算估计。**
- [x] **6.2 移植信号提取**：等价重写 `get_latest_signals`（金叉/死叉/超买超卖/均线多头等）。
  → 验证：构造用例覆盖每个布尔信号的真/假分支。
- [x] **6.3 因子窗口（technical）**：按 `quant_factor_context` 的窗口 `1/3/5/10/20`、计算窗口 120，产出窗口收益/区间位置。
  → 验证：与 Python `_period_return/_range_position` 对拍。

> 范围说明：
> - S6.1 的"MA60 分别按各自口径出值且不同"这条验证点目前只做了一半——`TechnicalIndicators` 自己
>   的 `<60` 根用例已覆盖；`RuleScoreEngine` 那一侧的 MA60（满窗口+退化到MA20）要等 S7 落地才能
>   真正对比出"不同"，S6 阶段只能先确认 `TechnicalIndicators` 自身行为正确。
> - RSI 口径的"不用分别实现"这条结论是本轮开发时发现的既有文档措辞不够精确（`plan.md`/`task.md`
>   原来写"与 RSI 分歧同理"，容易让人以为 RSI 也要拆两份），已经在 `plan.md` §0.5-6 和这里一并
>   修订，不是新裁决，是把已有裁决说清楚。

---

## S7 — 策略评分引擎（RuleScoreEngine，纯函数）

- [ ] **7.1 移植枚举**：`TrendStatus/VolumeStatus/BuySignal/MACDStatus/RSIStatus`（保留中文语义标签）。
  → 验证：枚举齐全，与 `stock_analyzer.py` 一致。
- [ ] **7.2 移植评分**：权重 **趋势30/乖离20/量能15/支撑10/MACD15/RSI10**，输出 `signal_score(0-100)`。
  → 验证：对若干真实日线，Swift 评分与 Python `_generate_signal` 一致（容忍阈值边界）。
- [ ] **7.3 支撑/阻力位（替代原"买卖点"任务，§0.5-1）**：移植 `TrendAnalyzer._analyze_support_resistance` 的完整 `support_levels`/`resistance_levels` 逻辑（`stock_analyzer.py:448-479`），包含**全部三个支撑位来源**（§0.5-5，不要漏掉第三个）：
  - MA5 支撑（461行）：`|price-MA5|/MA5 <= 2%` 且 `price>=MA5` 时加入；
  - MA10 支撑（468行）：`|price-MA10|/MA10 <= 2%` 且 `price>=MA10` 时加入（去重）；
  - **MA20 支撑（472行，容易漏掉）**：只要 `price>=MA20` 就无条件加入，**没有 2% 容忍度限制**；
  - 阻力位（477行）：近 20 日最高价，且 `recent_high > price` 时加入。
  写入 ContextPack `levels` 块，供 LLM 生成买卖点参考。**本任务不产出 `ideal_buy/secondary_buy/take_profit`**。
  → 验证：多头/空头/盘整各一例，`support_levels`（含全部三个来源）与阻力位与 Python `TrendAnalyzer` 一致；`support_levels[0]` 可作为 `stop_loss` 确定性回退值备用。
- [ ] **7.4 买卖点归属声明（不实现规则）**：`ideal_buy/secondary_buy/stop_loss/take_profit` 属 `dashboard.battle_plan.sniper_points`，由 **LLM 生成**（见 S9/S10）。端上仅保留 `stop_loss ← support_levels[0]` 的确定性回退（当 LLM 缺该字段时）。
  → 验证：代码中无端上规则买卖点实现；LLM 缺 `stop_loss` 时回退逻辑有单测。

---

## S8 — ContextPack 构建

- [ ] **8.1 移植 Pack 结构**：`ContextPack/Block/Item` + `ContextFieldStatus(available/missing/not_supported/fallback/stale/estimated/partial/fetch_failed)`（对标 `analysis_context_pack.py`）。
  → 验证：序列化字段名与状态枚举与 Python 侧一致。
- [ ] **8.2 实现 `ContextPackBuilder`**：`quote/daily_bars/technical/factors/levels` 置 available/partial（`levels`=S7.3 支撑/阻力位），`chip/fundamentals/news/capital_flow/events` 置 `not_supported`；若跳过成交量叠加则 `warnings` 追加 `intraday_volume_overlay_skipped`；若当日日线行尚未推送则追加 `intraday_bar_not_yet_available`（§0.5-4/§0.5-7）。
  → 验证：无源块状态正确；技术块携带指标与评分摘要；`levels` 块含支撑/阻力位（三个来源都在）；成交量跳过、当日行缺失两种 warning 分别有对应用例。
- [ ] **8.3 数据质量打分**：按端上权重（technical/quote/daily_bars 为主）算 `overall_score/level/block_scores/limitations`（参照 `analysis_context_builder`）。
  → 验证：缺块越多分越低；level 落在 good/usable/limited/poor。

---

## S9 — PromptBuilder

- [ ] **9.1 组装 Prompt**：输入 `ContextPack(含 levels 块) + RuleScore + MarketStrategyBlueprint(静态文本) + 历史 + 问题` → `(system, user)`。Prompt 明确要求 **LLM 结合 `levels` 支撑/阻力位与技术面输出 `sniper_points`（ideal_buy/secondary_buy/stop_loss/take_profit）**（§0.5-1）。
  → 验证：缺失块（新闻/基本面）在 Prompt 中被显式标注为"本地不支持"；Prompt 含要求 LLM 产出 sniper_points 的指令。
- [ ] **9.2 System 口径**：只基于给定数据回答、不臆造行情/新闻、声明数据时效（参照 `chat_context.SUMMARY_SYSTEM_PROMPT` 精神）。
  → 验证：注入"无新闻"场景，LLM 不虚构新闻（人工抽检）。

---

## S10 — LLMService

- [ ] **10.1 抽象协议**：`func generate(system:String, user:String) async throws -> String`（对齐 `GenerationBackend.generate` 最小子集）。
  → 验证：协议可注入 Mock，便于单测。
- [ ] **10.2 云端直连实现**：用户自带 Key（Keychain），直连所选云 API；结构化错误（超时/鉴权/空输出）参照 `GenerationErrorCode`。
  → 验证：真机一次成功问答；断网/错 Key 给出清晰错误态。

---

## S11 — 个股隔离问答历史

- [ ] **11.1 每股独立会话**：`ChatSession` 消息数组随 Workspace 持久化，禁止跨股读取。
  → 验证：A 股会话不出现在 B 股上下文（代码级断言 + UI 验证）。
- [ ] **11.2 超长处理**：MVP 先按 token 预算截断；预留 5 段式摘要压缩接口（`chat_context` 思路）。
  → 验证：长会话不超模型上下文；摘要接口有占位实现。

---

## S12 — 手动刷新与数据过期评估

- [ ] **12.1 单股刷新**：重跑 Step A–F，更新快照时间与 Pack。
  → 验证：刷新后数值与快照时间更新。
- [ ] **12.2 过期评估**：快照日期 < 最近交易日或超阈值→置 `stale` 并提示。
  → 验证：伪造旧快照→UI 出现"数据过期，建议刷新"。

---

## S13 — 初始化进度显示

- [ ] **13.1 进度 UI**：分步展示 A–F（拉日线/指标/评分/打包），单步失败可重试。
  → 验证：真机观测进度推进；单步失败可点重试恢复。

---

## S14 — 通知与灵动岛增强

- [ ] **14.1 本地通知**：初始化完成/失败发本地通知。
  → 验证：后台完成时收到通知。
- [ ] **14.2 灵动岛 Live Activity**：显示初始化进度（**仅展示**，非后台计算容器）。
  → 验证：灵动岛显示进度；不承诺后台持续拉数（对照 `plan.md` §12 边界）。

---

## S15 — 错误处理、降级与恢复

- [ ] **15.1 分块降级**：任一数据步失败→对应块置 `fetch_failed/not_supported`，不阻塞 ready。
  → 验证：断网初始化仍能进入"部分就绪"，问答可用且如实声明缺失。
- [ ] **15.2 队列恢复**：见 4.2/4.3，端到端联调。
  → 验证：多股批量初始化中断→恢复→全部完成或明确失败可重试。

---

## S16 — MVP 验收标准

- [ ] **16.1** 从自选股一键建 Workspace，分步初始化并进度可视化，单步可重试。
- [ ] **16.2** 端上算出指标与规则评分（0-100）与支撑/阻力位，且与 Python 对拍一致（买卖点由 LLM 生成，见 §0.5-1）。
- [ ] **16.3** 生成 ContextPack：技术面 available、`levels` available、其余 `not_supported`，含数据质量分。
- [ ] **16.4** 每股独立问答，Prompt 如实声明数据边界，历史严格隔离。
- [ ] **16.5** LLM 直连云端（自带 Key，Keychain），成功完成一次真机问答，且能结合 `levels` 产出 sniper_points。
- [ ] **16.6** 手动刷新 + 过期告警可用；串行/受限并发队列可恢复。
- [ ] **16.7** 通知/灵动岛显示进度，且未被用作后台计算容器。

---

## 明确不做（Out of Scope）

- 交易/下单/持仓/账户。
- 全市场横截面选股（`quant_platform/selection/*`）、端上训练/回测/评估（`quant_platform/training,evaluation/*`）。
- 端上新闻/情报/联网搜索（`search_service.py`、`intelligence_service.py`）。
- 服务端依赖、内网穿透、常开机器、后台长时计算。
- 端上规则买卖点算法（`ideal_buy/secondary_buy/take_profit`，由 LLM 生成，见 §0.5-1）。
- 实时成交量叠加、日线"追加虚拟行"分支（MVP 阶段，见 §0.5-4/§0.5-7）。

> 若某任务看似需要以上任一项，**先停下确认**再实现。
