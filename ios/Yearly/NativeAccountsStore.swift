import Foundation
import Combine

enum NativeAccountValidation {
    static func username(_ value: String) -> String? {
        guard (2...80).contains(value.unicodeScalars.count) else { return "用户名须为 2 至 80 个字符。" }
        guard value.range(of: #"\A[\p{L}\p{N}_.@-]+\z"#, options: .regularExpression) != nil else {
            return "用户名只能包含文字、数字、下划线、点、@ 和短横线，不能包含空格。"
        }
        return nil
    }

    static func password(_ value: String, optional: Bool = false) -> String? {
        if optional && value.isEmpty { return nil }
        return (12...256).contains(value.unicodeScalars.count) ? nil : "密码须为 12 至 256 个字符。"
    }
}

struct NativeManagedUser: Decodable, Identifiable {
    let id: Int
    let username: String
    let role: String
    let active: Bool
    let updated_at: String?
    var nickname: String? = nil
    var displayName: String { if let nickname, !nickname.isEmpty { return nickname }; return username }
    var roleLabel: String { role == "admin" ? "管理员" : role == "member" ? "普通账户" : "只读访客" }
}

struct NativeCreatedUser: Decodable { let id: Int }

@MainActor final class NativeAccountsStore: ObservableObject {
    @Published private(set) var users: [NativeManagedUser] = []
    @Published private(set) var loading = false
    @Published private(set) var error = ""
    let session: NativeSession
    init(session: NativeSession) { self.session = session }

    func load() async {
        guard session.isAdmin, let actor = session.account?.id, !loading else { return }
        loading = true; error = ""
        defer { loading = false }
        do {
            let current: [NativeManagedUser] = try await session.get("/users", refresh: true)
            guard !Task.isCancelled, session.account?.id == actor else { return }
            users = current
        } catch { if !Task.isCancelled { self.error = friendly(error) } }
    }

    func save(existing: NativeManagedUser?, username: String, nickname: String = "", password: String, role: String, active: Bool) async throws {
        guard session.isAdmin else { throw NativeAPIError(status: 403, message: "需要管理员权限。") }
        let nickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing {
            try await session.write("/users/\(existing.id)", json: [
                "username": username, "password": password.isEmpty ? NSNull() as Any : password,
                "nickname": nickname, "role": role, "active": active,
            ])
            if existing.id == session.account?.id && (existing.username != username || !password.isEmpty) {
                session.requireLogin(message: "账户已更新，请重新登录。")
                return
            }
            if existing.id == session.account?.id { session.updateNickname(nickname) }
        } else {
            let _: NativeCreatedUser = try await session.post("/users", json: ["username": username, "nickname": nickname, "password": password, "role": role])
        }
        await load()
    }
}

indirect enum NativeAuditValue: Decodable {
    case text(String), number(Decimal), boolean(Bool), array([NativeAuditValue]), object([String: NativeAuditValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(String.self) { self = .text(value) }
        else if let value = try? container.decode(Decimal.self) { self = .number(value) }
        else if let value = try? container.decode([NativeAuditValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: NativeAuditValue].self)) }
    }
    var display: String {
        switch self {
        case .text(let value): return value.isEmpty ? "空" : value
        case .number(let value): return NSDecimalNumber(decimal: value).stringValue
        case .boolean(let value): return value ? "是" : "否"
        case .array(let values): return "[" + values.map(\.display).joined(separator: "、") + "]"
        case .object(let values): return values.keys.sorted().map { "\($0) = \(values[$0]!.display)" }.joined(separator: "\n")
        case .null: return "空"
        }
    }
}
struct NativeAuditChange: Decodable {
    let before: NativeAuditValue?
    let after: NativeAuditValue?
    let changed: Bool?
}
struct NativeAuditLog: Decodable, Identifiable {
    let id: Int
    let actor_name: String
    let resource_type: String
    let resource_id: String
    let action: String
    let changes: [String: NativeAuditChange]
    let created_at: String
    var label: String { (action == "create" ? "创建" : action == "delete" ? "删除" : "修改") + " " + NativeAuditLabels.resources[resource_type, default: resource_type] + " #" + resource_id }
}
struct NativeAuditPage: Decodable { let items: [NativeAuditLog]; let total: Int }
enum NativeAuditLabels {
    static let resources = ["media": "文件", "timeline_folder": "文件夹", "child": "档案", "timeline_event": "日记", "timeline_day": "日期设置", "timeline_share": "分享", "sys_user": "账户"]
    static let fields = ["title": "标题", "name": "名称", "username": "用户名", "nickname": "昵称", "role": "账户角色", "active": "启用账户", "password": "密码", "status": "状态", "share_allowed": "允许分享", "child_ids": "人物与宠物", "media_ids": "关联影像", "folder_id": "文件夹", "timeline_date": "归档日期", "batch_name": "批次名称", "remark": "备注", "content": "日记内容", "sort_order": "顺序", "owner_id": "创建人", "created_by": "创建人", "location_name": "地点", "revoked": "撤销分享", "expires_at": "有效期"]
    static func time(_ value: String) -> String {
        let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value + "Z"))
            ?? (try? Date.ISO8601FormatStyle().parse(value + "Z"))
        return date?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
}
