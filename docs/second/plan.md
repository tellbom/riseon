# plan.md — 本地 iPhone 个股问答 App 方案设计

> 本文件为**方案设计文档**，不含任何业务代码开发或改动。
> 目标：基于当前 Python 量化/分析平台的既有能力，设计一个**离线优先、端上自洽**的
> iPhone 个股问答 App（集成自选股），并与 `task.md` 配套，供后续 Claude/Codex 会话直接落地。
> 本文所有"可复用/不可复用"结论均标注了当前仓库中的**确切文件位置**；无法从代码验证的地方，明确写"**无法验证**"。
>
> **v2 修订说明**：S0 代码核实阶段发现 4 处原文假设与源码不符，S1 交付后的复审又补充发现 3 处遗漏，
> 共 7 项已裁决，详见新增的 **§0.5**。本文档已同步更新相关章节（§2.2/2.3/6/7/8/9/13/14/16），
> 不再需要额外的勘误表——正文即最新结论。

---

## 0. 阅读者须知与命名

- 当前仓库同时存在两套东西：
  1. **Python 量化/分析平台**（`src/`、`quant_platform/`、`data_provider/`、`bot/`、`api/` 等）——本方案的**能力来源**。
  2. **已有的 Swift App**（`RiseOn_*`=iPhone 自选股管理、`Stocks_Watch_App_*`=Apple Watch 行情、`Shared_*`=共享层）——本方案的**落地宿主**，自选股与行情能力将被直接复用。
- 本方案交付的 App 代号沿用现有 iPhone 工程 **RiseOn**，新增"个股问答（StockWorkspace）"模块，与既有自选股/行情共存，不推翻现有 `plan.md`（Watch 行情 MVP）的既定边界。
- 术语：**StockWorkspace** = 单只股票的独立工作区（数据、因子、评分、会话彼此隔离）；**ContextPack** = 单只股票的上下文数据包（对应 Python 侧 `AnalysisContextPack`）。

---

## 0.5 v2 决策记录（S0 核实 + S1 复审，评审确认）

> 本节是全文档的权威裁决来源，`task.md` 中所有 "§0.5-N" 引用均指向本节对应编号。

1. **买卖点由 LLM 生成，端上不做规则买卖点算法。** `src/analyzer.py::get_sniper_points` 读的是
   `dashboard.battle_plan.sniper_points`——LLM 报告结构的一部分，不是 `TrendAnalyzer` 的输出。
   Python 侧唯一的规则兜底只有 `stop_loss ← support_levels[0]`
   （`src/core/pipeline.py::_stop_loss_fallback_from_trend`）。端上 `RuleScoreEngine` 只移植
   `support_levels`/`resistance_levels`（见第 5 条），`ideal_buy/secondary_buy/take_profit`
   完全交给 LLM 在 Prompt 里结合 `levels` 块生成。
2. **RSI 统一采用 `stock_analyzer.py::_calculate_rsi` 的 Wilder's EMA 口径**
   （`ewm(alpha=1/period, adjust=False)`），禁用 `technical_indicators.py::calculate_rsi`
   的简单滚动均值口径——两者对同一段数据算出的 RSI 数值不同，且 `RuleScoreEngine` 的评分权重
   直接依赖 Wilder 口径。
3. **`code` 归一化新建独立函数（`Workspace/ACodeResolver`），不复用 `Shared/Models/StockSymbol.swift`。**
   现有 `StockSymbol` 只处理 `6→sh, 0/3→sz, 4/8→bj`（且校验文案写死"须以 0/3/4/6/8 开头"），
   与 Python `data_provider/base.py::is_bse_code` 的真实规则（BSE = `92/43/81/82/83/87/88` 开头
   且非 `900` 开头；其余 `6/5/9` 开头 → `sh`；否则 → `sz`）不一致。S1.1 明确不改动既有自选股/Watch
   代码，因此 `ACodeResolver` 是全新、独立的函数，与 `StockSymbol` 互不影响、互不复用。
4. **MVP 阶段实时行情覆盖跳过成交量叠加，仅叠加价格。** `Shared/Models/Quote.swift` 没有
   volume/amount 字段，`TencentQuoteProvider` 也未解析整笔成交量（只解析盘口五档量）。覆盖时只更新
   `close`（及可选 `open/high/low`），`volume` 保持日线原值，并在 ContextPack `warnings` 写入
   `intraday_volume_overlay_skipped`。
