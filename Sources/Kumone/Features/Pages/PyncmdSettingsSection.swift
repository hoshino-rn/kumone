import Foundation
import SwiftUI

/// Server address, data-proxy switch and login sync for the self-hosted
/// pyncmd service, shown under Settings ▸ 音源 when the pyncmd source is
/// enabled (or its data proxy is on).
struct PyncmdSettingsSection: View {
    @AppStorage(PyncmdConfiguration.endpointsKey) private var endpointsText = ""
    @AppStorage(PyncmdConfiguration.tokenKey) private var token = ""
    @EnvironmentObject private var account: AccountStore
    @State private var proxyEnabled = PyncmdConfiguration.isDataProxyEnabled
    @State private var isImporting = false
    @State private var importMessage: String?
    @State private var isPushing = false
    @State private var pushMessage: String?
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

            Toggle("数据请求经 pyncmd", isOn: Binding(
                get: { proxyEnabled },
                set: { value in
                    proxyEnabled = value
                    PyncmdConfiguration.setDataProxyEnabled(value)
                    if value {
                        Task { await account.refreshLoginFromPyncmdIfNeeded(force: true) }
                    }
                }
            ))

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
            Text("多个地址用逗号或换行分隔，按顺序尝试。局域网可填电脑的局域网 IP；EasyTier 组网后填虚拟 IP（如 10.126.126.1:8090），外网也能访问。留空时使用构建时写入的默认地址。\n\n开启「数据请求经 pyncmd」后，Kumone 只用自己的登录获取歌单；歌曲详情、播放地址、歌词、搜索等其余请求都交给 pyncmd 服务器。pyncmd 需已登录同一账号，否则播放与账号操作会受限。\n\n代理开启时，App 会在启动/回前台时自动从 pyncmd 刷新本地登录态（每小时最多一次）；只刷新同一账号，不会自动切换账号。")
        }

        Section {
            Button {
                Task { await importLogin() }
            } label: {
                HStack(spacing: 8) {
                    Text("从 pyncmd 导入登录态")
                    if isImporting {
                        Spacer(minLength: 0)
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(isImporting)

            Button {
                Task { await pushLogin() }
            } label: {
                HStack(spacing: 8) {
                    Text("把 Kumone 登录同步到 pyncmd")
                    if isPushing {
                        Spacer(minLength: 0)
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(isPushing)

            if let importMessage {
                Text(importMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let pushMessage {
                Text(pushMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("登录同步")
        } footer: {
            Text("两个方向都可以：在 pyncmd 控制台登录后点「导入」，Kumone 直接采用该登录态；或先在 Kumone 登录，再把 Cookie 写回 pyncmd。同步后两边是同一个账号，不用重复扫码。登录态只在 Kumone 与你自己的 pyncmd 服务之间传输；若服务暴露在局域网或 EasyTier 中，请设置访问令牌。")
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

        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        for endpoint in endpoints {
            guard let url = endpoint.url(path: "api/health", query: []) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            if !trimmedToken.isEmpty {
                request.setValue(trimmedToken, forHTTPHeaderField: "X-Pyncmd-Token")
            }
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch status {
                case 200:
                    let login = await loginStatus(for: endpoint, token: trimmedToken)
                    lines.append("\(endpoint.displayName)：连接成功\(login.map { " · \($0)" } ?? "")")
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

    private func importLogin() async {
        isImporting = true
        importMessage = nil
        defer { isImporting = false }

        do {
            let remote = try await PyncmdProxy.fetchSession()
            guard remote.loggedIn,
                  let uid = remote.uid, uid > 0,
                  let cookies = remote.cookies,
                  cookies["MUSIC_U"]?.isEmpty == false else {
                importMessage = "pyncmd 尚未登录，请先在 pyncmd 控制台登录"
                return
            }
            try await account.importLogin(accountID: uid, cookies: cookies, authorization: { true })
            await account.refreshLibrary()
            let nickname = (remote.nickname ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            importMessage = nickname.isEmpty ? "已导入 pyncmd 登录态" : "已导入：\(nickname)"
        } catch is CancellationError {
            return
        } catch {
            if let apiError = error as? MusicAPIError, case .needLogin = apiError {
                importMessage = "pyncmd 登录态已失效，请先在 pyncmd 控制台重新登录"
            } else {
                importMessage = "导入失败：\(error.localizedDescription)"
            }
        }
    }

    private func pushLogin() async {
        isPushing = true
        pushMessage = nil
        defer { isPushing = false }

        let cookies = MusicClient.shared.authenticationCookies()
        guard cookies["MUSIC_U"]?.isEmpty == false else {
            pushMessage = "请先在 Kumone 登录"
            return
        }
        do {
            try await PyncmdProxy.pushSession(cookies: cookies)
            pushMessage = "已把 Kumone 登录同步到 pyncmd"
        } catch is CancellationError {
            return
        } catch {
            if let apiError = error as? MusicAPIError, case .needLogin = apiError {
                pushMessage = "Kumone 登录已失效，请重新登录"
            } else {
                pushMessage = "同步失败：\(error.localizedDescription)"
            }
        }
    }

    private func loginStatus(for endpoint: PyncmdEndpoint, token: String) async -> String? {
        guard let url = endpoint.url(path: "api/login/status", query: []) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Pyncmd-Token")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { return "访问令牌无效" }
            guard status == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "登录状态未知"
            }
            guard object["logged_in"] as? Bool == true else {
                return "未登录，请先在 pyncmd 控制台登录"
            }
            let nickname = (object["nickname"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return nickname.isEmpty ? "已登录" : "已登录：\(nickname)"
        } catch {
            return "登录状态获取失败"
        }
    }
}
