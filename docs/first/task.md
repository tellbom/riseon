# task.md — Build Order for the A-Share Viewer MVP

> Companion to `plan.md`. Tasks are grouped into milestones and ordered. Each task has an explicit
> **verify** check (per `CLAUDE.md` §4). Do not start coding a milestone until the previous one verifies.
> Keep changes surgical and minimal (`CLAUDE.md` §2–§3). When something is ambiguous, stop and ask.

Legend: `[ ]` todo · `[~]` in progress · `[x]` done

---

## M0 — Project Skeleton

- [ ] **0.1 Create Xcode project with iOS + watchOS app targets.**
  → verify: both targets build and launch (empty SwiftUI views) on simulator and on a real iPhone + Watch.
- [ ] **0.2 Add a `Shared` group/package** for `Models`, `QuoteProvider`, `Persistence`, included by both targets.
  → verify: a trivial shared type compiles and is referenceable from both the iOS and watchOS target.
- [ ] **0.3 Confirm free-Apple-ID on-device signing works** end to end (trust profile on both devices).
  → verify: both apps launch on the physical iPhone and Watch; note the 7-day expiry in the README per `plan.md` §9.

---

## M1 — Shared Models & Quote Provider (no UI)

- [ ] **1.1 Define `StockSymbol`** with code → market-prefix resolution (`sh`/`sz`/`bj`).
  → verify: unit tests — `600519→sh600519`, `000001→sz000001`, `300059→sz300059`, an `8…`/`4…` code → `bj…`.
- [ ] **1.2 Define `Quote`** (core fields) and `OrderBook`/`Level` (bid1–5, ask1–5 as price+volume).
  → verify: types compile; order book is optional on `Quote`.
- [ ] **1.3 Define `protocol QuoteProvider { func fetchQuote(for:) async throws -> Quote }`.**
  → verify: protocol compiles; nothing in `Shared` imports SwiftUI.
- [ ] **1.4 Implement `TencentQuoteProvider`** (HTTPS `qt.gtimg.cn`, GBK decode, defensive `~`-index parse).
  → verify: **parser unit test against a saved fixture string** (not the live network) extracts name, code,
    price, change %, change amount, time, and all 10 book levels. Missing-book fixture → price-only, no crash.
- [ ] **1.5 Live smoke test** of `fetchQuote` for one real code.
  → verify: a one-off test/CLI prints a sane quote for `600519`; Chinese name is not garbled (encoding correct).

> Guardrail: all `URLSession` usage stops here. No networking appears in any later UI task.

---

## M2 — Persistence (Watchlist Store)

- [ ] **2.1 Implement `WatchlistStore`** (array of codes in `UserDefaults`), usable by both targets.
  → verify: unit test — add, delete, dedupe, load returns the same set; survives a simulated relaunch.

---

## M3 — iPhone App (Watchlist Management)

- [ ] **3.1 Watchlist list view** (SwiftUI) backed by `WatchlistStore`.
  → verify: codes render; empty state shown when none.
- [ ] **3.2 Add-stock flow** (enter a code, validate format, persist).
  → verify: adding `600519`/`000001`/`300059` shows them in the list and they persist across relaunch.
- [ ] **3.3 Delete-stock flow** (swipe/edit).
  → verify: deleting removes the row and persists across relaunch.
  → verify (HIG): list editing matches Apple list conventions; basic VoiceOver labels present.

---

## M4 — iPhone ↔ Watch Sync (Watchlist Only)

- [ ] **4.1 WatchConnectivity session setup** on both targets (activate `WCSession`, handle delegate).
  → verify: session reaches `activated` on both sides; log state.
- [ ] **4.2 iPhone pushes watchlist via `updateApplicationContext`** on every change.
  → verify: editing on iPhone updates the context payload (assert delegate receipt on the Watch side).
- [ ] **4.3 Watch receives context, persists its own copy** via `WatchlistStore`.
  → verify: change the list on iPhone → it appears on the Watch; **kill the iPhone app, relaunch the Watch app → list still present.**

---

## M5 — Watch App (Viewing)

- [ ] **5.1 Watch list view** from the synced/persisted watchlist.
  → verify: shows the codes pushed from the phone; empty state when none.
- [ ] **5.2 Watch detail view** showing core fields: name, code, price, change %, change amount, update time.
  → verify: opening a stock shows all six core fields with real data from `QuoteProvider`.
- [ ] **5.3 Order book section** on detail: bid1–5 and ask1–5 with price + volume.
  → verify: book renders when present; **hidden cleanly when absent** (no empty rows, no crash).
- [ ] **5.4 Manual refresh** on detail (and list, optional).
  → verify: refresh re-fetches and updates the numbers + timestamp; loading and error states visible.
- [ ] **5.5 Switch between stocks on the Watch** (navigate back to list or swipe between details).
  → verify: I can move from one stock's detail to another's and each fetches its own quote.
- [ ] **5.6 HIG pass** on Watch UI (legible at a glance, standard Watch layout, Digital Crown scroll, color for up/down).
  → verify: readable on a real Watch; up/down direction is obvious; no clipped content.

---

## M6 — Standalone / Cellular Verification

- [ ] **6.1 Cellular fetch test.**
  → verify: with the iPhone powered off (or out of range), open the Watch app on cellular and successfully
    fetch a quote. This proves the data path does **not** depend on WatchConnectivity.
- [ ] **6.2 Offline behavior.**
  → verify: with no connectivity, the Watch shows a clear offline/error state and recovers on retry.

---

## M7 — Hardening & Docs

- [ ] **7.1 Error & rate-limit friendliness:** ensure manual-refresh only, batch where sensible, graceful failures.
  → verify: rapid refreshes degrade gracefully (no crash, clear messaging).
- [ ] **7.2 README** covering: how to build/run on device, the free-Apple-ID 7-day re-sign workflow,
    the data-source risk disclaimer, and how to swap `QuoteProvider`.
  → verify: a fresh reader can build, deploy, and understand the 7-day limitation from the README alone.

---

## Explicitly Out of Scope (do NOT build)

- Any trading: buy / sell / cancel / positions / balances / broker order routing.
- Any quant: strategies, stock selection, automated alerts/signals.
- Local server / always-on machine dependency.
- Charts (Phase 2), auto-refresh (Phase 2), second provider/fallback (Phase 2), SwiftData (later), App Store release.

If a task seems to require any of the above, **stop and ask** before implementing.