5. **`support_levels` 有三个来源，不是两个——MA20 分支容易被漏掉。**
   `src/stock_analyzer.py::_analyze_support_resistance`（448-479 行）里：
   - 461 行：MA5，`|price-MA5|/MA5 <= 2%` 且 `price>=MA5` 才计入；
   - 468 行：MA10，同样 2% 容忍度，`price>=MA10` 才计入；
   - **472 行：MA20，只要 `price>=MA20` 就无条件计入，没有 2% 容忍度限制**——这一条最容易在
     "移植 MA5/MA10 支撑"这种简化描述下被漏掉。
   - 477 行：阻力位 = 近 20 日最高价（`recent_high > price` 时计入）。
   端上必须完整移植全部四条（三条支撑 + 一条阻力），否则 `support_levels[0]`（即 `stop_loss`
   回退值）可能选中错误的价位。
6. **`TechnicalIndicators`（S6）与 `RuleScoreEngine`（S7）的 MA 计算口径不同，禁止共享实现。**
   `technical_indicators.py::calculate_ma` 用 `rolling(window=period, min_periods=1)`（不足周期也
   出值）；`stock_analyzer.py::_calculate_mas` 用满窗口（默认 `min_periods=period`，不足周期为
   NaN；且 `MA60` 在数据 <60 根时直接退化为 `MA20`）。这与 RSI 的分歧是同一类问题：两个 Python
   源本来就没有共享实现，端上也必须分别独立实现，`RuleScoreEngine` 一侧必须对齐
   `stock_analyzer.py` 口径，不能偷懒调用 `TechnicalIndicators` 的 MA 函数。
7. **实时覆盖当日日线的"追加虚拟行"分支，MVP 阶段不实现。** Python
   `_augment_historical_with_realtime` 有两个分支：当日已有日线行 → 原地覆盖；当日还没有日线行
   → 追加一条虚拟行。端上是否需要"追加虚拟行"分支，取决于腾讯日线接口在盘中是否已经实时推送
   "今天"这一根K线——这一点在当前开发环境里无法直接验证（需要真机/浏览器在交易时段实测）。
   MVP 决策：**只实现"覆盖已有行"分支**；若最后一根日线日期 < 今天，`daily_bars`/`technical`
   继续使用最近交易日收盘价，仅 `quote` 块单独展示实时价，并在 `warnings` 写入
   `intraday_bar_not_yet_available`。"追加虚拟行"列为 Phase 2 候选项，需先实测接口行为再决定。

---

## 1. 对当前项目现状的理解

当前 Python 平台是一个**完整的、服务端形态的**个股分析与问答系统，核心链路可端到端跑通：
拉数 → 实时行情 → 筹码 → 基本面 → 趋势评分 → 情报/新闻检索 → 上下文组装 → LLM 生成结构化报告 → 落库与会话历史。

关键事实（均有代码支撑）：

- **入口与编排**：`src/services/analysis_service.py::AnalysisService.analyze_stock` → `src/core/pipeline.py::StockAnalysisPipeline.process_single_stock`（约 176KB，是真正的编排中枢）。
- **产出结构**已定型（见 `analysis_service._build_analysis_response`）：`meta / summary(analysis_summary, operation_advice, action, trend_prediction, sentiment_score) / strategy(ideal_buy, secondary_buy, stop_loss, take_profit) / details(news_summary, technical_analysis, fundamental_analysis, risk_warning)`。这可直接作为**端上问答/报告的目标数据结构**（但 `strategy` 块的取值来源见 §0.5-1：LLM 生成，非规则计算）。
- **上下文契约**已工程化：`src/schemas/analysis_context_pack.py` 定义了带**逐块状态**（`available/missing/not_supported/fallback/stale/estimated/partial/fetch_failed`）与**数据质量打分**的 `AnalysisContextPack`。这正是产品需求里"每只股票独立数据包"的现成模型。
- **LLM 调用是远程/桌面形态**：`src/llm/litellm_backend.py`（走 LiteLLM，需云端 Key）与 `src/llm/local_cli_backend.py`（走本地 Codex CLI，桌面进程）。**两者都无法直接搬进 iPhone**。
- **新闻/情报/联网搜索是重资产**：`src/services/intelligence_service.py`（RSS/Atom/newsnow + DNS 防护 + sqlalchemy 落库）、`src/search_service.py`（Bocha/Tavily/Brave/SerpAPI/SearXNG + `newspaper` 抓正文，约 176KB）。**强依赖服务端与第三方 Key**。
- **横截面选股/训练/回测是研究级重负载**：`quant_platform/selection/*`、`quant_platform/evaluation/*`、`quant_platform/training/*`（LightGBM、walk-forward、IC、DuckDB/Parquet lake）。**与"单股端上问答"目标无关，不迁移**。

