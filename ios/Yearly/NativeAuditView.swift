import SwiftUI

struct NativeAuditView: View {
    @ObservedObject var session: NativeSession
    var resourceType: String?
    var resourceID: String?
    @State private var selectedType = ""
    @State private var logs: [NativeAuditLog] = []
    @State private var total = 0
    @State private var page = 0
    @State private var busy = false
    @State private var error = ""
    private var type: String { resourceType ?? selectedType }
    private var query: String { type + "|" + (resourceID ?? "") }

    var body: some View {
        List {
            if resourceType == nil {
                Picker("内容类型", selection: $selectedType) {
                    Text("全部类型").tag("")
                    ForEach(NativeAuditLabels.resources.keys.sorted(), id: \.self) { key in
                        Text(NativeAuditLabels.resources[key]!).tag(key)
                    }
                }
            }
            Section {
                Text(session.isAdmin ? "显示所有账户的修改记录。" : "显示自己内容的修改记录及当前账户的操作。")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(logs) { log in
                    DisclosureGroup {
                        ForEach(log.changes.keys.sorted(), id: \.self) { key in
                            let change = log.changes[key]!
                            VStack(alignment: .leading, spacing: 5) {
                                Text(NativeAuditLabels.fields[key, default: key]).font(.subheadline.bold())
                                if change.changed == true && key == "password" { Text("已更新密码") }
                                else {
                                    Text("修改前 · " + (change.before?.display ?? "空")).foregroundStyle(.secondary)
                                    Text("修改后 · " + (change.after?.display ?? "空"))
                                }
                            }.font(.caption).textSelection(.enabled).padding(.vertical, 4)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(log.actor_name).font(.subheadline.bold())
                            Text(log.label).font(.subheadline)
                            Text(NativeAuditLabels.time(log.created_at)).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
                if logs.isEmpty && !busy && error.isEmpty {
                    Text("暂无修改日志。历史操作从升级后开始记录。 ").foregroundStyle(.secondary)
                }
                if logs.count < total && !busy { Button("加载更多记录") { Task { await load(more: true) } } }
            }
            if busy { ProgressView("正在读取修改日志…") }
            if !error.isEmpty {
                Text(error).foregroundStyle(.red)
                Button("重试") { Task { await load(more: page > 0) } }
            }
        }
        .scrollContentBackground(.hidden).background(NativeTheme.background)
        .navigationTitle("修改日志")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: query) { await load() }
        .refreshable { await load() }
    }
    private func load(more: Bool = false) async {
        let requested = query
        let actor = session.account?.id
        let next = more ? page + 1 : 1
        busy = true; error = ""
        if !more { logs = []; total = 0; page = 0 }
        defer { if query == requested { busy = false } }
        var params = [URLQueryItem(name: "page", value: String(next))]
        if !type.isEmpty { params.append(URLQueryItem(name: "resource_type", value: type)) }
        if let resourceID { params.append(URLQueryItem(name: "resource_id", value: resourceID)) }
        var path = URLComponents(); path.queryItems = params
        do {
            let result: NativeAuditPage = try await session.get("/audit-logs?" + (path.percentEncodedQuery ?? ""))
            guard !Task.isCancelled, query == requested, session.account?.id == actor else { return }
            logs = more ? logs + result.items : result.items
            total = result.total; page = next
        } catch { if !Task.isCancelled && query == requested { self.error = friendly(error) } }
    }
}
