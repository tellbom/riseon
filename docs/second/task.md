# task.md — 本地 iPhone 个股问答 App 开发任务分解

> 配套 `plan.md`。任务按阶段编排，每个任务给出**验证点**。
> 图例：`[ ]` 待办 · `[~]` 进行中 · `[x]` 完成。
> 纪律：网络 I/O 只允许出现在 `QuoteProvider` 与 `LLMService`；`Analytics/` 保持纯函数可单测；不机械翻译 pandas，需按 Swift 重写并对拍数值。

---

## S0 — 代码理解与迁移边界确认

- [ ] **0.1 通读并确认能力来源定位**（对照 `plan.md` §2）：`analysis_service.py`、`core/pipeline.py`、`schemas/analysis_context_pack.py`、`services/analysis_context_builder.py`、`stock_analyzer.py`、`technical_indicators.py`、`factors/quant_factor_context.py`、`llm/*`。
  → 验证：产出一页"可迁移/降级/不迁移"清单，逐条附文件路径，与 `plan.md` §8 一致。
- [ ] **0.2 锁定端上唯一数据源**：确认腾讯实时（`qt.gtimg.cn`）与日线（`web.ifzq.gtimg.cn/appstock/app/fqkline/get`，`qfq`）字段，与现有 Swift `TencentQuoteProvider`/`TencentMinuteProvider` 对齐。
  → 验证：写下日线返回 `qfqday` 的字段序（date/open/close/high/low/volume/amount），并确认成交量单位（手→股 ×100，见 `tencent_fetcher._lots_to_shares`）。
- [ ] **0.3 明确降级块**：新闻/资金流/基本面/筹码/融资在 MVP 一律 `not_supported`；`ChipDistribution` 端上源标注"无法验证"。
  → 验证：文档化降级矩阵，评审通过后再开工。

---

## S1 — iPhone App 基础工程搭建

- [ ] **1.1 在现有 RiseOn 工程内新增模块分组**：`Workspace/ Analytics/ Context/ QA/ UI/`（见 `plan.md` §13），不改动现有自选股/Watch 代码。
  → 验证：空实现可编译；现有自选股/行情功能不回归。
- [ ] **1.2 复用共享层**：直接依赖现有 `Shared_Models_WatchlistItem.swift`、`Shared_Persistence_WatchlistStore.swift`、`Shared_QuoteProvider_*`。
  → 验证：Home 列表能读出现有自选股。

---

## S2 — StockWorkspace 数据模型设计

- [ ] **2.1 定义 `StockWorkspace`**（`code/name/market` + 状态机 `uninitialized/initializing/ready/stale/partial/failed(step)`）。
  → 验证：状态流转单测覆盖所有合法转移。
- [ ] **2.2 定义持有物结构**：`ContextPack`、`RuleScore`、`ChatSession`、`meta(snapshotDate, source, quality)`。
  → 验证：`Codable` 往返序列化单测通过。
- [ ] **2.3 定义 `code` 归一化**：对齐 Python `canonical_stock_code/normalize_stock_code/is_bse_code` 语义（沪 6/5/9→sh，京→bj，其余→sz）。
  → 验证：`600519→sh600519`、`000001→sz000001`、`300059→sz300059`、`8/4…→bj…`。

---

## S3 — 本地存储设计

- [ ] **3.1 实现 `WorkspaceStore`**：每股一份独立记录/文件持久化（隔离），支持增删查、原子写。
  → 验证：建两只股票→互不干扰→重启后仍在。
- [ ] **3.2 Key 安全存储**：LLM API Key 存 Keychain（非 UserDefaults）。
  → 验证：卸载/重装后 Key 行为符合预期；日志不打印 Key。

---

## S4 — 股票初始化任务队列

- [ ] **4.1 实现 `InitializationQueue`（actor）**：串行调度 + 并发上限（2–3），任务模型 `InitTask{code, step, retries, status}`。
  → 验证：批量入队 5 只，观测并发不超上限、按序完成。
- [ ] **4.2 断点续跑与恢复**：持久化队列状态；App 重启后恢复未完成任务。
  → 验证：初始化中途杀进程→重启→从中断步继续。
- [ ] **4.3 失败退避**：单步失败指数退避重试（上限），超限置 `failed(step)`。
  → 验证：模拟网络失败→重试→最终可手动重试成功。

---

## S5 — 日线与行情数据获取

- [ ] **5.1 新增日线 Provider**：在 `TencentMinuteProvider` 同源基础上实现日线（`param={sym},day,{start},{end},{lookback},qfq`），GBK 无关（JSON）。
  → 验证：`600519` 拉到近 120+ 根日线，字段与单位正确（量×100）。