结论：**平台大而全，但真正适合端上离线执行的是"技术面计算 + 规则评分 + 上下文打包 + Prompt 组装"这条轻链路**；数据获取只有腾讯免费直连端点适合端上；情报与 LLM 需要重新设计端上形态。

---

## 2. 当前核心链路复盘（逐条定位）

### 2.1 股票数据获取管线
- 统一入口：`data_provider/base.py`
  - `DataFetcherManager.get_daily_data(...)`（日线）、`get_realtime_quote(...)`（实时）、`get_stock_name(...)`。
  - 代码规范化：`normalize_stock_code / canonical_stock_code / is_bse_code`（`base.py`）——端上对应实现见 §0.5-3 的 `ACodeResolver`，与既有 `StockSymbol.swift` 是两套独立逻辑。
- 具体源：`data_provider/tencent_fetcher.py`（日线 qfq，端点 `https://web.ifzq.gtimg.cn/appstock/app/fqkline/get`，`param=sh600519,day,<start>,<end>,<lookback>,qfq`，返回 `qfqday` 数组，字段序为 `date/open/close/high/low/volume/amount`——注意第 3 位是 close 不是 high）；`akshare/tushare/efinance/yfinance/longbridge/finnhub/alphavantage/tickflow_fetcher.py`（均为 **Python 库 + 服务端**）。
- 实时行情模型：`data_provider/realtime_types.py::UnifiedRealtimeQuote`（`price/change_pct/volume_ratio/turnover_rate/amplitude/open/high/low/pre_close`）与 `ChipDistribution`（`avg_cost`、`get_chip_status(price)`）。
- **可端上复用**：仅**腾讯直连**两个端点（实时 `qt.gtimg.cn`、日线 `web.ifzq.gtimg.cn`）。前者 Swift 已实现（`Shared_QuoteProvider_TencentQuoteProvider.swift`），分时也已实现（`TencentMinuteProvider.swift`），**日线尚缺，需新增**。其余源不可端上直接复用。

### 2.2 因子/指标计算管线
- **纯计算、零外部依赖、最适合迁移**：`technical_indicators.py`（`calculate_ma/macd/kdj/rsi/boll`、`calculate_all_indicators`、`get_latest_signals`、`format_indicators_for_json`）。
- **LLM 因子摘要**：`src/factors/llm_factor_summary.py::build_llm_factor_summary`（MA/RSI/KDJ/BOLL/ATR/量能/动量/波动 摘要，纯 pandas）。
- **窗口化因子上下文**：`src/factors/quant_factor_context.py::build_quant_factor_context`（决策窗口 `1/3/5/10/20`、计算窗口 `COMPUTE_WINDOW_BARS=120`、`technical/capital_flow/valuation/industry/fundamentals/events/margin`）。其中 `technical` 块**仅靠本地日线**即可算；`capital_flow/valuation/industry/fundamentals/margin` 依赖 `fundamental_context`，**端上需降级为 not_supported**。
- **重型特征工程（不迁移）**：`quant_platform/features/*`（`technical.py` 复用 `technical_indicators.py` 之上叠加 `pandas_ta_classic`、warm-up 掩码、截面标准化、IC）——面向训练/截面，端上无意义。
- **口径分歧提醒（v2 裁决，见 §0.5-2/§0.5-6）**：`technical_indicators.py` 的 RSI（简单滚动均值）与 MA（`min_periods=1`）与 `src/stock_analyzer.py` 的 RSI（Wilder's EMA）与 MA（满窗口+MA60兜底MA20）**口径不同**。端上 `TechnicalIndicators`（S6）与 `RuleScoreEngine`（S7）必须各自独立实现，不得共享同一套 MA/RSI 函数；`RuleScoreEngine` 一侧必须对齐 `stock_analyzer.py` 口径。

