// StockWatch Watch App/Detail/QuoteDetailViewModel.swift
//
// FIX 1: quote polling interval is 3 s.
// FIX 4: replaced Timer.scheduledTimer with async Task loop so the poll
//         runs even when Digital Crown is active (RunLoop tracking-mode bug).
//         Each iteration awaits the network call, so concurrent stacking
//         is structurally impossible regardless of latency.

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
         refreshInterval: TimeInterval = 3) {
        self.symbol          = symbol
        self.provider        = provider
        self.refreshInterval = refreshInterval
    }

    // MARK: — Lifecycle

    func startAutoRefresh() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchOnce()
                // Sleep between polls; if cancelled during sleep, loop exits cleanly
                try? await Task.sleep(nanoseconds: UInt64(
                    (self?.refreshInterval ?? 3) * 1_000_000_000
                ))
            }
        }
    }

    func stopAutoRefresh() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One-shot refresh (foreground resume kick, error retry).
    func refresh() {
        Task { [weak self] in await self?.fetchOnce() }
    }

    // MARK: — Private

    private let provider: any QuoteProvider
    private var pollTask: Task<Void, Never>?
    private var isFetching = false

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
