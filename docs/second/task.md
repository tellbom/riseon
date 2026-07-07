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

## S7 — 策略评分引擎（RuleScoreEngine，纯函数） `[x]` 已完成

- [x] **7.1 移植枚举**：`TrendStatus/VolumeStatus/BuySignal/MACDStatus/RSIStatus`（保留中文语义标签）。
  → 验证：枚举齐全，与 `stock_analyzer.py` 一致。
- [x] **7.2 移植评分**：权重 **趋势30/乖离20/量能15/支撑10/MACD15/RSI10**，输出 `signal_score(0-100)`。
  → 验证：对若干真实日线，Swift 评分与 Python `_generate_signal` 一致（容忍阈值边界）。**交付：多头/空头/盘整各一例，逐字段与真实运行 stock_analyzer.py 的输出对拍，全字段一致（不止 signal_score）。**
- [x] **7.3 支撑/阻力位（替代原"买卖点"任务，§0.5-1）**：移植 `TrendAnalyzer._analyze_support_resistance` 的完整 `support_levels`/`resistance_levels` 逻辑（`stock_analyzer.py:448-479`），包含**全部三个支撑位来源**（§0.5-5，不要漏掉第三个）：
  - MA5 支撑（461行）：`|price-MA5|/MA5 <= 2%` 且 `price>=MA5` 时加入；
  - MA10 支撑（468行）：`|price-MA10|/MA10 <= 2%` 且 `price>=MA10` 时加入（去重）；
  - **MA20 支撑（472行，容易漏掉）**：只要 `price>=MA20` 就无条件加入，**没有 2% 容忍度限制**；
  - 阻力位（477行）：近 20 日最高价，且 `recent_high > price` 时加入。
  写入 ContextPack `levels` 块，供 LLM 生成买卖点参考。**本任务不产出 `ideal_buy/secondary_buy/take_profit`**。
  → 验证：多头/空头/盘整各一例，`support_levels`（含全部三个来源）与阻力位与 Python `TrendAnalyzer` 一致；`support_levels[0]` 可作为 `stop_loss` 确定性回退值备用。**另有专门回归用例覆盖 MA20 append 无去重检查这个不对称细节（见 plan.md §0.5-5 补充）。**
- [x] **7.4 买卖点归属声明（不实现规则）**：`ideal_buy/secondary_buy/stop_loss/take_profit` 属 `dashboard.battle_plan.sniper_points`，由 **LLM 生成**（见 S9/S10）。端上仅保留 `stop_loss ← support_levels[0]` 的确定性回退（当 LLM 缺该字段时）。
  → 验证：代码中无端上规则买卖点实现；LLM 缺 `stop_loss` 时回退逻辑有单测。

> 范围说明：
> - `RuleScoreEngine` 的 MACD/RSI 计算直接复用 `TechnicalIndicators.macd`/`TechnicalIndicators.rsiWilder`
>   （两个 Python 源公式完全一致，见 plan.md §0.5-6 补充），只有 MA 是独立实现（满窗口 +
>   MA60 兜底 MA20，与 `TechnicalIndicators` 的 `min_periods=1` 版本分别维护）。
> - S6 遗留的"MA60 在 TechnicalIndicators 与 RuleScoreEngine 两边分别出值且不同"这条验证点，
>   现在 S7 落地后已补full对比单测（同一份 <60 根日线喂给两边，确认数值确实不同）。
> - 对拍方法：本轮没有手算参考值，而是把 `stock_analyzer.py::StockTrendAnalyzer` 原样复制成一个
>   不依赖 `src.config` 的独立脚本（只把 `get_config().bias_threshold` 换成字面量 5.0，其余逻辑
>   逐行未改），在真实 pandas 环境里跑出参考结果；又把 Swift 实现逐行搬成等价 Python 独立验证一遍，
>   两边在牛市/熊市/盘整三个构造用例上逐字段完全一致后才写进 Swift 测试文件。过程中发现最初用等比
>   数列构造的牛市/熊市样例会让"均线间距是否走阔"这个判断落在浮点误差量级的临界点上（pandas 内部
>   rolling 实现和逐点重算的求和顺序不同，可能翻转结果）——这不是逻辑错误，是样例本身脆弱，已换成
>   加速增长/衰减的样例，留出几个百分点的余量。

---

## S8 — ContextPack 构建 `[x]` 已完成