### 2.3 策略选择/评分/推荐管线
- **单股规则评分（最适合迁移）**：`src/stock_analyzer.py::TrendAnalyzer`。
  - 枚举：`TrendStatus/VolumeStatus/BuySignal/MACDStatus/RSIStatus`；结果 `TrendAnalysisResult(signal_score 0-100, support_levels/resistance_levels 等)`。
  - 评分权重（`_generate_signal`）：**趋势 30 / 乖离率 20 / 量能 15 / 支撑 10 / MACD 15 / RSI 10 = 100**；由分数+趋势映射 `BuySignal`。
  - **买卖点澄清（v2 裁决，见 §0.5-1）**：`ideal_buy/secondary_buy/stop_loss/take_profit` 并**不是** `TrendAnalyzer` 的输出，而是 `dashboard.battle_plan.sniper_points`，由 **LLM** 生成（`src/analyzer.py::get_sniper_points`）；pipeline 侧仅对 `stop_loss` 提供确定性兜底（取 `support_levels[0]`，见 `src/core/pipeline.py::_stop_loss_fallback_from_trend`）。端上**不移植**买卖点算法，只移植 `support_levels`/`resistance_levels`（完整三+一来源，见 §0.5-5）。
- **横截面选股（不迁移）**：`quant_platform/selection/strategies.py`（`EqualTopK/ProportionalTopK/Hybrid`，需要全市场面板）。
- **策略蓝图（作为静态 Prompt 文本可复用）**：`src/core/market_strategy.py::MarketStrategyBlueprint`（CN/HK/US 复盘原则、维度、行动框架，`to_prompt_block()`）。注意 `CN_BLUEPRINT` 面向大盘/板块轮动复盘，个股 Prompt 里建议只摘 `principles`/`action_framework` 的通用交易纪律部分，不用面向大盘的 `dimensions`。

### 2.4 Prompt 构建与上下文组装管线
- **上下文契约**：`src/schemas/analysis_context_pack.py`（`AnalysisContextPack/Block/Item + ContextFieldStatus + DataQuality`）。
- **组装器**：`src/services/analysis_context_builder.py::AnalysisContextBuilder.build`（把 pipeline 产物打包成分块 Pack；块权重 `quote25/daily_bars25/technical25/news10/fundamentals10/chip5`，状态→分值映射齐全）。
- **Prompt 渲染**：`src/analysis_context_pack_prompt.py`（块/状态中英标签）、`src/analysis_context_pack_overview.py`（低敏感度公开概览）。
- **会话历史（问答记忆）**：`src/agent/chat_context.py`（可见历史 + 超长时的**会话压缩摘要** `SUMMARY_SYSTEM_PROMPT`，产出固定 5 个二级标题）。
- **可端上复用**：Pack 结构、状态枚举、质量打分、块标签、摘要压缩思路——**全部可移植为 Swift 端字符串/结构组装**。

### 2.5 LLM 调用与报告生成管线
- 契约：`src/llm/generation_backend.py`（`GenerationBackend.generate(...)`、`GenerationResult`、`GenerationError(错误码枚举)`）。
- 工厂：`src/llm/backend_factory.py` → `litellm_backend.py`（远程）/`local_cli_backend.py`（Codex CLI，桌面）。
- 报告脚手架：`stock_full_report.py`、`gen_report.py`、`update_stock_report.py`、`src/analyzer.py`（约 216KB，`get_sniper_points`/`fill_price_position_if_needed` 等买卖点相关逻辑均在此文件，见 §0.5-1）。
- **端上结论**：报告的**目标结构可复用**（§2.1 的产出结构）；**执行体不可复用**——iPhone 需**直连云端 LLM API（用户自带 Key）**，把 `generate(prompt, system_prompt)` 抽象为一个 Swift `LLMService`；且 Prompt 需要显式要求 LLM 结合端上算好的 `levels`（支撑/阻力位）块产出 `sniper_points`（见 §9）。

### 2.6 问答入口
- `bot/commands/ask.py::AskCommand`（`/ask 600519 [技能]`，多股对比≤5，技能来自 `src/agent/skills/*`）。技能体系（`src/agent/*` orchestrator/executor）是服务端 Agent，**端上先不迁移**，仅借鉴"单股 + 技能视角"的交互概念。

---

## 3. 本地 iPhone 个股问答 App 目标

