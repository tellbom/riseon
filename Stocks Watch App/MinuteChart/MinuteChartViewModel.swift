// StockWatch Watch App/MinuteChart/MinuteChartViewModel.swift
//
// FIX 1: minute-chart polling interval is 3 s.
// FIX 4: async Task poll loop — immune to RunLoop tracking-mode blocking.
//        Poll cadence is measured from request start, so request time does not
//        add to the configured interval.

import Combine
import Foundation

@MainActor
final class MinuteChartViewModel: ObservableObject {

    enum LoadState: Equatable {
        case waiting           // previousClose not yet available
        case loading
        case loaded(MinuteData)
        case error(String)
    }

    @Published private(set) var state: LoadState = .waiting

    let symbol: StockSymbol
    let refreshInterval: TimeInterval

    private var previousClose: Double? = nil
    private let minuteProvider = TencentMinuteProvider()
    private var pollTask: Task<Void, Never>?
    private var isFetching = false

    init(symbol: StockSymbol, refreshInterval: TimeInterval = 3) {
        self.symbol          = symbol
        self.refreshInterval = refreshInterval
    }

    // MARK: — Called by view when page-0 quote first arrives

    func quoteDidLoad(previousClose: Double) {
        self.previousClose = previousClose
    }

    // MARK: — Lifecycle

    func startAutoRefresh() {
        guard previousClose != nil, pollTask == nil else { return }
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

    func refresh() {
        if pollTask == nil {
            startAutoRefresh()
            return
        }
        Task { [weak self] in await self?.fetchOnce() }
    }

    // MARK: — Fetch

    private func sleepForRemainingInterval(since startedAt: Date) async {
        let remaining = refreshInterval - Date().timeIntervalSince(startedAt)
        guard remaining > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
    }

    private func fetchWithRetry() async {
        guard let pc = previousClose else { return }
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        if case .waiting = state { state = .loading }

        do {
            let data = try await minuteProvider.fetchMinuteData(for: symbol, previousClose: pc)
            if data.points.isEmpty {
                if case .loaded = state { } else { state = .error("暂无分时数据") }
            } else {
                state = .loaded(data)
            }
        } catch {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            do {
                let data = try await minuteProvider.fetchMinuteData(for: symbol, previousClose: pc)
                if data.points.isEmpty {
                    if case .loaded = state { } else { state = .error("暂无分时数据") }
                } else {
                    state = .loaded(data)
                }
            } catch {
                if case .loaded = state { } else {
                    state = .error(error.localizedDescription)
                }
            }
        }
    }

    private func fetchOnce() async {
        guard let pc = previousClose else { return }
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        if case .waiting = state { state = .loading }

        do {
            let data = try await minuteProvider.fetchMinuteData(for: symbol, previousClose: pc)
            if data.points.isEmpty {
                if case .loaded = state { } else { state = .error("暂无分时数据") }
            } else {
                state = .loaded(data)
            }
        } catch {
            if case .loaded = state { } else {
                state = .error(error.localizedDescription)
            }
        }
    }

    deinit { pollTask?.cancel() }
}