- [x] **8.1 移植 Pack 结构**：`ContextPack/Block/Item` + `ContextFieldStatus(available/missing/not_supported/fallback/stale/estimated/partial/fetch_failed)`（对标 `analysis_context_pack.py`）。
  → 验证：序列化字段名与状态枚举与 Python 侧一致。**交付：新增 `JSONValue` 枚举承接 Python `Any`/`Dict[str,Any]`
  字段（`value`/`metadata`），所有多词字段都手写了 `CodingKeys` 映射到 Python 的 snake_case（`stock_name`/
  `pack_version`/`data_quality`/`fallback_from`/`missing_reason`/`overall_score`/`block_scores`），单测直接
  解出 JSON dict 断言 key 字面量，不是只信任 Codable 往返。不迁移 `phase`/`to_safe_dict`/`model_copy`
  （服务端/多租户概念，端上没有对应场景，见 plan.md §7）。**
- [x] **8.2 实现 `ContextPackBuilder`**：`quote/daily_bars/technical/factors/levels` 置 available/partial（`levels`=S7.3 支撑/阻力位），`chip/fundamentals/news/capital_flow/events` 置 `not_supported`；若跳过成交量叠加则 `warnings` 追加 `intraday_volume_overlay_skipped`；若当日日线行尚未推送则追加 `intraday_bar_not_yet_available`（§0.5-4/§0.5-7）。
  → 验证：无源块状态正确；技术块携带指标与评分摘要；`levels` 块含支撑/阻力位（三个来源都在）；成交量跳过、当日行缺失两种 warning 分别有对应用例。**交付：`technical` 块的"评分摘要"部分门槛对齐 `RuleScoreEngine.minimumBarsRequired`（20根）而不是 `TechnicalIndicators` 自己的 `min_periods=1`——日线够但不到20根时，指标还在但评分摘要不出现，块状态降级为 `partial`。**
- [x] **8.3 数据质量打分**：按端上权重（technical/quote/daily_bars 为主）算 `overall_score/level/block_scores/limitations`（参照 `analysis_context_builder`）。
  → 验证：缺块越多分越低；level 落在 good/usable/limited/poor。**交付：三组场景（全可用/全缺失/部分退化）逐一与 `_build_data_quality` 的真实计算结果核对，含 `round(92.5)=92`（银行家舍入）这类边界值。**

> 范围说明：
> - `warnings` 统一收在 `data_quality.warnings` 里，不在每个 block 里各自重复一份——照抄 Python 侧
>   `_build_data_quality(blocks, warnings=...)` 的做法（block 构建过程中产生的告警汇总传给 data_quality，
>   不是分散存放）。
> - `not_supported` 从不计入 `limitations`——这是预期内的永久降级，不是某次拉取失败，`chip/fundamentals/
>   news` 常年 `not_supported` 也不会占用 `limitations` 的 5 条名额。
> - `portfolio` 块（Python 侧的多股组合上下文）没有迁移——`StockWorkspace` 设计上是单股隔离（plan.md §5），
>   不存在组合场景。

---

## S9 — PromptBuilder `[x]` 已完成

- [x] **9.1 组装 Prompt**：输入 `ContextPack(含 levels 块) + RuleScore + MarketStrategyBlueprint(静态文本) + 历史 + 问题` → `(system, user)`。Prompt 明确要求 **LLM 结合 `levels` 支撑/阻力位与技术面输出 `sniper_points`（ideal_buy/secondary_buy/stop_loss/take_profit）**（§0.5-1）。
  → 验证：缺失块（新闻/基本面）在 Prompt 中被显式标注为"本地不支持"；Prompt 含要求 LLM 产出 sniper_points 的指令。**交付：`ContextPack.blocks` 按固定顺序逐块渲染，`not_supported` 块直接输出"状态：本地不支持"字面文案，单测按具体 block 名逐一断言，不是笼统检查"某处出现过这四个字"。**
- [x] **9.2 System 口径**：只基于给定数据回答、不臆造行情/新闻、声明数据时效（参照 `chat_context.SUMMARY_SYSTEM_PROMPT` 精神）。
  → 验证：注入"无新闻"场景，LLM 不虚构新闻（人工抽检）。**交付：System Prompt 里已包含"不得编造""数据快照时间""数据质量等级""过期"等具体措辞并有单测覆盖；但"LLM 实际执行时确实不会编造新闻"这件事本身要接真实 LLM 才能验证，本环境不具备（这条验证点本来就写明是人工抽检，不是自动化测试）。**