- **离线优先、端上自洽**：初始化后，单股的技术面数据、指标、规则评分、上下文包、Prompt 组装均在端上完成；仅 **LLM 推理**这一步出网（直连云端 API，用户自带 Key）。
- **无服务端依赖**：不做内网穿透、不依赖常开机器、不走 VPN。
- **每股一个 StockWorkspace**：数据、因子、评分、会话彼此隔离；可多股并发/排队初始化；支持手动刷新、失败重试、部分缺失提示、数据过期告警。
- **与既有自选股打通**：直接复用 `Shared_Models_WatchlistItem.swift`、`Shared_Persistence_WatchlistStore.swift`——自选股即"可一键建为 Workspace 的候选集"。
- **非目标**：不做交易/下单、不做全市场选股、不做端上训练/回测、不做端上联网新闻爬取（MVP 阶段情报块降级）。

---

## 4. 产品形态与 UI/UX 设计

三个主界面 + 一个初始化态：

1. **股票列表页（Home）**：来源=自选股 ∪ 已建 Workspace。每行展示：名称/代码、最新价与涨跌幅（复用 `TencentQuoteProvider`）、Workspace 状态徽标（未建/初始化中/就绪/数据过期/部分缺失）。
2. **StockWorkspace 详情页**：顶部=行情卡 + 数据质量条（来自 ContextPack `data_quality`）；中部=**规则评分卡**（signal_score、BuySignal、支撑/阻力位、趋势/量能/MACD/RSI 分解；买卖点由 LLM 在问答区给出，见 §0.5-1）；下部=**问答区**（该股独立会话）。
3. **问答页（Chat）**：仅基于该股 ContextPack + 该股历史；顶部常驻"数据快照时间/质量/缺失块"提示，避免用户误以为有实时新闻。
4. **初始化态**：进度可视化（分步：日线→指标→评分→打包），失败可重试单步；完成后进入"可问答"。

设计原则：
- **诚实呈现数据边界**：凡是端上拿不到的块（新闻/资金流/基本面/筹码），UI 明确显示"不支持/降级/过期"，与 Python 侧 `ContextFieldStatus` 一一对应。
- 涨跌红绿、评分色阶、状态徽标一致化；问答输入前置校验（有无就绪 Pack）。

---

## 5. StockWorkspace 设计

一个 Workspace = 一个隔离目录 + 一份状态机：

- **标识**：`code`（通过 §0.5-3 的 `ACodeResolver` 归一化，镜像 Python `is_bse_code`/`_to_tencent_symbol` 语义）、`name`、`market`。
- **状态机**：`uninitialized → initializing → ready → (stale | partial)`；失败态 `failed(step)` 可重试。
- **持有物**：`ContextPack(JSON) + RuleScore(结构体) + ChatSession(消息数组) + meta(数据快照时间/来源/质量)`。
- **隔离约束**（硬性）：问答上下文只能读取**本 Workspace** 的 Pack 与历史，禁止跨股共享（对应产品需求）。
- **存储**：每股一份独立文件/记录（见 §7）。

---

## 6. 股票初始化流程设计

分步、可恢复、可观测（每步都对应可迁移的 Python 逻辑）：

```
Step A 拉日线    → TencentMinuteProvider 的日线变体（web.ifzq.gtimg.cn，qfq）
Step B 叠加实时  → TencentQuoteProvider（qt.gtimg.cn）覆盖当日最新价（仅价格，不含成交量；
                   若当日日线行尚未出现则跳过覆盖，见 §0.5-4/§0.5-7）
Step C 算指标    → 移植 technical_indicators.py（MA/MACD/KDJ/RSI/BOLL + get_latest_signals，
                   RSI 口径见 §0.5-2）
Step D 规则评分  → 移植 TrendAnalyzer 评分（30/20/15/10/15/10）+ 支撑/阻力位
                   （不产出买卖点，买卖点由 LLM 在问答阶段生成，见 §0.5-1/§9）
Step E 打包Pack  → 按 AnalysisContextPack 结构生成分块 + 逐块状态 + 质量打分
Step F 就绪      → 标记 ready，写入快照时间
```

- **降级规则**：新闻/资金流/基本面/筹码块直接置 `not_supported`（端上无源），不阻塞 ready。
- **失败恢复**：每步幂等、可单独重试；网络首连延迟参照现有 Watch 经验加"1s + 单次重试"（用户记忆中的 `fetchWithRetry` 模式）。
- **并发/排队**：见 §10。

