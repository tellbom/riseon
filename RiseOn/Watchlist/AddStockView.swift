import SwiftUI

struct AddStockView: View {
    @ObservedObject var viewModel: WatchlistViewModel
    @Binding var isPresented: Bool

    @State private var inputCode = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如：600519", text: $inputCode)
                        .keyboardType(.numberPad)
                        .focused($fieldFocused)
                        .accessibilityLabel("股票代码输入框")
                        .onChange(of: inputCode) {
                            if viewModel.addError != nil {
                                viewModel.clearError()
                            }
                        }
                } header: {
                    Text("输入股票代码")
                } footer: {
                    footer
                }
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        confirmAdd()
                    }
                    .accessibilityLabel("确认添加股票")
                    .disabled(inputCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                fieldFocused = true
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let error = viewModel.addError {
            Text(error)
                .foregroundStyle(.red)
                .accessibilityLabel("错误：\(error)")
        } else {
            Text("支持沪（6开头）、深（0/3开头）、北（4/8开头）市场")
                .foregroundStyle(.secondary)
        }
    }

    private func confirmAdd() {
        viewModel.add(code: inputCode)
        if viewModel.addError == nil {
            isPresented = false
        }
    }
}