> 范围说明：
> - 买卖点指令放在 system prompt（每次问答都生效的固定行为要求），不是每次现拼进 user prompt。
> - `RuleScore` 除了给 `technical`/`levels` 块提供数值摘要外，`PromptBuilder` 还单独把
>   `signalReasons`/`riskFactors`（`_generate_signal` 产出的中文可读理由）整段附进 Prompt，
>   作为规则引擎评分依据，而不是让 LLM 只看数字自己现编理由。
> - Blueprint 只保留 `principles`/`action_framework`，`dimensions`（涨跌家数/板块轮动这类大盘维度）
>   一个字都没进 Prompt——有专门回归用例确认这一点。

---

## S10 — LLMService `[x]` 已完成

- [x] **10.1 抽象协议**：`func generate(system:String, user:String) async throws -> String`（对齐 `GenerationBackend.generate` 最小子集）。
  → 验证：协议可注入 Mock，便于单测。**交付：单测里直接构造了一个 mock 结构体塞进只认 `LLMService` 协议类型的调用点，证明确实可替换，不是只测"能不能声明一个 mock"。**
- [x] **10.2 云端直连实现**：用户自带 Key（Keychain），直连所选云 API；结构化错误（超时/鉴权/空输出）参照 `GenerationErrorCode`。
  → 验证：真机一次成功问答；断网/错 Key 给出清晰错误态。**交付：状态码→错误映射、响应体解析这两个纯函数逻辑有完整单测；真实网络请求本身没有自动化测试（这个代码库其他联网组件也没有注入 mock URLSession 的先例，保持一致），"真机一次成功问答"这条验证点本身就是要在 Xcode 接上真实 Key 之后手动跑。**

> 范围说明（**连线格式是需要你确认的决策，见 plan.md §9**）：
> - 具体实现 `OpenAICompatibleLLMService` 走的是 OpenAI 兼容的 `/chat/completions` 格式，不是 Anthropic
>   原生 Messages API。这不是 task.md/plan.md 原文规定的，是这轮开发时做的选择——个人使用场景下能接的
>   云端服务大多实现这个格式更方便，`endpoint`/`model` 都可配置，没有锁死具体厂商。如果你想直接对接
>   Anthropic 原生格式，需要另外加一个 `LLMService` 实现，协议本身不用动。
> - `GenerationErrorCode` 里 `COMMAND_NOT_FOUND`/`INTERACTIVE_PROMPT_REQUIRED`/`APPROVAL_REQUIRED`/
>   `LOGIN_REQUIRED`/`UNSUPPORTED_TOOL_CALLING`/`SCHEMA_VALIDATION_FAILED` 这些是本地 CLI 子进程后端
>   才有的失败模式，直连云端 HTTPS API 用不上，没有照搬；换成了直连 HTTP 真实会遇到的网络层失败、
>   429 限流、5xx 服务端错误。

---

## S11 — 个股隔离问答历史 `[x]` 已完成

- [x] **11.1 每股独立会话**：`ChatSession` 消息数组随 Workspace 持久化，禁止跨股读取。
  → 验证：A 股会话不出现在 B 股上下文（代码级断言 + UI 验证）。**交付：`StockWorkspace.appendChatMessage`/`replaceChatSession` 在写入前检查 code 一致性，不一致就抛错（用可测试的抛错代替字面意义的崩溃式 assert）；另有端到端用例，两只股票分别写入历史、存盘、重新读回，断言两边内容互不相交，以及 `PromptBuilder` 只会渲染传给它的那个 workspace 的历史，不会看到另一个。**
- [x] **11.2 超长处理**：MVP 先按 token 预算截断；预留 5 段式摘要压缩接口（`chat_context` 思路）。
  → 验证：长会话不超模型上下文；摘要接口有占位实现。**交付：token 数用 `len(text)/3` 估算（对齐 `chat_context.py` 在没有真实 tokenizer 时的兜底口径），截断策略是先丢最旧的；`ChatHistorySummarizer` 协议 + 5 个中文标题常量（`ChatSummarySection`）已定义，占位实现 `UnimplementedChatHistorySummarizer` 永远抛 `notImplemented`，真正接 LLM 压缩留到以后。**