---

## 7. 股票数据包 / 上下文包设计

端上 `ContextPack`（**直接对标** `src/schemas/analysis_context_pack.py`）：

- `subject{code,name,market}`、`pack_version`、`created_at`。
- `blocks`：
  - `quote`（available，来自实时）
  - `daily_bars`（available，来自日线）
  - `technical`（available，来自端上指标）
  - `factors`（partial：仅 technical 窗口，参照 `quant_factor_context` 的 `1/3/5/10/20` 窗口与 120 bar 计算窗口）
  - `levels`（available：S7.3 产出的支撑位/阻力位，供 LLM 生成买卖点参考，见 §0.5-1/§0.5-5）
  - `chip / fundamentals / news / capital_flow / events`（**not_supported**，端上无源）
- `data_quality{overall_score, level(good/usable/limited/poor), block_scores, limitations, warnings}`，权重参照 `analysis_context_builder`（端上重算权重：technical/quote/daily_bars 为主）；`warnings` 中会出现 `intraday_volume_overlay_skipped`（§0.5-4）与视情况出现的 `intraday_bar_not_yet_available`（§0.5-7）。
- **序列化**：JSON，落本地文件；问答时整包注入 Prompt（大小可控，端上无检索需求）。

---

## 8. 因子与策略迁移可行性评估

| 能力 | 来源文件 | 端上处置 | 理由 |
|---|---|---|---|
| MA/MACD/KDJ/BOLL + 信号 | `technical_indicators.py` | **直接移植（Swift 重写）** | 纯 pandas 数学，无外部依赖；MA 用 `min_periods=1`，与 `RuleScoreEngine` 一侧的 MA 分别独立实现（§0.5-6） |
| RSI(6/12/24) | `src/stock_analyzer.py::_calculate_rsi` | **移植（Wilder's EMA 口径，禁用 `technical_indicators.py` 的简单均值版本）** | 两套 RSI 数值不同，评分依赖 Wilder 口径（§0.5-2） |
| 单股规则评分 | `src/stock_analyzer.py::TrendAnalyzer` | **移植（保留权重与枚举语义）** | 规则清晰、离线可算 |
| 支撑位/阻力位 | `src/stock_analyzer.py::_analyze_support_resistance`（448-479行） | **完整移植（MA5/MA10/MA20 三个支撑来源 + 近20日高点阻力位）** | 规则清晰、离线可算；MA20 分支无容忍度限制，容易漏（§0.5-5） |
| 买卖点 ideal_buy/secondary_buy/stop_loss/take_profit | `src/analyzer.py::get_sniper_points`（LLM 产出）、`src/core/pipeline.py::_stop_loss_fallback_from_trend`（规则兜底） | **不迁移规则算法，仅 `stop_loss` 保留 `support_levels[0]` 确定性回退；其余由 LLM 在问答阶段生成** | Python 侧本身就不是纯规则实现（§0.5-1） |
| 窗口化因子（technical 部分） | `src/factors/quant_factor_context.py` / `llm_factor_summary.py` | **部分移植** | technical 窗口本地可算；其余块无源 |
| 策略蓝图文本 | `src/core/market_strategy.py` | **作为静态 Prompt 文本复用（仅摘 principles/action_framework）** | 纯文案；`dimensions` 面向大盘，个股场景不适用 |
| 资金流/估值/基本面/筹码/融资 | `data_provider/*`、`quant_platform/features/*` | **降级为 not_supported / 未来服务端** | 依赖 akshare/tushare/efinance 库与私有端点，端上不可直接调 |
| 横截面选股 | `quant_platform/selection/*` | **不迁移** | 需要全市场面板 |
| 训练/回测/评估 | `quant_platform/training,evaluation/*` | **不迁移** | 重负载研究链路 |
| 新闻/情报/联网搜索 | `intelligence_service.py`、`search_service.py` | **不迁移（MVP 降级）** | 强依赖服务端 + 第三方 Key |

**不要机械翻译**：以上"移植"指按 Swift 惯用法重写等价逻辑（含单元测试固定用例），而非逐行转译 pandas。
**不要合并口径不同的实现**：`TechnicalIndicators`（S6）与 `RuleScoreEngine`（S7）的 MA/RSI 即使名字一样，也必须分别独立实现（§0.5-2/§0.5-6）。

