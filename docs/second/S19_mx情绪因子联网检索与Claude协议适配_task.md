# S19 — mx-search 情绪面因子联网检索 + Claude 协议适配（task 计划）

> 承接 S18（提示词优化 + 联网检索）。本轮做四件事：
> ① 移除 Tavily 方案，**保留 web_search 的循环思考（工具轮次）逻辑**，换成东方财富妙想
> mx-search 作为联网检索源，产出「带情绪面因子的数据报告」注入 LLM 上下文；
> ② 联网仍是可选项，但开启后要有「思考动作」——让用户看到 LLM 正在检索什么；
> ③ 最终回答改为**流式输出**（含工具轮次路径，不再退化成非流式）；
> ④ LLM 增加 **Claude(Anthropic Messages API) 协议适配** + 自定义模型配置项。
> 全部向后兼容：新增参数带默认值，`webSearch==nil` / OpenAI 协议路径行为与现在完全一致。

---

## 〇、前置验证结论（已完成，勿重复验证）

- mx-search 真实接口：`POST https://mkapi2.dfcfs.com/finskillshub/api/claw/news-search`
  - Header：`Content-Type: application/json`、`apikey: <MX_APIKEY>`
  - Body：`{"query":"贵州茅台最新研报机构观点"}`
  - 已用 Key `mkt_JBB4KOC1V-WIsXjyeAJvpr_6XBGWptOvcGE5fUMvoGw` 实测通过（HTTP 200 / `status:0` / 100KB 真实数据）。
- 响应结构（Swift 解析路径）：`root["data"]["data"]["llmSearchResponse"]["data"]` 为数组，
  每条 item 字段：`title` / `content` / `date` / `informationType`(REPORT/NEWS/ANNOUNCEMENT) /
  `entityFullName` / `insName` / `rating`(增持/买入/强推/强烈推荐/跑赢行业…) / `indexAttention`(Bool) /
  `rankScore` / `emRatingName` / `communityFlag`。成功判据：`root["status"]==0` 或 `root["success"]==true`。
- 结论：**纯 HTTPS，端上 `URLSession` 直连即可，情绪面因子链路能跑通，无需手机端 MCP 爬取兜底。**
- 安全说明（需在设置页 footer 提示）：无服务器端，`MX_APIKEY` 与 LLM Key 一样存 Keychain，
  客户端持有——个人自用可接受，与现有 Tavily Key 的处理口径一致。

---

## 一、移除 Tavily，接入 mx-search（保留工具轮次循环）

### T1.1 新增 `QA/MXSearchService.swift`（替换 Tavily 实现）
- `actor MXSearchService: WebSearchService`，`init(apiKey:maxResults:session:)`。
- `search(_:) -> [WebSearchResult]`：POST 上述 endpoint，Header 用 `apikey`（**不是** Bearer）。
- 新增 `static func parse(_:) -> [WebSearchResult]`（暴露给单测，与 `TavilyWebSearchService.parse` 同模式）：
  - 走 `data.data.llmSearchResponse.data[]`，逐条映射 `WebSearchResult`：
    - `title` = item.title
    - `url` = ""（mx 无 url；不要编造）或证券代码 `secuCode`（若存在）
    - `snippet` = 拼「机构/日期/评级/类型 + 正文摘要」，作为情绪因子上下文（见 T2.1）。
  - 非 200 / `status!=0` → 抛 `LLMServiceError`；解析失败返回 `[]`（与现有语义一致）。
- **保留** `WebSearchService` 协议、`WebSearchResult`、`WebSearchOptions`、
  `OpenAICompatibleLLMService.runToolRound` 的整套「模型请求 web_search → 端上执行 → 回填 → 再答」循环逻辑，仅替换具体检索后端。
- verify：`Tests/QA/WebSearchToolRoundTests` 里 Tavily 相关用例改为 MX 版 fixture，
  `MXSearchService.parse` 能从样例 JSON 正确取出 title/评级/机构；`firstMessage`/`toolCallQuery`/
  `formatSearchResults`/`WebSearchOptions` 纯函数用例保持通过。

### T1.2 删除 Tavily 残留（仅清理本次改动产生的孤儿）
- 删 `TavilyWebSearchService`（在 `WebSearchService.swift` 内）及其单测。
- `LLMConfigurationStore.makeService`：`webSearch = .init(service: MXSearchService(apiKey: key))`。
- `WebSearchAPIKeyStore` 保留（Keychain，独立 service id），仅存的语义由 Tavily Key 改为 `MX_APIKEY`；
  设置页文案随之更新（见 T3）。不改动 `LLMAPIKeyStore`。
- verify：全局 grep 无 `Tavily` 残留（docs 说明除外）；`makeService` 仅在
  「开启联网 **且** 存了 MX Key」时挂工具轮次，否则视为模型自带联网（路 A，只放开提示词）。

