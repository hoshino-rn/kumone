import Foundation
import SwiftUI

/// Server address and optional access token for the self-hosted pyncmd
/// service, shown under Settings ▸ 音源 when the pyncmd source is enabled.
struct PyncmdSettingsSection: View {
    @AppStorage(PyncmdConfiguration.endpointsKey) private var endpointsText = ""
    @AppStorage(PyncmdConfiguration.tokenKey) private var token = ""
    @State private var isTesting = false
    @State private var testResult: String?

    var body: some View {
        Section {
            TextField("服务器地址", text: $endpointsText, axis: .vertical)
                .lineLimit(1...3)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif

            SecureField("访问令牌（可选）", text: $token)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

            Button {
                Task { await testConnections() }
            } label: {
                HStack(spacing: 8) {
                    Text("测试连接")
                    if isTesting {
                        Spacer(minLength: 0)
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(isTesting)

            if let testResult {
                Text(testResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("pyncmd 服务器")
        } footer: {
            Text("多个地址用逗号或换行分隔，按顺序尝试。局域网可填电脑的局域网 IP；EasyTier 组网后填虚拟 IP（如 10.126.126.1:8090），外网也能访问。留空时使用构建时写入的默认地址。")
        }
    }

    private func testConnections() async {
        let endpoints = PyncmdConfiguration.endpoints(from: endpointsText)
        guard !endpoints.isEmpty else {
            testResult = "请先填写服务器地址"
            return
        }

        isTesting = true
        defer { isTesting = false }

        var lines: [String] = []
        for endpoint in endpoints {
            guard let url = endpoint.url(path: "api/health", query: []) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedToken.isEmpty {
                request.setValue(trimmedToken, forHTTPHeaderField: "X-Pyncmd-Token")
            }
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch status {
                case 200:
                    lines.append("\(endpoint.displayName)：连接成功")
                case 401:
                    lines.append("\(endpoint.displayName)：需要访问令牌（HTTP 401）")
                default:
                    lines.append("\(endpoint.displayName)：HTTP \(status)")
                }
            } catch {
                lines.append("\(endpoint.displayName)：\(error.localizedDescription)")
            }
        }
        testResult = lines.isEmpty ? "没有可用的服务器地址" : lines.joined(separator: "\n")
    }
}