---

## 9. Prompt 与 LLM 问答设计

- **PromptBuilder（Swift）**：输入=该股 `ContextPack`（含 `levels` 支撑/阻力位块） + `RuleScore` + `MarketStrategyBlueprint` 文本（仅摘通用交易纪律部分） + 用户问题 + 会话历史；输出=`(systemPrompt, userPrompt)`。
  - system 参照 Python 侧口径：只基于给定数据回答、不臆造行情/新闻、明确数据时效与缺失（呼应 `chat_context.SUMMARY_SYSTEM_PROMPT` 与 overview 的诚实呈现）。
  - 缺失块必须写进 Prompt（"新闻/基本面：本地不支持"），防止 LLM 幻觉补数据。
  - **买卖点指令（§0.5-1）**：Prompt 必须显式要求 LLM 结合 `levels` 块（支撑/阻力位）与技术面数据，产出结构化 `sniper_points`（`ideal_buy/secondary_buy/stop_loss/take_profit`）；若 LLM 未给出 `stop_loss`，端上使用 `support_levels[0]` 作为确定性回退（S7.4）。
- **LLMService（Swift）**：抽象 `func generate(system:String, user:String) async throws -> String`；实现直连云端 API（用户在设置里填 Key，Keychain 存储）。对应 Python `GenerationBackend.generate` 的最小子集。
- **会话隔离与压缩**：每股独立消息数组；超长时按 `chat_context` 的 5 段式摘要思路做端上压缩（可先本地截断，后续接 LLM 压缩）。

---

## 10. 本地缓存与刷新策略

- **缓存**：每股 `ContextPack + RuleScore` 落盘；附 `created_at` 与"交易日快照日期"。
- **过期评估**：若快照日期 < 最近交易日，或距今超过阈值（如收盘后自然日 > N），标记 `stale`，UI 提示"数据过期，建议刷新"。
- **手动刷新**：单股刷新 = 重跑 Step A–F；不做后台自动轮询（省电、避免免费端点被限流，延续现有 Watch MVP 原则）。

---

## 11. 多股任务队列设计

- **串行为主、可控并发**：`InitializationQueue`（`actor`）串行调度；并发上限（如 2–3）以避免腾讯端点限流与移动端资源压力。
- **任务模型**：`InitTask{code, step, retries, status}`；每步幂等、可断点续跑。
- **恢复**：App 前后台切换/被系统回收后，从持久化的队列状态恢复未完成任务（**不做长时后台计算容器**，仅短时前台/宽限期内推进）。
- **失败策略**：单步失败→指数退避重试（上限）；超限→标记 `failed(step)`，UI 提供手动重试。

---

## 12. 通知、灵动岛与后台行为边界

- **允许**：初始化进度/完成用**本地通知**与**灵动岛（Live Activity）**做**展示增强**。
- **禁止**：把灵动岛/后台当作**长时计算容器**。计算发生在前台或系统宽限窗口内；后台只更新"进度展示"，不承诺持续拉数/推理。
- LLM 推理为前台交互触发，不放后台。

---

## 13. 推荐的 Swift / iOS 模块解耦

```
RiseOn (现有 iPhone 工程) 内新增：
├── Shared/ (复用现有)
│   ├── Models: WatchlistItem, StockSymbol, Quote, MinutePoint   ← 已存在，不改动
│   └── QuoteProvider: QuoteProvider, TencentQuoteProvider,       ← 已存在，不改动
│                      TencentMinuteProvider(+新增日线变体)
├── Workspace/
│   ├── StockWorkspace (模型 + 状态机)
│   ├── ACodeResolver (§0.5-3：独立 code 归一化，不复用 StockSymbol.swift)
│   ├── WorkspaceStore (每股独立持久化)
│   └── InitializationQueue (actor 队列)
├── Analytics/           ← 纯计算，可单测；与下方 Context/ 一样，MA/RSI 口径独立实现（§0.5-2/§0.5-6）
│   ├── TechnicalIndicators (移植 technical_indicators.py，MA用min_periods=1)
│   ├── RuleScore + RuleScoreEngine (移植 TrendAnalyzer 评分 + 支撑/阻力位；
│   │                                MA用满窗口+MA60兜底MA20，RSI用Wilder口径)
│   └── FactorWindows     (移植 quant_factor_context 的 technical 窗口)
├── Context/
│   ├── ContextPack (对标 AnalysisContextPack + 状态枚举 + 质量打分 + levels 块)
│   └── ContextPackBuilder
├── QA/
│   ├── PromptBuilder (Pack+Score+Blueprint+History → prompts；要求 LLM 结合 levels 产出 sniper_points)
│   ├── LLMService (直连云端 API，Keychain 存 Key)
│   └── ChatSession (每股隔离 + 摘要压缩)
└── UI/
    ├── HomeListView, WorkspaceDetailView, ChatView, InitProgressView
    └── NotificationCenter / LiveActivity 封装
```

