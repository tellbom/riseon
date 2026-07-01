// StockWatch Watch App/Detail/QuoteDetailViewModel.swift
//
// FIX 1: quote polling interval is 2 s.
// FIX 4: replaced Timer.scheduledTimer with async Task loop so the poll
//         runs even when Digital Crown is active (RunLoop tracking-mode bug).
//         Each iteration awaits the network call, so concurrent stacking
//         is structurally impossible regardless of latency. Poll cadence is
//         measured from request start, so request time does not add to 2 s.

import Combine
import Foundation

@MainActor
final class QuoteDetailViewModel: ObservableObject {

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(Quote)
        case error(String)
    }

    @Published private(set) var state: LoadState = .idle

    let symbol: StockSymbol
    let refreshInterval: TimeInterval

    init(symbol: StockSymbol,
         provider: any QuoteProvider,
         refreshInterval: TimeInterval = 2) {
        self.symbol          = symbol
        self.provider        = provider
        self.refreshInterval = refreshInterval
    }

    // MARK: — Lifecycle

    func startAutoRefresh() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var isFirstPoll = true
            while !Task.isCancelled {
                let startedAt = Date()
                if isFirstPoll {
                    await self?.fetchWithRetry()
                    isFirstPoll = false
                } else {
                    await self?.fetchOnce()
                }
                guard !Task.isCancelled else { break }
                await self?.sleepForRemainingInterval(since: startedAt)
            }
        }
    }

    func stopAutoRefresh() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One-shot refresh (foreground resume kick, error retry).
    func refresh() {
        if pollTask == nil {
            startAutoRefresh()
            return
        }
        Task { [weak self] in await self?.fetchOnce() }
    }

    // MARK: — Private

    private let provider: any QuoteProvider
    private var pollTask: Task<Void, Never>?
    private var isFetching = false

    private func sleepForRemainingInterval(since startedAt: Date) async {
        let remaining = refreshInterval - Date().timeIntervalSince(startedAt)
        guard remaining > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }

    private func fetchWithRetry() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        if case .idle = state { state = .loading }

        do {
            let quote = try await provider.fetchQuote(for: symbol)
            state = .loaded(quote)
        } catch {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            do {
                let quote = try await provider.fetchQuote(for: symbol)
                state = .loaded(quote)
            } catch {
                if case .loaded = state { } else {
                    state = .error(error.localizedDescription)
                }
            }
        }
    }

    private func fetchOnce() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        // Don't show spinner if we already have data
        if case .idle = state { state = .loading }

        do {
            let quote = try await provider.fetchQuote(for: symbol)
            state = .loaded(quote)
        } catch {
            // Keep stale data visible; only show error on first load
            if case .loaded = state { } else {
                state = .error(error.localizedDescription)
            }
        }
    }

    deinit { pollTask?.cancel() }
}