> 范围说明：
> - "代码级断言"这条验证点用的是可抛出的 `Error`，不是 Swift 字面意义的 `assert()`/`precondition()`——
>   崩溃式断言没法在 XCTest 里干净地断言到，抛错可以，功能上都是"检测到不变量被破坏就立刻失败"，
>   只是失败的呈现方式选了更利于测试和生产环境可恢复的那种。
> - 单条最新消息本身就超过 token 预算时，截断结果是空（整条丢弃，不做部分截断）——这是已知的
>   MVP 简化行为，有专门测试覆盖，不影响当前问题本身（`question` 是 `PromptBuilder` 的独立参数，
>   不会被这个截断逻辑动到）。

---

## S12 — 手动刷新与数据过期评估 `[x]` 已完成

- [x] **12.1 单股刷新**：重跑 Step A–F，更新快照时间与 Pack。
  → 验证：刷新后数值与快照时间更新。**交付：`InitializationQueue.refresh(code)`（强制重跑全部5步，跟只重跑失败那一步的 `retry(_:)` 区分开）+ `StockWorkspace.applyRefreshedPack(...)`（套用新 Pack/评分/快照时间，按 `data_quality.level` 决定落到 `ready` 还是 `partial`）。**
- [x] **12.2 过期评估**：快照日期 < 最近交易日或超阈值→置 `stale` 并提示。
  → 验证：伪造旧快照→UI 出现"数据过期，建议刷新"。**交付：`StalenessEvaluator`（纯函数）+ `StockWorkspace.evaluateStaleness(...)`（`ready`/`partial`→`stale`）。"UI 出现提示"这半句是 S13+ 的事，这轮只做了 UI 应该依据的那个判断逻辑和状态迁移。**

> 范围说明：
> - `InitializationQueue.refresh(code)` 在 code 正处于 active（正在跑）时会抛 `RefreshError.alreadyActive`
>   而不是硬改它的任务列表——直接改会跟正在跑的 pipeline 产生竞态（那个 pipeline 一开始就拿了一份
>   任务快照，之后各自往同一份数据里写，谁的结果最终生效说不清楚）。这不是遗漏，是刻意设计成"重跑
>   中的不能再触发重跑，等它跑完/失败了再说"。
> - `StalenessEvaluator` 不认识交易日历（哪天是交易日）——"最近交易日"是外部传入的参数，跟 S5.2 的
>   `RealtimeOverlay` 让调用方传 `isTradingDay` 是同一个理由（保持纯函数，不在这个类型里塞日历逻辑）。
>   交易日历本身还没有实现，不在 S12 范围内。
> - `refresh()`/`applyRefreshedPack` 之间"真正重新拉数据、算指标、打分、建包"这一整套编排逻辑
>   （把 S5-S8 的纯函数/actor 接成 `InitializationQueue` 的 `StepExecutor`）还没有实现——这是留给
>   以后的编排任务，S12 本身只交付了刷新/过期这两个状态管理动作。

---

## S13 — 初始化进度显示 `[x]` 已完成

- [x] **13.1 进度 UI**：分步展示 A–F（拉日线/指标/评分/打包），单步失败可重试。
  → 验证：真机观测进度推进；单步失败可点重试恢复。**交付：`InitProgressView`（分步展示 5 步状态 + 图标/颜色 + 重试按钮）+ `InitProgressViewModel`（轮询 `InitializationQueue` 驱动）。"真机观测"本身没法在这个环境里做，已经用真实 `InitializationQueue`（配 mock StepExecutor）跑了 ViewModel 的状态管理逻辑：进度推进、失败停住、重试后恢复推进直到再次结束，这几条路径都过了单测。UI 本身的实际渲染效果（图标好不好看、点按反馈够不够清晰）仍然需要你在 Xcode/真机里看一眼。**

> 范围说明：
> - ViewModel 用轮询（250ms 一次）驱动，不是订阅/推送——`InitializationQueue`（S4）目前只有拉取式
>   查询接口，故意没有为了这个 UI 需求反过去改已经测过的队列调度核心。初始化本来就是前台限时操作，
>   轮询几秒钟可以接受，不算权宜之计。
> - `InitProgressViewModel` 只负责"看"队列状态，不碰 `StockWorkspace`/`WorkspaceStore`——跟 S4 自己
>   "队列不认识 workspace"的既有边界一致，"队列结束后怎么更新 workspace 状态"仍然是以后编排任务的事。