---

## 二、情绪面因子数据报告（工具结果格式化）

### T2.1 改造 `OpenAICompatibleLLMService.formatSearchResults`（或抽到 MXSearchService）
- 在返回给模型的工具结果里，**先给一段情绪面汇总**，再列明细：
  - 汇总行：统计 `rating` 分布，粗粒度映射情绪信号
    （增持/买入/强推/强烈推荐/跑赢行业 → 看多；下调/减持/回避 → 看空；机构关注度 `indexAttention` 命中数），
    形如「本轮检索 12 条研报：11 条看多(强推4/买入3/增持1/强烈推荐3)，覆盖机构 8 家，多家标注高关注度」。
  - 明细：每条「标题 | 机构 | 日期 | 评级 | 类型 | 正文摘要」。
- 目的：让 LLM 拿到「因子」而非裸文本，回答时把情绪因子叠加进已有资金/技术/情绪本地因子之上。
- 提示词（`PromptBuilder` 联网分支，S18 已有）补一句：联网检索所得为「情绪面/舆情因子」，
  须与本地资金/技术因子交叉，注明来源机构与时间，不得覆盖本地行情数据。
- verify：`PromptRenderingTests` 增断言——联网系统提示词包含情绪因子交叉口径；
  给定含多条 rating 的 fixture，`formatSearchResults` 输出包含情绪汇总行。

---

## 三、思考动作 + 流式输出（含工具轮次路径）

> 现状：S18 的联网路径走**非流式** `ask`，UI 只显示「正在输入」。本轮要：开启联网后展示
> 「LLM 正在检索：<query>」等思考动作，最终回答**流式**逐 token。

### T3.1 新增 `LLMStreamEvent`
```swift
enum LLMStreamEvent: Sendable {
    case searching(query: String)   // 端上即将执行的一次检索（思考动作）
    case searchDone(summary: String)// 该次检索的情绪因子汇总一句话（思考动作）
    case answerDelta(String)        // 最终回答的流式增量
}
```

### T3.2 服务层：工具轮次改为「边思考边流式」
- `OpenAICompatibleLLMService` 增加 `streamGenerateEvents(system:user:) -> AsyncThrowingStream<LLMStreamEvent, Error>`：
  - 复用 `runToolRound` 的循环：每次模型请求 `web_search` 时，先 `yield .searching(query)`，
    端上执行 `MXSearchService.search`，`yield .searchDone(汇总)`，回填 `tool` 消息；
  - 轮次结束（模型不再要工具 / 轮次耗尽）后，最后一次请求带 `stream:true`，
    用现有 `parseSSEDataLine` 解析 `delta.content`，逐段 `yield .answerDelta`。
  - `webSearch==nil` 时：直接走纯流式（等价现有 `runStream`），只产出 `.answerDelta`。
- 保留原 `streamGenerate -> AsyncThrowingStream<String>`（纯路径与既有单测不动）；
  新方法是叠加，不改协议已有签名。若要进 `LLMService` 协议，给默认实现桥接到 `streamGenerate` 并包成 `.answerDelta`。
- verify：mock `WebSearchService` + mock SSE，`streamGenerateEvents` 先产出 `.searching`/`.searchDone`
  再产出若干 `.answerDelta`；`webSearch==nil` 时只产出 `.answerDelta`。

### T3.3 连线与 UI（`ChatView` / `WorkspaceChatService`）
- `WorkspaceChatService` 增 `streamAskEvents(...)`：先记录用户提问（不丢问题），返回 `AsyncThrowingStream<LLMStreamEvent>`；
  流正常结束后调用 `finalizeStreamedAnswer` 记录累计的 answer 文本。
- `ChatView.runStream`：联网开启（有 MX Key）时改走 `streamAskEvents`——
  - `.searching`/`.searchDone`：渲染成独立的「思考气泡」（如「🔎 正在检索：茅台 舆情」「已汇总 12 条研报：偏多」），
    让用户实时看到 LLM 在查什么；
  - `.answerDelta`：累加进 `streamingText`，逐字流式显示。
  - 出错路径仍保存已记录的用户提问。
- 未开启联网：保持现有纯流式体验不变。
- verify：真机——开启联网提问，先出思考气泡（含检索关键词）再流式出答案；关闭联网仍逐字流。

---

## 四、Claude(Anthropic) 协议适配 + 自定义模型

