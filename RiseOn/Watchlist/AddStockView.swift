import SwiftUI

struct AddStockView: View {
    @ObservedObject var viewModel: WatchlistViewModel
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var results: [StockSearchResult] = []
    @State private var isSearching = false
    @State private var debounceTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    private let searchService = StockSearchService()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                Divider()
                resultsView
            }
            .navigationTitle("添加自选股")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        isPresented = false
                    }
                    .accessibilityLabel("取消添加")
                }
            }
            .onAppear {
                fieldFocused = true
            }
        }
    }

    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("名称、拼音缩写或代码", text: $query)
                .focused($fieldFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("搜索股票输入框")
                .onChange(of: query) { _, newValue in
                    scheduleSearch(newValue)
                }

            if isSearching {
                ProgressView()
                    .scaleEffect(0.8)
            } else if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                    viewModel.clearError()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var resultsView: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            placeholderView
        } else if results.isEmpty && !isSearching {
            noResultsView
        } else {
            List(results) { result in
                Button {
                    add(result)
                } label: {
                    resultRow(result)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("添加 \(result.name)，代码 \(result.code)")
            }
            .listStyle(.plain)
        }
    }

    private var placeholderView: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("搜索股票名称或代码")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("支持中文名称、拼音缩写、股票代码")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("请输入股票名称或代码进行搜索")
    }

    private var noResultsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.circle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("未找到 \(query)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("请尝试其他名称或直接输入股票代码")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            if let error = viewModel.addError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func resultRow(_ result: StockSearchResult) -> some View {
        HStack(spacing: 12) {
            Text(result.market.uppercased())
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(result.market == "sh" ? Color.red : Color.blue, in: RoundedRectangle(cornerRadius: 3))

            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .foregroundStyle(.primary)
                Text(result.code)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if viewModel.codes.contains(result.code) {
                Text("已添加")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.4)))
            } else {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 4)
    }

    private func scheduleSearch(_ keyword: String) {
        debounceTask?.cancel()
        viewModel.clearError()

        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }

        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else {
                return
            }
            await performSearch(trimmed)
        }
    }

    @MainActor
    private func performSearch(_ keyword: String) async {
        isSearching = true
        results = await searchService.search(keyword: keyword)
        isSearching = false
    }

    private func add(_ result: StockSearchResult) {
        viewModel.add(code: result.code, name: result.name)
        if viewModel.addError == nil {
            isPresented = false
        }
    }
}