---

## S14 — 通知与灵动岛增强 `[x]` 已完成（灵动岛部分风险偏高，见范围说明）

- [x] **14.1 本地通知**：初始化完成/失败发本地通知。
  → 验证：后台完成时收到通知。**交付：`WorkspaceNotificationCenter`，文案拼装（`content(for:name:outcome:)`）是纯函数，单测覆盖了成功/失败每个 step 的措辞；实际调用 `UNUserNotificationCenter` 那部分（权限弹窗、真实送达）需要真机验证，这个环境做不到。**
- [x] **14.2 灵动岛 Live Activity**：显示初始化进度（**仅展示**，非后台计算容器）。
  → 验证：灵动岛显示进度；不承诺后台持续拉数（对照 `plan.md` §12 边界）。**交付：`WorkspaceInitActivityAttributes`（数据模型）+ `WorkspaceLiveActivityController`（start/update/end）+ `WorkspaceInitActivityWidget`（灵动岛/锁屏 UI 草稿）。**

> 范围说明（**灵动岛这部分置信度明显低于其他所有交付，务必在 Xcode 里重新过一遍**）：
> - 这个沙盒完全没有 ActivityKit/WidgetKit（没有 Apple SDK），S14.2 的三个文件从未被编译或交叉验证过，
>   是按现有认知写的初稿，不是像其余 S1-S15 那样经过人工逐行核对或 Python 交叉验证的交付物。
> - `WorkspaceInitActivityWidget.swift` 必须放进一个**新建的 Widget Extension target**（Xcode 里
>   Product ▸ New Target ▸ Widget Extension，勾选"Include Live Activity"），`WorkspaceInitActivityAttributes.swift`
>   需要同时属于主 App target 和这个新 target——这是工程配置，加源文件解决不了，需要你/Codex 在
>   Xcode 里手动建。
> - `WorkspaceLiveActivityController` 复用 `InitProgressViewModel`（S13）已经在跑的轮询，没有另起
>   一套"监视队列"的机制。

---

## S15 — 错误处理、降级与恢复 `[x]` 已完成

- [x] **15.1 分块降级**：任一数据步失败→对应块置 `fetch_failed/not_supported`，不阻塞 ready。
  → 验证：断网初始化仍能进入"部分就绪"，问答可用且如实声明缺失。**交付：`ContextPackBuilder.Inputs` 新增 `quoteFetchFailed`/`dailyBarsFetchFailed` 两个标志，区分"从没试过"（`missing`）和"试了但失败"（`fetch_failed`）；`dailyBarsFetchFailed` 会级联到 `technical`/`factors`/`levels`（根因是网络失败还是数据量不够，如实反映，不笼统合并成 `missing`）。`PromptBuilder` 的状态渲染从"只有 not_supported 有中文标签"扩展成"8 种状态全部都有"，系统提示词的诚实声明规则也从"只提 not_supported"扩展到"任何非 available 状态都要如实告知"。有一条端到端用例：全部拉取失败→质量分 poor→workspace 仍能到 `.partial`（不是卡死）→ Prompt 里能看到"拉取失败"字样。**
- [x] **15.2 队列恢复**：见 4.2/4.3，端到端联调。
  → 验证：多股批量初始化中断→恢复→全部完成或明确失败可重试。**交付：5 只股票混合场景（2只已完成/1只中断在某步/1只已耗尽重试彻底失败/1只从没开始）→ 用真实 `InitializationQueue`+`InitQueueStore` 模拟重启恢复→验证全部有明确结局、已耗尽重试的那只手动重试后能追到成功、恢复过程仍然遵守并发上限、恢复完的最终状态确实落盘（用第二次"重启"验证不是只存在内存里）。**

> 范围说明：
> - S15.1 改的是已有的 `ContextPackBuilder`/`PromptBuilder`（S8/S9 的文件），不是新建文件——新增的
>   两个 flag 都有默认值 `false`，S8 阶段写的旧单测不受影响、行为不变；只有显式传 `true` 才会触发
>   `fetch_failed` 分支。
> - S15.1 顺带把 S9 一处偏窄的实现补全了：之前只有 `not_supported` 状态在 Prompt 里有专门的中文
>   说法，其余状态直接显示英文 `rawValue`（如"partial"）。现在 8 种状态全都有对应中文标签，这不是
>   新裁决，是把"如实声明缺失"这个已有要求做得更完整——S9 那份测试文件里两处断言原来写的是英文
>   状态字符串，这次一并改成了对应中文。

