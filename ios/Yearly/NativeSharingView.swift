import SwiftUI

struct NativeSharingView: View {
    @StateObject private var store: NativeSharingStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var start: Date
    @State private var end: Date
    @State private var hours = 24
    @State private var confirming = false
    @State private var revoking: NativeShare?
    @State private var copied = false
    init(session: NativeSession, day: String? = nil) {
        _store = StateObject(wrappedValue: NativeSharingStore(session: session))
        let date = day.flatMap(NativeDay.date) ?? Date()
        _start = State(initialValue: date); _end = State(initialValue: date)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("分享家庭时光") {
                    TextField("分享标题（可留空）", text: $title)
                    DatePicker("开始日期", selection: $start, displayedComponents: .date)
                    DatePicker("结束日期", selection: $end, displayedComponents: .date)
                    Picker("链接有效期", selection: $hours) {
                        Text("1 小时").tag(1); Text("24 小时").tag(24)
                        Text("3 天").tag(72); Text("7 天").tag(168)
                    }
                    Text("链接包含所选日期内允许分享的全部家庭回忆，不受时间线人物、搜索和类型筛选影响；该日期内以后新增的可分享内容也会出现。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("收到链接的人无需登录，只能查看预览。原件下载和编辑不开放，实况图沿用现有完整播放方式。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button { confirming = true } label: {
                        Label("创建限时分享链接", systemImage: "link")
                    }.disabled(store.busy || NativeDay.string(start) > NativeDay.string(end) || !store.session.canEdit)
                }
                if let created = store.created {
                    Section("刚创建的分享") {
                        TimelineView(.periodic(from: .now, by: 15)) { _ in
                            VStack(alignment: .leading, spacing: 12) {
                                if let url = created.link(site: store.session.site) {
                                    ShareLink(item: url) { Label("发送给亲友", systemImage: "square.and.arrow.up") }
                                    Button {
                                        UIPasteboard.general.setItems([["public.url": url, "public.utf8-plain-text": url.absoluteString]], options: [.localOnly: true, .expirationDate: created.expiration ?? Date()])
                                        copied = true
                                    } label: { Label(copied ? "已复制链接" : "复制分享链接", systemImage: "doc.on.doc") }
                                    Text("链接仅在本次创建后提供，关闭前请复制或分享。以后可以在分享记录中撤销。")
                                        .font(.footnote).foregroundStyle(.secondary)
                                } else { Text(created.revoked ? "这条链接已撤销" : "这条链接已到期") }
                            }
                        }
                    }
                }
                if store.busy { ProgressView("正在处理…") }
                if !store.error.isEmpty { Section { Text(store.error).foregroundStyle(.red); Button("重新加载记录") { Task { await store.load() } }.disabled(store.busy) } }
                Section("分享记录 · 最近 100 条") {
                    if store.shares.isEmpty && !store.busy { Text("还没有分享记录").foregroundStyle(.secondary) }
                    ForEach(store.shares) { share in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(share.title.isEmpty ? "家庭时光" : share.title).font(.headline)
                            Text("\(share.start_date) — \(share.end_date)").font(.caption)
                            TimelineView(.periodic(from: .now, by: 15)) { _ in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(share.revoked ? "已撤销" : share.usable ? "生效中" : "已到期").font(.caption).foregroundStyle(.secondary)
                                    if let date = share.expiration { Text("到期：\(date.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                                    if share.usable { Button("撤销链接", role: .destructive) { revoking = share }.disabled(store.busy) }
                                }
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("分享与管理")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { await store.load() }
            .refreshable { await store.load() }
            .onChange(of: store.created?.id) { _ in copied = false }
            .alert("确认分享日期范围", isPresented: $confirming) {
                Button("创建链接") { Task { await store.create(title: title, start: start, end: end, hours: hours) } }
                Button("返回检查", role: .cancel) { }
            } message: { Text("\(NativeDay.string(start)) 至 \(NativeDay.string(end)) 的全部可分享回忆。有效期 \(hours) 小时，持链接者可查看。") }
            .confirmationDialog("撤销后，收到链接的人将无法再打开", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible) {
                if let share = revoking { Button("撤销分享", role: .destructive) { Task { await store.revoke(share) }; revoking = nil } }
            }
        }
    }
}