- **纪律**：网络 I/O 仅在 `QuoteProvider` 与 `LLMService`；`Analytics/` 保持纯函数、可单测；UI 不直接联网（延续现有工程约定）。

---

## 14. MVP 范围

- 从自选股/输入建立 StockWorkspace；分步初始化（A–F）+ 进度可视化 + 单步重试。
- 端上技术面指标 + 规则评分 + 支撑/阻力位（买卖点由 LLM 生成，见 §0.5-1）；生成 ContextPack（技术面块 available，其余 not_supported）。
- 每股独立问答：PromptBuilder + LLMService（用户自带 Key）+ 隔离历史。
- 手动刷新 + 过期告警；串行/受限并发队列 + 恢复。
- 通知/灵动岛显示初始化进度（展示级）。

**MVP 不含**：新闻/情报、资金流/基本面/筹码、多股对比、技能体系、端上摘要压缩（先截断）、后台自动刷新、实时成交量叠加、日线"追加虚拟行"分支（见 §0.5-4/§0.5-7）。

---

## 15. 未来扩展方向

- 引入**服务端可选增强**（若日后允许）：新闻/情报、基本面、筹码走后端补块，端上 Pack 从 `not_supported` 升级为 `available`。
- 端上 LLM 会话摘要压缩（接 `chat_context` 5 段式）。
- 多股横向对比（借鉴 `ask` 的多股语义）。
- Agent 技能视角（缠论/波浪等）以只读 Prompt 模板形式下发。
- 第二数据源（东方财富 JSON）作为腾讯端点的降级备份。
- 实时成交量叠加（需先扩展 `Quote`/`TencentQuoteProvider` 解析整笔成交量字段）。
- 日线"追加虚拟行"分支（需先实测腾讯接口盘中行为，见 §0.5-7）。

---

## 16. 风险、边界与缺失信息

- **免费端点稳定性/合规**：腾讯 `qt.gtimg.cn`、`web.ifzq.gtimg.cn` 为非官方端点，字段可能变更、可能限流；需防御式解析、个人低频非商用（延续现有 Watch `plan.md` §8 风险表）。**GBK 解码**坑已在现有 Swift 处理。
- **LLM 端上化**：需用户自带云端 Key；涉及**成本、时延、Key 安全（Keychain）**、以及"出网"这一唯一联网点。无服务端代理。
- **情报/新闻/搜索无法端上化**：`search_service.py`/`intelligence_service.py` 依赖 Bocha/Tavily/Brave/SerpAPI/SearXNG 等 Key 与 `newspaper`、sqlalchemy——**MVP 明确降级**。
- **基本面/资金流/筹码源无法验证端上可行性**：`ChipDistribution` 的实际数据源在 `DataFetcherManager` 内部经多源熔断获取，**从已读代码无法确认是否存在可端上直连的公开端点——标注"无法验证"**，MVP 一律 `not_supported`。
- **横截面/训练/回测**：与单股端上问答目标无关，明确不迁移。
- **不要机械翻译**：pandas 逻辑需按 Swift 重写并配固定用例单测，尤其指标数值需与 Python 输出对拍。
- **不要合并口径不同的实现**：`TechnicalIndicators` 与 `RuleScoreEngine` 的 MA/RSI 即使名字相同也要分别独立实现并分别对拍（§0.5-2/§0.5-6），避免"重构成一份共享代码"的直觉冲动。
- **腾讯日线接口盘中行为待实测**：`_augment_historical_with_realtime` 的"追加虚拟行"分支是否需要实现，取决于腾讯接口盘中是否已推送当日K线，MVP 阶段先跳过并显式声明（§0.5-7），后续需要真机验证。