### T4.1 新增 `QA/AnthropicLLMService.swift`（`LLMService` 第二实现）
- Messages API 线格式（无 SDK，纯 `URLSession`）：
  - Endpoint：`https://api.anthropic.com/v1/messages`
  - Header：`x-api-key: <key>`（**不是** Bearer）、`anthropic-version: 2023-06-01`、`Content-Type: application/json`
  - Body：`{ "model", "max_tokens"(必填), "system"(顶层字符串), "messages":[{role,content}], "tools"?, "stream"? }`
  - 工具轮次：assistant 返回 `content` 数组含 `{"type":"tool_use","id","name","input"}`；
    回填时用户消息 `content:[{"type":"tool_result","tool_use_id","content"}]`。
    `tool` 的 schema 与 OpenAI 版一致（`web_search`，参数 `query`），但结构是 Anthropic 的
    `{"name","description","input_schema"}`（非 `{"type":"function","function":{...}}`）。
  - SSE 流：事件 `content_block_delta` 且 `delta.type=="text_delta"` 取 `delta.text`；
    `message_delta` 带 `stop_reason`；`message_stop` 结束。
- 模型 id：`claude-sonnet-5`（默认）、`claude-opus-4-8`（更强）。注意 4.7+ 家族：
  **不要**传 `temperature`/`top_p`/`top_k`/`budget_tokens`（会 400）；`max_tokens` 必填，
  流式建议 64000。思考默认省略即可，无需 `thinking` 参数。
- 同样实现 `generate` / `streamGenerate` / `streamGenerateEvents`（工具轮次 + 情绪因子回填 + 流式），
  与 OpenAI 版行为对齐，仅线格式不同。
- verify：`AnthropicLLMService.parseSSE`（暴露纯函数）能从 `content_block_delta` 提取 text；
  工具调用解析能从 `tool_use.input` 取 `query`；非 2xx→结构化错误（401→unauthorized，429→rateLimited）。

### T4.2 `LLMConfigurationStore`：协议开关 + 自定义模型
- `Settings` 增 `apiProtocol: enum { openai, anthropic }`（持久化，默认 openai）。
- `makeService(settings:)` 按 `apiProtocol` 返回 `OpenAICompatibleLLMService` 或 `AnthropicLLMService`
  （返回类型抽象成 `any LLMService`）。联网工具轮次逻辑对两者一致。
- `presets` 增 Claude 项：`Anthropic · claude-sonnet-5`、`Anthropic · claude-opus-4-8`
  （`endpoint=https://api.anthropic.com/v1/messages`，`webCapable=false`——联网走本地 mx 工具轮次）。
- 自定义模型配置项：设置页允许手填 endpoint / model / 协议（openai|anthropic），覆盖预设。
- verify：`LLMConfigurationStore` 单测——选 anthropic 预设 → `makeService` 造出 `AnthropicLLMService`；
  选 openai → `OpenAICompatibleLLMService`；自定义手填能落库并回读。

### T4.3 设置页（`ChatView` 设置区）
- 预设列表加 Claude 两项；新增「协议」选择器（OpenAI 兼容 / Anthropic）；endpoint/model 可自定义。
- 「联网检索」区：`MX 妙想 API Key`（原 Tavily Key 输入框改名），footer 说明：
  开启后走 mx-search 拉取研报/公告/舆情作情绪因子；Key 存本机 Keychain，仅本人使用。
- verify：真机——切到 Anthropic + 填 x-api-key + `claude-sonnet-5` 能正常问答与流式；
  开启联网 + 填 MX Key，能触发工具轮次并展示检索思考动作。

---

## 五、测试与验收

- 纯函数单测：`MXSearchService.parse`、情绪因子 `formatSearchResults` 汇总、
  `AnthropicLLMService` SSE/工具解析、`LLMStreamEvent` 分支、`makeService` 协议选择。
- 既有 `PromptBuilderTests`/`LLMServiceTests`/`WorkspaceChatServiceTests` 走默认参数路径，断言不变。
- 真机待验证（本环境无 Xcode / 真机）：
  1. OpenAI 协议 + 关闭联网：逐字流式（回归）。
  2. OpenAI 协议 + 开启联网(MX Key)：先出「正在检索：xxx」思考气泡与情绪汇总，再流式出带情绪因子的回答。
  3. Anthropic 协议 + `claude-sonnet-5`：问答 + 流式正常；开启联网同样走 mx 工具轮次。
  4. 自定义模型（endpoint/model/协议）保存后生效。

---

## 附：给 sonnet5 的实现顺序建议

1. T1（MXSearchService 替换）→ verify parse 单测
2. T2（情绪因子格式化 + 提示词）→ verify 渲染单测
3. T3（LLMStreamEvent + 流式工具轮次 + UI 思考气泡）→ verify 事件流单测 + 真机
4. T4（Anthropic 服务 + 协议开关 + 自定义模型 + 设置页）→ verify 协议单测 + 真机
5. 全量回归既有单测，grep 清 Tavily 残留
