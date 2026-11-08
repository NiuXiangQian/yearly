# Yearly iOS 原生上传助手：开发与使用

基于已有 `codex/ios-app-install` 分支增量实现，最低 iOS 16。保留 SwiftUI 外壳、WKWebView 家庭站点、登录、下载分享和现有 Vue 时间线；新增原生批量原件上传入口。Bundle Identifier 仍为 `family.yearly.app`，无需付费 Apple Developer Program、TestFlight、App Store Connect 或新 Capability。

**当前状态：代码、Mac Swift 核心测试和前后端测试已完成；开发机只有 Command Line Tools，尚未完成 iOS SDK 编译、签名安装及真机相册/iCloud 验收。不要把本说明视为已完成真机验收。**

## 免费 Apple 账号安装与续签

1. 在 Mac 安装完整 Xcode 和 iOS 平台组件，首次打开完成组件安装及许可确认。仅 Command Line Tools 不含 UIKit/iOS SDK。
2. Xcode → Settings → Accounts，添加自己的免费 Apple Account。
3. 打开 `ios/Yearly.xcodeproj`，选择 **Yearly** scheme 和 target；在 **Signing & Capabilities** 勾选 **Automatically manage signing**，Team 选择自己的 **Personal Team**。
4. 先保留 `family.yearly.app`。如果该标识不能由你的 Team 注册，将 target 的 Debug/Release Bundle Identifier 改为自己的唯一反向域名，例如 `me.yourname.yearly`。之后保持 Team 和 Bundle Identifier 稳定，以便覆盖安装、保留缓存。不要提交个人签名文件。更换 Bundle Identifier 会成为另一个 App，旧任务不会自动迁移。
5. 用数据线连接 iPhone，在设备上选择“信任此电脑”。按系统提示启用“设置 → 隐私与安全性 → 开发者模式”，必要时重启。在 Xcode 选择这台 iPhone，点击 **Run（⌘R）**。
6. 如系统要求信任开发者，在“设置 → 通用 → VPN 与设备管理”中信任相应 Apple 账号。首次运行输入可访问且证书有效的家庭站点 **HTTPS 根地址**，在原网页登录。
7. 免费 Personal Team 的 provisioning profile **从签发起 7 天有效**。临近到期或 App 无法打开时，再连接 iPhone，用同一 Team、同一 Bundle Identifier 在 Xcode **Run**，重新签名并覆盖安装。不要先删除 App，否则本机未完成上传缓存会丢失。不存在永久免续签保证。

