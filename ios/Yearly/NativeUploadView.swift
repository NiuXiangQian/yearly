import SwiftUI
import PhotosUI

struct NativeUploadView: View {
    enum Destination { case timeline, recentUploads, batch([Int]) }
    @ObservedObject var queue: UploadQueue
    @ObservedObject var session: NativeSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var site: SiteOrigin { session.site }
    let profileRevision: Int
    @Binding var requestedDay: Date?
    let onTimeline: (Destination) -> Void
    @State private var account: UploadAccount?
    @State private var profiles: [UploadProfile] = []
    @State private var children: Set<Int> = []
    @State private var batchName = ""
    @State private var useArchiveDate = false
    @State private var archiveDate = Date()
    @State private var showPicker = false
    @State private var addingCount = 0
    @State private var excluded: Set<UUID> = []
    @State private var message = ""
    @State private var showingDuplicate = false
    @State private var loadingAccount = false
    @State private var openingPicker = false
    @State private var loadedProfileRevision: Int?
    @State private var showingBatchSettings = false
    @State private var profileSearch = ""
    @State private var showFinished = false
    @State private var listRevision = 0
    @State private var expandedTaskID: UUID?
    @State private var previewItem: UploadItem?
    @State private var warningConfirmation: Set<UUID>?
    @State private var cancelling: UploadItem?

    private var chosenNames: String {
        let names = profiles.filter { children.contains($0.id) }.map { $0.nickname.isEmpty ? $0.name : $0.nickname }
        return names.isEmpty ? "仅家庭时光" : names.joined(separator: "、")
    }
    private var batchNameError: String? {
        batchName.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count > 255
            ? "批次名称最多 255 个字符，请缩短后上传。" : nil
    }
    private var batchSettingsSummary: String {
        var details = [chosenNames]
        if useArchiveDate {
            details.insert("归档到 \(archiveDate.formatted(.dateTime.year().month().day()))", at: 0)
        }
        let title = batchName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { details.append(title) }
        return details.joined(separator: " · ")
    }
    private var items: [UploadItem] {
        guard let ownerID = session.account?.id else { return [] }
        let siteAddress = site.url.absoluteString
        return queue.items.filter { $0.ownerID == ownerID && $0.site == siteAddress }
    }
    private var ready: [UploadItem] { readyItems.filter { !excluded.contains($0.id) } }
    private var pending: [UploadItem] { items.filter { !$0.isTerminal } }
    private var finished: [UploadItem] { items.filter(\.isTerminal) }
    private var preparing: [UploadItem] { pending.filter { $0.phase == .selected || $0.phase == .preparing } }
    private var readyItems: [UploadItem] { pending.filter { $0.phase == .ready } }
    private var canAdd: Bool { account != nil && !openingPicker && addingCount == 0 }
    private var canUpload: Bool { account != nil && addingCount == 0 && !ready.isEmpty && batchNameError == nil }
    private var preparation: UploadQueue.Preparation? {
        guard let sample = queue.preparation,
              preparing.contains(where: { $0.id == sample.itemID && $0.phase == .preparing }) else { return nil }
        return sample
    }
    private var uploadItems: [UploadItem] {
        items.filter { $0.confirmed && !$0.duplicate && $0.phase != .cancelled &&
            (queue.uploadGroup.isEmpty ? !$0.isTerminal : queue.uploadGroup.contains($0.id)) }
    }
    private var batchResult: (title: String, detail: String, ids: [Int], success: Bool)? {
        let group = items.filter { queue.uploadGroup.contains($0.id) }
        guard !group.isEmpty, group.allSatisfy({ $0.isTerminal || $0.phase == .failed }) else { return nil }
        let ids = group.filter { $0.phase == .complete }.compactMap(\.mediaID)
        let failures = group.filter { $0.phase == .failed }.count
        let skipped = group.filter { $0.phase == .skipped }.count
        let cancelled = group.filter { $0.phase == .cancelled }.count
        let title: String
        if failures > 0 { title = "上传结束，\(failures) 项失败" }
        else if !ids.isEmpty { title = "上传完成" }
        else if skipped > 0 { title = "本批已处理" }
        else { title = "本批已取消" }
        var detail = ["\(ids.count) 项上传成功"]
        if skipped > 0 { detail.append("\(skipped) 项重复已跳过") }
        if cancelled > 0 { detail.append("\(cancelled) 项已取消") }
        return (title, detail.joined(separator: " · "), ids, failures == 0 && cancelled == 0)
    }
    private var uploadSize: Int64 { uploadItems.reduce(0) { $0 + $1.size } }
    private var sentBytes: Int64 { uploadItems.reduce(0) { $0 + bytesSent($1) } }
    private func bytesSent(_ item: UploadItem) -> Int64 {
        let inFlight = item.phase == .uploading && queue.transfer?.itemID == item.id ? queue.transfer?.inFlightBytes ?? 0 : 0
        return min(item.size, item.uploadedBytes + inFlight)
    }

