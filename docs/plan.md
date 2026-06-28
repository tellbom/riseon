# plan.md — iPhone + Apple Watch A-Share Viewer (MVP)

> This is the authoritative plan referenced by `AGENTS.md`. Read this before implementing anything.
> No code is written yet. This document + `task.md` define what gets built and in what order.

---

## 1. Goal & Non-Goals

**Goal.** A personal-use MVP that lets one user view real-time quotes for a self-chosen
list of A-share stocks on an Apple Watch. The iPhone app manages the watchlist; the Watch app
displays the data and can fetch it independently over eSIM/cellular.

**This is explicitly NOT:**

- Not a quantitative trading system. No strategies, no stock-selection models, no signals/alerts.
- Not an automated trading system. No buy/sell/cancel, no positions, no account balance, no broker order routing.
- Not a server/backend project. No local network server, no always-on iMac, no self-hosted proxy.
- Not an App Store release (for now). Target is on-device debugging and personal daily use.

These non-goals are hard constraints, not "later" items. The only forward-looking allowance is a
**clean extension point** in the data layer (see §4) so a paid/broker provider *could* be added later —
but no such provider is implemented in this project.

---

## 2. Platforms, Tooling, Conventions

| Item | Decision |
|---|---|
| UI framework | SwiftUI (both iOS and watchOS targets) |
| iOS ↔ watchOS sync | WatchConnectivity (`WCSession`) |
| Networking | `URLSession` (async/await) |
| Persistence | `UserDefaults` / `@AppStorage` for MVP; SwiftData reserved for a later phase |
| Min OS | iOS 17 / watchOS 10 (async/await, modern SwiftUI navigation) — adjust to your devices |
| Language | Swift, Swift Concurrency (`async`/`await`, `actor` for the network layer) |
| Architecture | Light MVVM. Views are dumb; view models own state; a `QuoteProvider` owns all network I/O |

**Project layout (single Xcode project, multiple targets):**

```
StockWatch/                    # Xcode project
├── StockWatch/                # iOS app target
│   ├── App/                   # @main, app entry
│   ├── Watchlist/             # add/delete/list UI + view model
│   ├── Sync/                  # WatchConnectivity (iOS side)
│   └── Resources/
├── StockWatch Watch App/      # watchOS app target
│   ├── App/
│   ├── List/                  # synced watchlist UI
│   ├── Detail/                # quote + order book UI
│   ├── Sync/                  # WatchConnectivity (watch side)
│   └── Resources/
└── Shared/                    # code shared by both targets (Swift package or shared group)
    ├── Models/                # Stock, Quote, OrderBook, etc.
    ├── QuoteProvider/         # protocol + implementations  ← all network logic lives here
    └── Persistence/           # watchlist store
```

> **Rule (from `CLAUDE.md` §3):** all market-data network logic lives in `Shared/QuoteProvider`.
> No `URLSession` calls inside any SwiftUI View. UI talks to view models; view models talk to a `QuoteProvider`.

---

## 3. Architecture & Data Flow

Two **independent** channels. Do not conflate them.

```
┌─────────────────────┐      WatchConnectivity (watchlist only)     ┌─────────────────────┐
│   iPhone App        │  ── updateApplicationContext(watchlist) ──▶ │   Watch App         │
│                     │                                             │                     │
│  • manage watchlist │                                             │  • show watchlist   │
│  • persist locally  │                                             │  • persist own copy │
│  • push to watch    │                                             │  • fetch quotes ────┼──┐
└─────────────────────┘                                             └─────────────────────┘  │
                                                                                              │ URLSession
                                                                                              ▼
                                                                            ┌──────────────────────────┐
                                                                            │  Public quote API        │
                                                                            │  (Tencent qt.gtimg.cn)   │
                                                                            └──────────────────────────┘
```

Key consequence of the eSIM/standalone requirement: **the Watch fetches market data itself.**
It must never depend on the iPhone being nearby to get quotes. WatchConnectivity is used *only* to
carry the watchlist configuration, which is small, infrequently changed, and "latest-state-wins".

---

## 4. Data Source Layer (`QuoteProvider`)

This is the most important and most fragile part of the system, so it is isolated behind a protocol.

### 4.1 Protocol

```
protocol QuoteProvider {
    /// Fetch a full snapshot (price fields + level-1 order book) for one symbol.
    func fetchQuote(for symbol: StockSymbol) async throws -> Quote
}
```

`Quote` carries the **core fields** (required by the spec) and the **order book** (best-effort):

