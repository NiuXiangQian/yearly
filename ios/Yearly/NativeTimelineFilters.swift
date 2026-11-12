import SwiftUI

struct NativeTimelineFilters: View {
    @ObservedObject var store: NativeTimelineStore
    @NativeDismiss private var dismiss
    @State private var uploaderID: Int?
    @State private var selected: Set<Int>
    @State private var mediaType: String
    @State private var useDateRange: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var uploaderSearch = ""

    init(store: NativeTimelineStore) {
        self.store = store
        _uploaderID = State(initialValue: store.uploaderID)
        _selected = State(initialValue: store.selected)
        _mediaType = State(initialValue: store.mediaType)
        _useDateRange = State(initialValue: store.useDateRange)
        _start = State(initialValue: store.startDate)
        _end = State(initialValue: store.endDate)
    }

    var body: some View {
        NavigationStack {
            NativeSegmentPages(titles: ["影像", "人物与宠物", "日期"], pages: [
                AnyView(Form {
                Section("影像类型") {
                    Picker("影像类型", selection: $mediaType) {
                        Text("全部").tag("")
                        Text("照片").tag("photo")
                        Text("实况").tag("live_photo")
                        Text("视频").tag("video")
                    }.pickerStyle(.segmented).frame(minHeight: 44)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section {
                    NativeFilterOption(title: "全部上传人", selected: uploaderID == nil) { uploaderID = nil }
                    if store.uploaders.count > 8 {
                        TextField("搜索上传人", text: $uploaderSearch).autocorrectionDisabled()
                    }
                    ForEach(store.uploaders.filter { uploaderSearch.isEmpty || ($0.displayName.localizedCaseInsensitiveContains(uploaderSearch) || $0.username.localizedCaseInsensitiveContains(uploaderSearch)) }) { uploader in
                        NativeFilterOption(title: uploader.displayName + (uploader.id == store.session.account?.id ? "（我）" : ""), selected: uploaderID == uploader.id) { uploaderID = uploader.id }
                    }
                    if store.uploadersLoading { ProgressView("正在读取上传人…") }
                    if !store.uploadersError.isEmpty {
                        Text(store.uploadersError).font(.footnote).foregroundStyle(.red)
                        Button("重新读取上传人") { Task { await store.loadUploaders(refresh: true) } }
                            .buttonStyle(NativeActionStyle())
                    }
                } header: { Text("谁上传的") }
                }.scrollContentBackground(.hidden)),
                AnyView(Form {
                if !store.profiles.isEmpty {
                    Section {
                        NativeFilterOption(title: "全部家人与宠物", selected: selected.isEmpty) { selected = [] }
                        ForEach(store.profiles) { profile in
                            NativeFilterOption(title: profile.label, selected: selected.contains(profile.id)) {
                                if selected.contains(profile.id) { selected.remove(profile.id) }
                                else { selected.insert(profile.id) }
                            }
                        }
                    } header: { Text("影像中的家人 · 可多选") }
                }
                }.scrollContentBackground(.hidden)),
                AnyView(Form {
                Section {
                    Toggle("指定日期范围", isOn: $useDateRange)
                    if useDateRange {
                        DatePicker("开始日期", selection: $start, displayedComponents: .date)
                        DatePicker("结束日期", selection: $end, displayedComponents: .date)
                        if NativeDay.string(start) > NativeDay.string(end) {
                            Text("结束日期不能早于开始日期。").font(.footnote).foregroundStyle(.red)
                        }
                    }
                } header: { Text(store.usesUploadOrder ? "上传日期" : "归档日期") } footer: {
                    Text("包含开始和结束当天。日期未知的影像不参与日期范围筛选。")
                }
                }.scrollContentBackground(.hidden))
            ])
            .scrollContentBackground(.hidden).background(NativeTheme.background)
            .navigationTitle("筛选影像").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button("重置") { uploaderID = nil; selected = []; mediaType = ""; useDateRange = false }
                        .buttonStyle(NativeActionStyle()).frame(minWidth: 82)
                    Button {
                        store.uploaderID = uploaderID
                        store.selected = selected
                        store.mediaType = mediaType
                        store.useDateRange = useDateRange
                        store.startDate = start
                        store.endDate = end
                        dismiss()
                    } label: { Text("应用筛选").frame(maxWidth: .infinity) }
                    .buttonStyle(NativeActionStyle(kind: .primary))
                    .disabled(useDateRange && NativeDay.string(start) > NativeDay.string(end))
                }.padding(16).background(.bar)
            }
        }
    }
}