Apple 官方依据：[Personal Team 与 7 天有效期](https://developer.apple.com/help/account/basics/about-your-developer-account)、[连接设备并运行](https://help.apple.com/xcode/mac/current/en.lproj/dev5a825a1ca.html)。免费账号还受 Apple 当时的 App/设备额度限制，Xcode 会显示具体错误。

不启用 Push Notifications、App Groups、iCloud Container、Background Processing 等能力。访问用户 iCloud 照片由 Photos 框架与系统照片账户完成，不需要 App 的 iCloud entitlement。没有 AltStore 前置条件。

```bash
# 项目根目录：CLI 可执行检查，完全不访问 OSS
./scripts/ios.sh verify
./scripts/ios.sh test-large

# 完整 Xcode：Debug / Release 模拟器编译，不签名
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/ios.sh build

# 可选：命令行自动开发签名构建（Xcode 已登录免费账号并连接设备）
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export YEARLY_TEAM_ID='Xcode显示的PersonalTeamID'
export YEARLY_DEVICE_ID='Xcode设备窗口显示的设备标识'
./scripts/ios.sh device

# Xcode 15+ 可用 devicectl 安装上一步构建产物，或直接在 Xcode 点击 Run
xcrun devicectl device install app --device "$YEARLY_DEVICE_ID" \
  .local/ios/Device/Build/Products/Debug-iphoneos/Yearly.app
```

`YEARLY_BUNDLE_ID` 可选，默认为 `family.yearly.app`。站点可在 App 内配置，个人安装无需填写发行隐私/支持 URL。原有 `archive` / `export` 是可选的付费商店发行工具，保留供历史流程使用；它们不是编译、安装、运行、续签的前提，也不代表应用已具备上架条件。

## 手机上如何使用

1. 在现有网页登录家庭编辑账号。只读账户、未登录或过期会话不能上传。
2. 点击 App 顶部 **上传图标**，或菜单 **原生相册上传与任务**，进入“珍藏原片”。网页旧的单张 Live Photo 桥接仍兼容保留；批量上传使用这个原生入口。
3. 点击“从系统相册选择照片与视频”。首次说明照片权限；可选有限访问。系统选择器支持多选、取消选择，按点选顺序回传。有限访问中不在授权范围内的资源会提示失败，可点“管理允许访问的照片”加入后重试；不会改成有损副本来绕过权限。
4. 逐项提取原始资源到应用私有目录。iCloud 资源允许联网下载，显示 Photos 提供的下载进度；尚未有进度时显示准备状态，不虚构百分比。可取消或暂停。缩略图只是预览，不作为上传源。
5. 资源提取后显示原始文件名、准确大小、可解析的拍摄时间、Live Photo 图片/MOV 两份状态。拍摄时间未知时，PhotoKit 日期仅标为参考。只有编辑后版本可用时，明确标记“不是相机未修改原片”，确认后才上传。
6. 可多选已有孩子、人物、宠物；不选保持“家庭时光”。设置批次名称及可选归档日期。归档日期仅影响时间线位置，不改原件、原始拍摄时间或已有重复媒体的信息。确认对话框再次说明跨日期归档行为。
7. 点击“确认上传所选 N 项”。每项独立上传、重试、暂停、继续、取消。Live Photo 两份资源全部通过服务端校验才完成；MOV 失败时不会宣告整个 Live Photo 成功。
8. 完成后点“返回网页时间线”。播放仍使用原有网页 Live Photo 预览机制；动态预览可能需要等待现有后端预览工作进程生成。

资源缓存最多 8 GiB，至少预留 512 MiB；临近上限先上传已准备的项目，再重试剩余项目。单份原件也必须装得下剩余预算。不会同时把几百张原件载入内存。所有未完成状态和已确认参数保存在 `Application Support/NativeUploads/queue.json`；文件位于每个 UUID 子目录，排除 iCloud 备份并设置 iOS Data Protection。

进入后台立即取消当前可取消操作并保存暂停状态，回到前台恢复原先运行的项目。系统强制结束后不承诺继续上传；下次打开显示已恢复任务，点“继续暂停任务”。原生队列独立于网页，网页重载不会丢失它。断网时保留原件和服务端分片，失败项目可单独重试。更换站点先暂停旧任务；每个任务绑定原站点和原账号，不能拿另一账号继续上传。

取消仅停止本机任务、删除本机缓存；现有 API 没有取消服务端任务接口，因此未完成分片按服务端原有 7 天清理策略处理，不额外增加删除权限。若最后一次完成请求已到服务端，取消不能撤回已经发布的媒体，可去网页检查。完整性冲突（409）保留证据、不自动重建；超过任务有效期（410）需取消后重新选择。

## 架构与真实 API 数据流

| 环节 | 实现与复用 |
|---|---|
| 外壳 | 复用 `YearlyApp`、`SiteView`、`BrowserState`、`SiteOrigin`、`DownloadManager`，增加原生上传 sheet |
| 选择 | `PHPickerConfiguration(photoLibrary: .shared())`，`selectionLimit=0`、`selection=.ordered`；按返回 identifier 顺序取 `PHAsset` |
| 原件 | `PHAssetResource.assetResources(for:)`；普通图片 `.photo`、视频 `.video`；Live Photo 通过 `.photoLive` 识别，优先 `.photo + .pairedVideo` |
| 编辑版本 | 仅在整组原始资源不存在时使用 `.fullSizePhoto + .fullSizePairedVideo`，或普通完整尺寸资源；不混用原始静态图与编辑后 MOV，并显式提示 |
| 提取 | `PHAssetResourceManager.requestData` 原始字节直接写文件，支持 iCloud、取消和写盘预算；无 `UIImage.jpegData`、截图、缩放或转码 |
| 指纹 | CryptoKit SHA-256 + CRC64/XZ（反射 ECMA 多项式，初始/最终异或全 1），每次读取 4 MiB，逐块 autoreleasepool；恢复前重算本机指纹 |
| 创建 | `POST /api/uploads` 一次提交一个逻辑媒体，携带所有 `files`、`child_ids`、批次、归档及原始元数据；每个队列 UUID 作为 `Idempotency-Key` |
| 续传 | `GET /api/uploads/{id}` 取 OSS 权威分片清单，验证序号与大小后跳过已完成分片 |
| 直传 | `POST /api/uploads/{id}/sign?number=N` → HTTPS 临时 URL → 独立无 Cookie 的 URLSession PUT |
| 校验 | `POST /api/uploads/{id}/complete`，原服务合并、HEAD 比较大小/CRC64；每份资源成功后持久化，再完成整个逻辑媒体 |
| 去重与关联 | 沿用服务端原件角色、SHA-256、大小和媒体类型匹配；重复返回空任务，不传 OSS，合并人物关联，保留旧日期和位置 |
| 清理 | 成功状态先原子写盘，再删除缓存；任一资源失败保留已完成状态，重试跳过成功资源 |

**分片配置以真实响应为准：**旧文档写 4 MiB，但当前 `backend/app/config.py` 和 `.env.*.example` 默认 `UPLOAD_PART_SIZE=16777216`（16 MiB）。客户端按任务返回的 `part_size` 处理，支持 4 MiB 等配置，不改变现有服务端设置。哈希读取固定 4 MiB；测试同时验证 4 MiB 和 16 MiB 上传。顺序资源提取、顺序逻辑媒体上传、每次一个分片，最大原件缓冲由分片大小约束。

PhotoKit 的 `writeData` 能直接导出文件，但不返回可取消的 request ID；为满足中途取消和低磁盘空间硬限，本队列使用同一资源管理器的可取消 `requestData` 字节流，保持同一资源原始字节。已有旧单张桥接 `LivePhotoTransfer` 仍使用 `writeData`，没有重写为转码输出。[Apple 原始/完整尺寸资源类型说明](https://developer.apple.com/documentation/photos/phassetresourcetype)、[编辑后 paired video](https://developer.apple.com/documentation/photos/phassetresourcetype/fullsizepairedvideo)。

## 后端最小补充与兼容

仅修改 `backend/app/uploads.py`，无表结构、OSS 对象命名、权限或 Vue API 行为变化：

- 可选 `Idempotency-Key: UUID`。没有该头的原网页流程不变。
- 带头请求先锁定当前用户行，查询现有媒体元数据中的内部 `_upload_receipt`。同一用户、同一 UUID 和同一规范化请求内容，返回原媒体和两份原任务；参数不同返回 409，过期未完成任务返回 410。记录与媒体在同一事务提交，防止创建响应丢失或手机重启后重复创建。
- 回执占用现有 JSON 元数据，不依赖 MySQL 8 新特性，不新增公共幂等框架。原始元数据来源可标记为 `ImageIO + AVFoundation`。客户端伪造内部回执字段会被清除。
- 已完成原件继续走既有内容去重与关联合并语义。不会把 Live Photo 分裂成两个媒体。

**使用新原生队列前，家庭服务需要包含本分支这处后端更新。**客户端创建前检查 `GET /api/uploads` 的 `X-Yearly-Upload-Protocol: idempotent-v1` 响应头；旧服务器缺少此能力时直接提示更新，不创建任务，避免忽略未知请求头导致重复创建。本次没有部署生产服务、修改生产配置或数据库。

认证复用 WebKit 管理的 HTTPS Secure/HttpOnly 会话 Cookie。原生端从所配置站点的 `WKHTTPCookieStore` 取当前 Cookie，仅在内存中传到同源 API；每次校验 `/api/auth/me` 的账号/角色并取得 CSRF，写请求继续携带正确 Origin 和 `X-CSRF-Token`。不另存密码、Cookie 或 CSRF 到 UserDefaults/JSON，不维护第二套登录凭据，也不复制会话到普通磁盘文件。持久登录仍由系统 WebKit 私有存储管理。原生网络用 ephemeral URLSession、禁用共享 Cookie/凭据缓存、拒绝重定向；OSS 请求不携带 API Cookie、CSRF 或 Authorization。日志和队列不存带签名 URL，更不含 OSS AccessKey。

## 元数据和时间

ImageIO 只读属性/标签，保存可解析 EXIF、XMP、IPTC、Apple MakerNote、GPS、镜头、曝光、ISO、方向等；AVFoundation 只读 QuickTime metadata/视频尺寸与时长。所有嵌入字段无论是否能解析，始终保留在未修改的原始字节中。数据库 JSON 有大小预算，超预算时明确标为 partial，完整字段仍在原件。

可靠当地时间沿用项目顺序：EXIF DateTimeOriginal → EXIF DateTimeDigitized/CreateDate → 可解释的 QuickTime CreationDate → 未知。只有明确的匹配偏移进入 `original_offset_minutes`。不根据导入时间、临时文件 mtime、无明确时区的 numeric QuickTime 秒数制造拍摄时间。PhotoKit 的 UTC creationDate、位置与尺寸放在 `photokit_auxiliary`，与原始嵌入数据、归档日期分开。

Live Photo 读取图片 Apple MakerNote / XMP ContentIdentifier 与 MOV `com.apple.quicktime.content.identifier`。两者都存在时必须一致；系统没有解析出双方标识时，保留 PhotoKit 同一 PHAsset 的同版本配对依据并显示说明，不按文件名推测配对。未解析出的私有元数据仍随原件保存。

## 本次实际执行的验证

开发环境：macOS，Swift 6.2.1 / macOS SDK，Python 3.12.11，Node 22，隔离本地 MySQL 8.4.13（仅 UNIX socket），FakeStorage。未访问生产 OSS。

- `./scripts/ios.sh verify`：plist、Xcode 源文件/资源清单、Swift 语法、38 项 origin 配置检查、6 项发行工具测试；原生核心/网络/Photos/队列在 macOS SDK 下类型检查；139 项合成 HEIC 与 Mock 上传断言，以及独立 URLProtocol HTTP 模拟测试。
- `./scripts/ios.sh test-large`：真实生成的合成 HEIC 验证 EXIF/GPS 读取不改字节、同版本 Live Photo 资源选择、100 项普通/Live 混合模拟队列、1 GiB 合成零字节文件的流式 SHA/CRC 和 256 个 4 MiB 分片，共 143 项断言。它不是可播放的 1 GiB 相机视频。
- 模拟服务验证分片跳过、签名 403/OSS 409 重签、服务端完整性 409 不成功、断网 3 次有限退避、认证错误不重试、取消、重启后部分 Live Photo 完成状态和顺序、路径越界拒绝。
- 前端：17 个测试文件、78 项测试通过；`vue-tsc` + Vite 构建通过，既有大 chunk 提示仍存在。首次 Node 18 检查不兼容，换用 Node 22 后通过；未修改 Vue 业务代码。
- 后端：全套测试使用隔离 `_test` 数据库和 FakeStorage，覆盖原件字节、双资源未齐不发布、去重、多人物宠物、CSRF/权限、幂等重试与过期会话。全套 127 项测试、27 个子测试通过。
- 1 GiB 核心测试经逐块自动释放修复后，测试进程最大 RSS 约 54 MiB；这是本机 Mock 核心进程实测，**不是 iPhone App 内存保证**。

### 尚需真机/部署验收

- 当前机器没有完整 Xcode/iOS SDK；`./scripts/ios.sh build` 会明确失败。未声称 UIKit/PhotosUI SwiftUI 界面已通过 iOS SDK 类型检查、模拟器编译、签名或安装。
- 需在 iPhone 验证 Personal Team 安装/7 天续签、真实系统选择器顺序和取消、有限图库授权更新、iCloud 下载进度及失败、编辑过的 Live Photo 原件选择和 ContentIdentifier。
- 使用专用测试家庭服务和合成媒体，验证真实 HTTPS Cookie/CSRF、OSS 临时签名、合并/HEAD、后台/锁屏/强杀、网络切换、低空间、中途重新登录和实际 100 张/1GB 视频内存。自动测试不向真实生产 OSS 上传。
- MySQL 测试实例是本地已有二进制 8.4.13，新建隔离库；本机没有 MySQL 5.7 实例。JSON 回执查询使用 5.7 已有操作，但尚需在 5.7 测试环境复验锁竞争和查询行为。
- 不保证系统不可解析格式能提取所有元数据，不保证后台无限上传，不保证已在服务端完成的请求可被本机取消。网页 Live Photo 播放取决于既有预览进程，未改变它。

## 文件职责

- `Yearly/NativeUploadView.swift`：原生选择器、确认页、缩略图、人物/宠物和任务操作。
- `Yearly/PhotoOriginals.swift`：PhotoKit 原始资源提取、iCloud 进度、取消和磁盘预算。
- `Yearly/OriginalMetadata.swift`：ImageIO / AVFoundation 元数据与日期可信度。
- `Yearly/UploadCore.swift`：持久化模型、原子队列文件、SHA/CRC、原件选择策略、分片续传与退避。
- `Yearly/UploadAPI.swift`：现有 HTTPS Cookie/CSRF API 与隔离的 OSS PUT。
- `Yearly/UploadQueue.swift`：顺序工作队列、逐资源检查点、前后台暂停恢复与清理。
- `Yearly/YearlyApp.swift`、`Yearly.xcodeproj/project.pbxproj`、`PrivacyInfo.xcprivacy`：入口、工程引用和仅本机磁盘空间用途声明。
- `Tests/UploadTests.swift`、`Tests/UploadAPITests.swift`、`backend/tests/test_native_uploads.py`：合成素材和服务模拟回归。
- `scripts/ios.sh`：CLI 验证、合成大文件测试、无签名模拟器构建与免费开发签名构建。

修改文件还包括 `backend/app/uploads.py`（可选幂等回执与能力响应头），以及 `README.md`、`README.en.md`、`docs/storage-and-metadata.md`、`docs/en/storage-and-metadata.md`、本 `ios/README.md`（同步入口、真实分片配置、安装和验收说明）。总计新增 9 个文件、修改 10 个文件。没有修改前端业务代码、数据库模型或迁移。