---

## S16 — MVP 验收标准 `[~]` 进行中（见 `S16_MVP验收评估.md` 逐条评估，2 处明确缺口未关闭）

- [x] **16.1** 从自选股一键建 Workspace，分步初始化并进度可视化，单步可重试。**核心逻辑已满足**（新增 `WorkspaceInitializationCoordinator.startInitialization`），**但 `HomeListView` 里"建 Workspace"的按钮/手势和到 `InitProgressView` 的导航还没做**——这是唯一一处纯 UI 交互层缺口，不属于任何已完成 S 编号。
- [x] **16.2** 端上算出指标与规则评分（0-100）与支撑/阻力位，且与 Python 对拍一致（买卖点由 LLM 生成，见 §0.5-1）。已满足，S6/S7 交付时已逐字段对拍。
- [x] **16.3** 生成 ContextPack：技术面 available、`levels` available、其余 `not_supported`，含数据质量分。已满足，S16 新增的端到端测试用真实 `WorkspaceInitializationCoordinator` 验证过，不只是 S8 单元测试层面成立。
- [x] **16.4** 每股独立问答，Prompt 如实声明数据边界，历史严格隔离。已满足，`WorkspaceChatService`（S16 新增）把 S9/S10/S11 串成真正能调用的入口。
- [x] **16.5** LLM 直连云端（自带 Key，Keychain），成功完成一次真机问答，且能结合 `levels` 产出 sniper_points。**代码链路已打通并用 mock 验证**，但"真机一次成功问答"本身需要真实 API Key，这个环境做不到——这条验证点性质上就是留给真机的，不算遗漏。
- [x] **16.6** 手动刷新 + 过期告警可用；串行/受限并发队列可恢复。**刷新/恢复逻辑已满足**，**过期告警的 UI 提示文案还没做**（判断逻辑和状态迁移都有了，只是"在哪个界面用什么措辞显示"没设计）。
- [x] **16.7** 通知/灵动岛显示进度，且未被用作后台计算容器。本地通知已满足；**灵动岛代码存在但从未编译验证过，且需要在 Xcode 里新建 Widget Extension target**，风险明显高于其余交付，S14 交付时已强调过。

> 本轮新增了三块之前所有阶段都在往后推的"胶水层"代码，因为没有它们 16.1/16.4/16.5 根本没有
> 入口可以触发：
> - `WorkspaceInitializationCoordinator`（把 S5-S8 的纯函数接成 `InitializationQueue` 的
>   `StepExecutor`，含"一键建 Workspace"入口）
> - `WorkspaceChatService`（把 `PromptBuilder`+`LLMService`+`ChatSession` 接成真正的"问一个问题"）
> - `DailyBarsProvider` 协议（给 `TencentDailyProvider` 补的协议抽象，跟现有 `QuoteProvider` 一个
>   模式，专门是为了让上面这个编排层能用 mock 做端到端测试，不用真的连网）
>
> 详细的逐条评估、每条的具体依据、5 点明确缺口清单，见 `S16_MVP验收评估.md`。前两点缺口
> （Home 页建 Workspace 入口、过期告警 UI 文案）是可以现在补的纯 UI 工作；灵动岛需要你在
> Xcode 里配置；"真机验证"类的几条本来就不可能在这个环境里自动化完成。

---

## 明确不做（Out of Scope）

- 交易/下单/持仓/账户。
- 全市场横截面选股（`quant_platform/selection/*`）、端上训练/回测/评估（`quant_platform/training,evaluation/*`）。
- 端上新闻/情报/联网搜索（`search_service.py`、`intelligence_service.py`）。
- 服务端依赖、内网穿透、常开机器、后台长时计算。
- 端上规则买卖点算法（`ideal_buy/secondary_buy/take_profit`，由 LLM 生成，见 §0.5-1）。
- 实时成交量叠加、日线"追加虚拟行"分支（MVP 阶段，见 §0.5-4/§0.5-7）。

> 若某任务看似需要以上任一项，**先停下确认**再实现。