- Core: `name`, `code`, `price`, `changePercent`, `changeAmount`, `updatedAt`
- Order book: `bids: [Level]` (买一…买五), `asks: [Level]` (卖一…卖五), where `Level = (price, volume)`

Both targets depend on the protocol, never on a concrete implementation directly (inject it).

### 4.2 Recommended primary implementation: `TencentQuoteProvider`

Chosen because it returns the **full level-1 order book in one request**, is free, requires no token,
and is reachable over HTTPS.

- Endpoint: `https://qt.gtimg.cn/q={prefix}{code}` (e.g. `https://qt.gtimg.cn/q=sh600519`)
- Batchable: comma-separate symbols in one request (`q=sh600519,sz000001,sz300059`)
- Response: one `v_{prefix}{code}="...";` line per symbol; the payload is `~`-delimited.

**Symbol prefix resolution** (`StockSymbol` should encapsulate this):

| Code starts with | Market | Prefix |
|---|---|---|
| `6` | Shanghai (沪) | `sh` |
| `0`, `3` | Shenzhen (深) | `sz` |
| `4`, `8` | Beijing (北交所) | `bj` |

**Field map** (index into the `~`-split array — verified against current responses):

| Index | Meaning |
|---|---|
| 1 | name (名称) |
| 2 | code |
| 3 | current price (现价) |
| 4 | previous close (昨收) |
| 5 | open (今开) |
| 9 / 10 | bid1 price / bid1 volume (买一价/量) |
| 11–18 | bid2…bid5 (price, volume pairs) |
| 19 / 20 | ask1 price / ask1 volume (卖一价/量) |
| 21–28 | ask2…ask5 (price, volume pairs) |
| 30 | timestamp `yyyyMMddHHmmss` |
| 31 | change amount (涨跌额) |
| 32 | change percent (涨跌幅 %) |
| 33 / 34 | high / low |

Volumes are in 手 (lots; 1 lot = 100 shares). Display unit is a UI decision.

> Parse defensively: do not hard-code an exact field count. Index into the array with bounds checks,
> and treat the order book as optional — if those indices are missing/empty, render price-only and
> hide the book. Field positions can change without notice (see §8).

### 4.3 Fallback / replaceability

The reason for the protocol is that any single free source may break. Plan for at least one alternative
behind the same protocol, addable later without touching UI:

- **Sina** (`https://hq.sinajs.cn/list=sh600519`) — also exposes 5-level book, but returns **GB2312/GBK**
  text and historically requires a `Referer: https://finance.sina.com.cn` header; otherwise 403. More
  fragile to wire up; keep as secondary.
- **Eastmoney** (`push2.eastmoney.com/api/qt/stock/get`) — JSON, cleaner to parse; field availability varies.

MVP ships **one** provider (Tencent). The others are documented here as the designed escape hatch, not built now.

### 4.4 Encoding & transport notes (must handle)

- **Encoding:** Tencent and Sina return **GBK-encoded** bytes (Chinese names). Decode with
  `String(data:, encoding:)` using GB 18030 / GBK, not UTF-8, or names will be garbled.
- **Transport (ATS):** use the **HTTPS** form of the Tencent endpoint so no App Transport Security
  exception is needed. If a fallback provider is HTTP-only, that target would need an ATS exception —
  avoid if possible.
- **Caching:** these are snapshot endpoints; set `URLRequest.cachePolicy` to reload to avoid stale data.

---

## 5. iOS ↔ watchOS Sync (Watchlist Only)

The watchlist is small and "latest wins", so use **`updateApplicationContext`** (not `sendMessage`):

- It does not require the counterpart app to be reachable/foreground.
- It overwrites with the latest state, which is exactly the watchlist semantics we want.
- The Watch receives it via the `WCSessionDelegate` callback and persists its own copy.

Design rules:

1. iPhone is the source of truth for *editing* the watchlist. Every change persists locally **and** calls `updateApplicationContext`.
2. The Watch keeps its **own persisted copy** so it works on launch before any new context arrives (and standalone on cellular).
3. Provide a manual "re-sync from phone" affordance as a safety net (WatchConnectivity delivery is best-effort/eventual).

---

## 6. Watch Independent Networking (eSIM / Cellular)

- The Watch app fetches quotes directly with `URLSession`; it must not route through the phone.
- On a cellular Apple Watch, `URLSession` requests work when the paired iPhone is absent, provided the
  Watch has connectivity (cellular or its own Wi-Fi). No special routing code is needed — just do not
  use WatchConnectivity as a data transport.