- [ ] **5.2 实时覆盖**：用现有 `TencentQuoteProvider` 覆盖当日最新价（对应 pipeline 的 realtime overlay）。
  → 验证：盘中最后一根日线 close 被实时价覆盖；非交易时段跳过覆盖。
- [ ] **5.3 首连重试**：沿用 `fetchWithRetry`（1s + 单次重试）经验。
  → 验证：首次冷启动拉数不因首连延迟失败。

---

## S6 — 轻量因子/指标计算（Analytics，纯函数）

- [ ] **6.1 移植技术指标**：等价重写 `technical_indicators.py`（MA5/10/20/60、MACD(12/26/9)、KDJ(9/3/3)、RSI(6/12/24)、BOLL(20,2)）。
  → 验证：与 Python 同一段日线输入**逐值对拍**，误差 < 1e-6（EMA/rolling 口径一致）。
- [ ] **6.2 移植信号提取**：等价重写 `get_latest_signals`（金叉/死叉/超买超卖/均线多头等）。
  → 验证：构造用例覆盖每个布尔信号的真/假分支。
- [ ] **6.3 因子窗口（technical）**：按 `quant_factor_context` 的窗口 `1/3/5/10/20`、计算窗口 120，产出窗口收益/区间位置。
  → 验证：与 Python `_period_return/_range_position` 对拍。

---

## S7 — 策略评分引擎（RuleScoreEngine，纯函数）

- [ ] **7.1 移植枚举**：`TrendStatus/VolumeStatus/BuySignal/MACDStatus/RSIStatus`（保留中文语义标签）。
  → 验证：枚举齐全，与 `stock_analyzer.py` 一致。
- [ ] **7.2 移植评分**：权重 **趋势30/乖离20/量能15/支撑10/MACD15/RSI10**，输出 `signal_score(0-100)`。
  → 验证：对若干真实日线，Swift 评分与 Python `_generate_signal` 一致（容忍阈值边界）。
- [ ] **7.3 买卖点**：产出 `ideal_buy/secondary_buy/stop_loss/take_profit`（对齐 pipeline sniper points 语义）。
  → 验证：多头/空头/盘整各一例，买卖点方向合理且可复现。

---

## S8 — ContextPack 构建

- [ ] **8.1 移植 Pack 结构**：`ContextPack/Block/Item` + `ContextFieldStatus(available/missing/not_supported/fallback/stale/estimated/partial/fetch_failed)`（对标 `analysis_context_pack.py`）。
  → 验证：序列化字段名与状态枚举与 Python 侧一致。
- [ ] **8.2 实现 `ContextPackBuilder`**：`quote/daily_bars/technical/factors` 置 available/partial，`chip/fundamentals/news/capital_flow/events` 置 `not_supported`。
  → 验证：无源块状态正确；技术块携带指标与评分摘要。
- [ ] **8.3 数据质量打分**：按端上权重（technical/quote/daily_bars 为主）算 `overall_score/level/block_scores/limitations`（参照 `analysis_context_builder`）。
  → 验证：缺块越多分越低；level 落在 good/usable/limited/poor。

---

## S9 — PromptBuilder

- [ ] **9.1 组装 Prompt**：输入 `ContextPack + RuleScore + MarketStrategyBlueprint(静态文本) + 历史 + 问题` → `(system, user)`。
  → 验证：缺失块（新闻/基本面）在 Prompt 中被显式标注为"本地不支持"。
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
- [ ] **16.2** 端上算出指标与规则评分（0-100）与买卖点，且与 Python 对拍一致。
- [ ] **16.3** 生成 ContextPack：技术面 available、其余 `not_supported`，含数据质量分。
- [ ] **16.4** 每股独立问答，Prompt 如实声明数据边界，历史严格隔离。
- [ ] **16.5** LLM 直连云端（自带 Key，Keychain），成功完成一次真机问答。
- [ ] **16.6** 手动刷新 + 过期告警可用；串行/受限并发队列可恢复。
- [ ] **16.7** 通知/灵动岛显示进度，且未被用作后台计算容器。

---

## 明确不做（Out of Scope）

- 交易/下单/持仓/账户。
- 全市场横截面选股（`quant_platform/selection/*`）、端上训练/回测/评估（`quant_platform/training,evaluation/*`）。
- 端上新闻/情报/联网搜索（`search_service.py`、`intelligence_service.py`）。
- 服务端依赖、内网穿透、常开机器、后台长时计算。

> 若某任务看似需要以上任一项，**先停下确认**再实现。