    private func bytesLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func progressLabel(_ progress: ByteProgress) -> String {
        guard let total = progress.total else { return "\(bytesLabel(progress.processed)) · 总大小待确认" }
        return "\(bytesLabel(progress.processed)) / \(bytesLabel(total))"
    }

    private func eta(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "估算中" }
        if seconds < 60 { return "\(max(1, Int(seconds.rounded(.up)))) 秒" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded(.up))) 分钟" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时 \(Int(seconds / 60) % 60) 分钟" }
        return "超过 1 天"
    }

    @ViewBuilder private var preparationSummary: some View {
        let preparingItems = preparing
        if !preparingItems.isEmpty {
            let ready = readyItems
            let readyBytes = ready.reduce(Int64(0)) { $0 + $1.size }
            let knownSizes = preparingItems.compactMap(\.sourceByteCount)
            let total = knownSizes.count == preparingItems.count ? readyBytes + knownSizes.reduce(0, +) : nil
            let progress = ByteProgress(processed: readyBytes + (preparation?.bytesRead ?? 0), total: total)
            VStack(alignment: .leading, spacing: 6) {
                Text("准备原件 · \(ready.count) / \(ready.count + preparingItems.count) 项就绪")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                if let fraction = progress.fraction { ProgressView(value: fraction) }
                else { ProgressView() }
                Group {
                    let read = "已读取 \(progressLabel(progress))"
                    if progress.fraction == 1 { Text("原件已读取，正在校验") }
                    else if progress.total != nil, let sample = preparation {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            if context.date.timeIntervalSince(sample.sampledAt) < 5,
                               let seconds = progress.remainingTime(bytesPerSecond: sample.bytesPerSecond) {
                                Text("\(read) · 预计剩余 \(eta(seconds))")
                            } else { Text(read) }
                        }
                    } else { Text(read) }
                }.font(.caption).foregroundStyle(NativeTheme.secondaryText)
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder private var uploadSummary: some View {
        if uploadSize > 0 && batchResult == nil {
            let active = uploadItems.filter { $0.phase == .queued || $0.phase == .uploading }
            let blocked = uploadItems.contains { [.paused, .failed].contains($0.phase) }
            let progress = ByteProgress(processed: sentBytes, total: uploadSize)
            let fraction = progress.fraction ?? 0
            ProgressView(value: fraction) {
                Text("上传进度 · \(fraction.formatted(.percent.precision(.fractionLength(0...1))))")
                    .font(.subheadline.weight(.semibold))
            } currentValueLabel: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已上传 \(progressLabel(progress))")
                    if active.isEmpty && blocked { Text("上传已中断，继续后显示剩余时间") }
                    else if !active.isEmpty && active.allSatisfy({ bytesSent($0) == $0.size }) {
                        Text(blocked ? "进行中任务已传完，正在校验" : "已传完，正在校验")
                    } else if let rate = queue.uploadRate,
                              let seconds = ByteProgress(processed: active.reduce(0) { $0 + bytesSent($1) },
                                                         total: active.reduce(0) { $0 + $1.size }).remainingTime(bytesPerSecond: rate) {
                        let remaining = blocked ? "进行中任务预计剩余" : "预计剩余"
                        Text("\(bytesLabel(Int64(rate)))/秒 · \(remaining) \(eta(seconds))")
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(NativeTheme.secondaryText)
            }
            .padding(.vertical, 6)
        }
    }
    @ViewBuilder private var completionBanner: some View {
        if let result = batchResult {
            let tint: Color = result.success ? .green : .orange
            VStack(alignment: .leading, spacing: 10) {
                Label(result.title, systemImage: result.success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.title3.bold()).foregroundStyle(tint)
                    .accessibilityAddTraits(.isHeader)
                Text(result.detail).font(.subheadline)
                if !result.ids.isEmpty {
                    Button {
                        onTimeline(result.ids.count <= 5 ? .batch(result.ids) : .recentUploads)
                    } label: {
                        Label(result.ids.count <= 5 ? "查看刚上传的影像" : "按上传时间查看", systemImage: "photo.on.rectangle")
                    }.buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }
    private var addMediaButton: some View {
        Button { Task { await choosePhotos() } } label: {
            Label("添加照片与视频", systemImage: "plus")
        }
        .disabled(!canAdd)
        .accessibilityIdentifier("upload-add-media")
    }

    private var taskFilters: some View {
        HStack(spacing: 4) {
            taskFilter("当前", count: pending.count, finished: false)
            taskFilter("已结束", count: finished.count, finished: true)
        }
        .padding(4)
        .background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func taskFilter(_ title: String, count: Int, finished: Bool) -> some View {
        let selected = showFinished == finished
        return Button {
            if !selected { showTasks(finished: finished) }
        } label: {
            Text("\(title) \(count)")
                .monospacedDigit()
                .foregroundStyle(selected ? NativeTheme.accent : NativeTheme.secondaryText)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(NativeActionStyle(kind: selected ? .secondary : .quiet, compact: true))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(finished ? "upload-finished-tasks" : "upload-current-tasks")
    }

    private var canPause: Bool { pending.contains { $0.phase.canPause } }
    private var interruptedCount: Int { pending.filter { $0.phase == .paused || $0.phase == .failed }.count }
    private var hasLimitedAccess: Bool { PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited }

    private var taskMenu: some View {
        Menu {
            if !showFinished && canPause {
                Button { queue.pauseAll() } label: { Label("全部暂停", systemImage: "pause.circle") }
            }
            if hasLimitedAccess {
                Button { presentLimitedPicker() } label: { Label("管理允许访问的照片", systemImage: "photo.on.rectangle") }
            }
            Button { IOSUploadNotifications.requestPermission(openSettingsOtherwise: true) } label: {
                Label("后台上传提醒", systemImage: "bell")
            }
        } label: {
            Label("任务操作", systemImage: "ellipsis.circle")
        }
        .labelStyle(.iconOnly)
    }

    private var currentStatus: some View {
        Section {
            if addingCount > 0 {
                ProgressView("正在加入 \(addingCount) 项…")
            } else if openingPicker {
                ProgressView("正在打开系统相册…")
            } else if loadingAccount && account == nil {
                ProgressView("正在读取登录状态…")
            }
            if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(NativeTheme.inputError) }
            if !queue.error.isEmpty { Text(queue.error).font(.footnote).foregroundStyle(NativeTheme.inputError) }
            if account == nil && !loadingAccount {
                Button("刷新登录状态") { Task { await loadAccount() } }
            }
            if interruptedCount > 0 {
                Button {
                    IOSUploadNotifications.requestPermission()
                    queue.retryInterrupted()
                } label: {
                    Label("全部重试（\(interruptedCount) 项）", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(NativeActionStyle(compact: true))
                .disabled(!session.canEdit)
                .accessibilityIdentifier("upload-retry-all")
            }
            if let showProgress = queue.requestContinuedExecution,
               !queue.hasContinuedExecution, !queue.activeConfirmedUploadIDs.isEmpty {
                Button(action: showProgress) {
                    Label("显示后台进度", systemImage: "chart.bar.xaxis").frame(maxWidth: .infinity)
                }
                .buttonStyle(NativeActionStyle(kind: .quiet, compact: true))
                if let notice = queue.continuedExecutionNotice {
                    Text(notice).font(.footnote).foregroundStyle(NativeTheme.secondaryText)
                }
            }
            if !queue.duplicateNotice.isEmpty {
                Button { showingDuplicate = true } label: {
                    HStack(spacing: 8) {
                        Label("发现重复文件", systemImage: "exclamationmark.triangle")
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).accessibilityHidden(true)
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NativeTheme.accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("查看已跳过的文件")
            }
            preparationSummary
            uploadSummary
        }
        .listRowBackground(NativeTheme.background)
    }

    private var emptyQueue: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title2)
                .foregroundStyle(NativeTheme.accent)
                .accessibilityHidden(true)
            Text("当前没有任务").font(.title3.weight(.semibold))
            addMediaButton.buttonStyle(NativeActionStyle(kind: .primary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(NativeTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .padding(.vertical, 8)
        .listRowBackground(NativeTheme.background)
        .listRowSeparator(.hidden)
    }

    private var batchActions: some View {
        let compact = verticalSizeClass == .compact && dynamicTypeSize.isAccessibilitySize
        let layout = compact ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 6))
        return VStack(spacing: 0) {
            Divider()
            layout {
                Button {
                    profileSearch = ""
                    showingBatchSettings = true
                } label: {
                    if compact {
                        Image(systemName: batchNameError == nil ? "slider.horizontal.3" : "exclamationmark.circle")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(batchNameError == nil ? NativeTheme.accent : NativeTheme.inputError)
                            .frame(width: 48, height: 48)
                            .background(NativeTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                            .contentShape(Rectangle())
                    } else {
                        HStack(spacing: 10) {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundStyle(NativeTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("批次设置").font(.subheadline.weight(.semibold))
                                Text(batchNameError ?? batchSettingsSummary)
                                    .font(.caption)
                                    .foregroundStyle(batchNameError == nil ? NativeTheme.secondaryText : NativeTheme.inputError)
                                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(NativeTheme.secondaryText)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("批次设置")
                .accessibilityValue(batchNameError ?? batchSettingsSummary)
                .accessibilityIdentifier("upload-batch-settings")
                if !readyItems.isEmpty {
                    let count = ready.count
                    Button { requestUpload() } label: {
                        Text(count == 0 ? "选择要上传的文件" : "上传\(preparing.isEmpty ? "所选" : "已就绪的") \(count) 项")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NativeActionStyle(kind: .primary))
                    .disabled(!canUpload)
                    .accessibilityIdentifier("upload-start")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(NativeTheme.surface)
    }

    private var batchSettings: some View {
        NavigationStack {
            Form {
                if profileSearch.isEmpty {
                    Section {
                        NativeFormField(title: "批次名称", error: batchNameError) {
                            TextField("", text: $batchName, prompt: NativeTheme.inputPrompt("可留空"))
                        }
                        Toggle("设置本批归档日期", isOn: $useArchiveDate)
                        if useArchiveDate {
                            DatePicker("归档日期", selection: $archiveDate, displayedComponents: .date)
                                .accessibilityIdentifier("upload-archive-date")
                        }
                    }
                    .listRowBackground(NativeTheme.surface)
                }
                Section("关联人物与宠物") {
                    if profileSearch.isEmpty {
                        profileOption("仅家庭时光", symbol: "house", selected: children.isEmpty) { selectPeople([]) }
                    }
                    let matches = profiles.filter { profileSearch.isEmpty || $0.label.localizedCaseInsensitiveContains(profileSearch) }
                    ForEach(matches) { profile in
                        profileOption(profile.label, symbol: profile.profile_type == "pet" ? "pawprint" : "person.crop.circle",
                                      selected: children.contains(profile.id)) {
                            var updated = children
                            if !updated.insert(profile.id).inserted { updated.remove(profile.id) }
                            selectPeople(updated)
                        }
                    }
                    if !profileSearch.isEmpty && matches.isEmpty {
                        Text("没有匹配的人物或宠物").foregroundStyle(NativeTheme.secondaryText)
                    }
                }
                .listRowBackground(NativeTheme.surface)
            }
            .navigationTitle("批次设置")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(NativeTheme.background)
            .searchable(text: $profileSearch, prompt: "搜索人物或宠物")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showingBatchSettings = false }
                }
            }
        }
    }

    private func profileOption(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: 8) {
                Label(title, systemImage: symbol)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(NativeTheme.accent)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func taskProgress(_ item: UploadItem) -> ByteProgress? {
        if item.phase == .preparing {
            let sample = queue.preparation
            let bytesRead = sample?.itemID == item.id ? sample?.bytesRead ?? 0 : 0
            return ByteProgress(processed: bytesRead, total: item.sourceByteCount)
        }
        guard item.confirmed, !item.duplicate, item.phase != .cancelled, item.size > 0 else { return nil }
        return ByteProgress(processed: bytesSent(item), total: item.size)
    }

    private func taskRow(_ item: UploadItem) -> some View {
        let size = item.resources.isEmpty ? item.sourceByteCount : item.size
        let progress = taskProgress(item)
        let isActive = item.phase == .preparing || item.phase == .uploading
        let isExcluded = item.phase == .ready && excluded.contains(item.id)
        let status: String
        switch item.phase {
        case .selected: status = "等待准备"
        case .preparing: status = "准备中"
        case .ready: status = isExcluded ? "未选入本批" : "待上传"
        case .queued: status = "排队上传"
        case .complete: status = "已上传"
        default: status = item.phase.label
        }
        let statusColor = item.phase == .failed ? NativeTheme.inputError : isActive ? NativeTheme.accent : NativeTheme.secondaryText
        let detail = isActive
            ? progress?.fraction?.formatted(.percent.precision(.fractionLength(0)))
            : size.map(bytesLabel)
        let expanded = expandedTaskID == item.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { previewItem = item } label: {
                    UploadTaskThumbnail(item: item, queue: queue, session: session)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("预览 \(item.name)")
                Button {
                    withAnimation(reduceMotion ? nil : NativeMotion.spring) {
                        expandedTaskID = expanded ? nil : item.id
                    }
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                            Text(detail.map { "\(status) · \($0)" } ?? status)
                                .font(.caption)
                                .foregroundStyle(statusColor)
                        }
                        if !item.warning.isEmpty {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 14))
                                .foregroundStyle(NativeTheme.secondaryText)
                                .accessibilityLabel("有原件说明")
                        }
                        Spacer(minLength: 0)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(NativeTheme.secondaryText)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "已展开" : "已收起")
                .accessibilityHint(expanded ? "收起任务详情" : "展开任务详情")
                if item.phase == .ready {
                    Button {
                        if isExcluded { excluded.remove(item.id) } else { excluded.insert(item.id) }
                    } label: {
                        Image(systemName: isExcluded ? "circle" : "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(isExcluded ? NativeTheme.secondaryText : NativeTheme.accent)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExcluded ? "选择 \(item.name) 上传" : "取消选择 \(item.name)")
                    .accessibilityAddTraits(isExcluded ? [] : .isSelected)
                }
            }
            if expanded {
                Divider()
                taskDetails(item, progress: progress)
                    .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 0 : 52)
            }
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowBackground(NativeTheme.background)
        .listRowSeparatorTint(NativeTheme.line)
    }

    @ViewBuilder private func taskDetails(_ item: UploadItem, progress: ByteProgress?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.name).font(.subheadline.weight(.semibold))
            if item.mediaType == "live_photo" {
                Label("实况照片", systemImage: "livephoto").font(.caption)
            } else if item.mediaType == "video" {
                Label("视频", systemImage: "video").font(.caption)
            }
            let size = item.resources.isEmpty ? item.sourceByteCount : item.size
            Text(size.map(bytesLabel) ?? "大小：待读取").font(.caption)
            Text("拍摄：\(item.captureDate ?? "未知")").font(.caption)
            if let day = item.albumArchiveDay() {
                Text("相册日期：\(day)").font(.caption).foregroundStyle(.secondary)
            }
            if !item.warning.isEmpty { Text(item.warning).font(.caption).foregroundStyle(.orange) }
            if let progress {
                if let fraction = progress.fraction { ProgressView(value: fraction) }
                else { ProgressView() }
                Text(item.phase == .preparing ? "已读取 \(progressLabel(progress))" : "已上传 \(progressLabel(progress))")
                    .font(.caption)
            }
            if !item.message.isEmpty {
                Text(item.message).font(.caption).foregroundStyle(item.phase == .failed ? NativeTheme.inputError : NativeTheme.secondaryText)
            }
            if !item.isTerminal {
                HStack {
                    if [.paused, .failed].contains(item.phase) {
                        Button(item.phase == .failed ? "重试" : "继续") {
                            IOSUploadNotifications.requestPermission()
                            queue.resume(item.id)
                        }.disabled(!session.canEdit)
                    } else if item.phase != .ready {
                        Button("暂停") { queue.pause(item.id) }
                    }
                    Spacer(minLength: 8)
                    Button("取消", role: .destructive) { cancelling = item }
                }
                .buttonStyle(NativeActionStyle(compact: true))
            }
        }
        .padding(.vertical, 8)
    }

    private var taskList: some View {
        let current = pending
        let visibleItems = showFinished ? finished : current
        return List {
            if showFinished || (current.isEmpty && addingCount == 0) {
                completionBanner
                    .listRowBackground(NativeTheme.background)
                    .listRowSeparator(.hidden)
            }
            if !showFinished { currentStatus }
            if visibleItems.isEmpty {
                if showFinished {
                    Text("暂无已结束的任务")
                        .foregroundStyle(NativeTheme.secondaryText)
                        .listRowBackground(NativeTheme.background)
                } else if addingCount == 0 && !openingPicker && batchResult == nil {
                    emptyQueue
                }
            }
            ForEach(visibleItems.reversed()) { item in
                taskRow(item)
            }
            if showFinished {
                Button("查看家庭时间线") { onTimeline(.timeline) }
                    .listRowBackground(NativeTheme.background)
                    .listRowSeparator(.hidden)
            }
        }
        .id(listRevision)
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await loadAccount() }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                taskFilters
                taskList
            }
            .navigationTitle("上传任务")
            .navigationBarTitleDisplayMode(.inline)
            .background(NativeTheme.background)
            .tint(NativeTheme.accent)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    taskMenu
                    if showFinished || !pending.isEmpty || batchResult != nil || addingCount > 0 {
                        addMediaButton.labelStyle(.iconOnly)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !showFinished && account != nil && (useArchiveDate || pending.isEmpty || pending.contains(where: { !$0.confirmed })) {
                    batchActions
                }
            }
            .nativeSheet(item: $previewItem) { item in
                UploadTaskPreview(item: items.first { $0.id == item.id } ?? item, queue: queue, session: session)
            }
            .nativeSheet(isPresented: $showingBatchSettings) {
                batchSettings
            }
            .confirmationDialog("取消后会删除本机缓存，继续上传需要重新选择原件", isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }), titleVisibility: .visible) {
                if let item = cancelling { Button("取消此任务", role: .destructive) { queue.cancel(item.id); cancelling = nil } }
            }
            .alert("发现重复文件", isPresented: $showingDuplicate) {
                Button("知道了", role: .cancel) { }
            } message: {
                Text(queue.duplicateNotice)
            }
            .onChange(of: batchResult?.title) { title in
                if let title { UIAccessibility.post(notification: .announcement, argument: title) }
            }
            .task(id: requestedDay) {
                if let day = requestedDay {
                    archiveDate = day
                    useArchiveDate = true
                    showTasks(finished: false)
                    requestedDay = nil
                }
            }
            .task(id: profileRevision) {
                queue.configure(session: session)
                if loadedProfileRevision != profileRevision { await loadAccount() }
            }
            .sheet(isPresented: $showPicker) {
                NativePhotoPicker(onFinish: addSelectedMedia)
            }
            .alert("部分原件有说明", isPresented: Binding(
                get: { warningConfirmation != nil },
                set: { if !$0 { warningConfirmation = nil } }
            ), presenting: warningConfirmation) { ids in
                Button("继续上传") { startUpload(ids) }
                Button("返回检查", role: .cancel) { }
            } message: { _ in
                Text("部分文件包含编辑版本或元数据提示。可返回任务列表，展开对应文件查看。")
            }
        }
    }

    private func showTasks(finished: Bool) {
        showFinished = finished
        expandedTaskID = nil
        listRevision += 1
    }

    private func addSelectedMedia(_ identifiers: [String], unavailable: Int) {
        showPicker = false
        guard !identifiers.isEmpty || unavailable > 0 else { return }
        message = unavailable > 0 ? "有 \(unavailable) 项无法读取，请调整照片权限后重新选择。" : ""
        showTasks(finished: false)
        guard let account, !identifiers.isEmpty else { return }
        addingCount = identifiers.count
        Task {
            await queue.add(identifiers: identifiers, account: account)
            addingCount = 0
            if !showFinished { listRevision += 1 }
        }
    }

    private func requestUpload() {
        guard canUpload else { return }
        let selected = ready
        let ids = Set(selected.map(\.id))
        if selected.contains(where: { !$0.warning.isEmpty }) { warningConfirmation = ids }
        else { startUpload(ids) }
    }

    private func startUpload(_ ids: Set<UUID>) {
        guard account != nil, batchNameError == nil else { return }
        IOSUploadNotifications.requestPermission()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        queue.confirm(ids: ids, childIDs: Array(children), batchName: batchName,
                      archiveDate: useArchiveDate ? formatter.string(from: archiveDate) : nil)
    }

    private func selectPeople(_ ids: Set<Int>) {
        guard let account, account.id == session.account?.id else { return }
        children = ids.intersection(Set(profiles.map(\.id)))
        UploadProfilePreferences(site: site, ownerID: account.id).save(children)
    }
    private func loadAccount() async {
        guard !loadingAccount, let expectedOwner = session.account?.id else { return }
        loadingAccount = true
        defer { loadingAccount = false }
        do {
            async let currentRequest: UploadAccount = session.get("/auth/me")
            async let profilesRequest: [UploadProfile] = session.get("/children", refresh: true)
            let (current, loaded) = try await (currentRequest, profilesRequest)
            try Task.checkCancellation()
            guard current.id == expectedOwner, session.account?.id == expectedOwner,
                  ["admin", "member"].contains(current.role) else {
                account = nil
                throw UploadFailure(message: "当前账号没有上传权限，请重新登录。")
            }
            let remembered = UploadProfilePreferences(site: site, ownerID: current.id)
                .restore(validIDs: Set(loaded.map(\.id)))
            account = current; profiles = loaded; children = remembered
            loadedProfileRevision = profileRevision; message = ""
        } catch {
            if Task.isCancelled { return }
            message = error is URLError ? "无法连接家庭站点，请检查网络。已保存的人物选择不会丢失。" : error.localizedDescription
        }
    }
    private func choosePhotos() async {
        guard canAdd, !showPicker else { return }
        openingPicker = true
        defer { openingPicker = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            message = "读取未修改原件需要照片访问权限。请在设置 → Yearly → 照片中允许访问所选照片。"
            return
        }
        showPicker = true
    }
    private func presentLimitedPicker() {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let presented = controller.presentedViewController { controller = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }
}

private struct NativePhotoPicker: UIViewControllerRepresentable {
    let onFinish: ([String], Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 0
        // Ordered selection disables the system swipe-to-select gesture.
        configuration.selection = .default
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) { }
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onFinish: ([String], Int) -> Void
        init(onFinish: @escaping ([String], Int) -> Void) { self.onFinish = onFinish }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let identifiers = results.compactMap(\.assetIdentifier)
            onFinish(identifiers, results.count - identifiers.count)
        }
    }
}