- Refresh model for MVP: **manual refresh** (pull-to-refresh / refresh button) on both the list and detail
  pages. No background polling, no auto-timer in the MVP (keeps it simple and battery-friendly).

---

## 7. Persistence

- **MVP:** watchlist stored as an array of codes in `UserDefaults` (mirror via `@AppStorage` where convenient),
  on both targets.
- Keep a single `WatchlistStore` type in `Shared/Persistence` used by both targets.
- **Later (optional):** migrate to SwiftData if the watchlist grows structured fields (notes, sort order,
  groups). Not in MVP.

---

## 8. Risks & Mitigations

Free public quote interfaces are convenient but come with real risks. Stated explicitly per requirement:

| Risk | Likelihood | Mitigation |
|---|---|---|
| **Instability / downtime** of the free endpoint | Medium | Provider isolated behind `QuoteProvider`; show clear error + retry in UI; fallback provider designed in. |
| **Rate limiting / IP bans** on bursty polling | Medium | MVP is manual-refresh only; batch symbols into one request; no tight polling loop. |
| **Field/format changes** (positions shift) | Medium | Defensive index-based parsing with bounds checks; order book treated as optional; parser unit-tested with fixtures. |
| **Encoding** (GBK, not UTF-8) | High if ignored | Decode explicitly as GB 18030/GBK. |
| **ATS / HTTP origin** | Low | Use HTTPS endpoint; avoid HTTP-only fallbacks. |
| **Terms-of-service / authorization uncertainty** | — | These are undocumented, unofficial endpoints. Use is personal, low-volume, non-commercial, no redistribution. Do not ship to the App Store on top of them without revisiting licensing. |
| **Watch connectivity gaps** (no cellular/Wi-Fi) | Medium | Clear "no data / offline" state; cached last-known quote optional later. |

> Honest framing: because the data source is an undocumented free interface, **assume it can break or
> change at any time.** The architecture's main job is to make swapping it cheap.

---

## 9. Free Apple ID Signing — the 7-Day Expiry (Important)

This project targets on-device personal use **without** a paid Apple Developer Program membership. With a
free Apple ID, Xcode issues a **Personal Team** provisioning profile that **expires after 7 days**.

Practical consequences:

- After ~7 days, the installed app **stops launching** ("app is no longer available" / untrusted) until it
  is **re-signed and re-deployed from Xcode**. This applies to the Apple Watch app as well.
- Free accounts have additional limits: a small number of app IDs can be registered per 7-day window, and
  only a few apps can have active provisioning at once. A paired iOS + watchOS app consumes more than one
  bundle ID, so keep the project to just this one app.
- On first launch on a device you must **trust the developer profile**:
  Settings → General → VPN & Device Management → trust your Apple ID.

**Accepted workflow for personal use:** every ~7 days, connect the iPhone (and Watch, paired) and
re-run the build from Xcode to refresh signing. This is expected and acceptable for this MVP. If the
re-signing cadence becomes annoying, the path out is a paid Apple Developer account (1-year profiles) —
out of scope here.

---

## 10. Phasing

**Phase 1 — MVP (this project):**
1. iPhone: add / delete / list / persist watchlist; push to Watch.
2. Watch: receive watchlist, list view, detail view with core fields + level-1 order book, manual refresh, switch between stocks.
3. One `QuoteProvider` (Tencent), defensively parsed, HTTPS, GBK-decoded.

**Phase 2 — later (planned, not built now):**
- Intraday line chart on the detail page (Tencent minute endpoint exists).
- A second `QuoteProvider` + provider selection/fallback.
- Auto-refresh option, complications, richer persistence (SwiftData).

**Future extension point (designed, deliberately NOT implemented):**
- The `QuoteProvider` boundary is where a paid data source could later plug in. No trading, brokerage,
  order, or account capability is part of this codebase — those remain non-goals.

---

## 11. Definition of Done (MVP)

- On iPhone: I can add `600519`, `000001`, `300059`, delete one, and the list persists across relaunches.
- The Watch shows the same list after a sync, and keeps showing it after relaunch with the phone absent.
- Tapping a stock on the Watch shows name, code, price, change %, change amount, update time, and (when
  available) bid1–5 / ask1–5 with price and volume.
- Manual refresh updates the numbers. I can switch to another stock on the Watch.
- The Watch fetches data over cellular with the phone powered off.
- All network logic lives in `QuoteProvider`; no `URLSession` in any View.
