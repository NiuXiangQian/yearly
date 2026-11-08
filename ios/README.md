# Yearly iOS 原生上传助手：开发与使用

基于已有 `codex/ios-app-install` 分支增量实现，最低 iOS 16。复用既有 SwiftUI 工程、PhotoKit 原件提取及持久上传队列，当前 App 使用原生登录、时间线、家人筛选、影像预览和上传任务，不再加载 WKWebView。既有 Vue 网页独立保留。旧网页外壳源码移至 `LegacyWebShell/` 备查，不参与编译。Bundle Identifier 仍为 `family.yearly.app`，无需付费 Apple Developer Program、TestFlight、App Store Connect 或新 Capability。

**当前状态：已通过 Xcode 真机构建、Personal Team 签名安装和 iPhone 15 启动检查。真机相册、iCloud 和批量上传的端到端验收待完成。**

## 免费 Apple 账号安装与续签

1. 在 Mac 安装完整 Xcode 和 iOS 平台组件，首次打开完成组件安装及许可确认。仅 Command Line Tools 不含 UIKit/iOS SDK。
2. Xcode → Settings → Accounts，添加自己的免费 Apple Account。
3. 打开 `ios/Yearly.xcodeproj`，选择 **Yearly** scheme 和 target；在 **Signing & Capabilities** 勾选 **Automatically manage signing**，Team 选择自己的 **Personal Team**。
4. 先保留 `family.yearly.app`。如果该标识不能由你的 Team 注册，将 target 的 Debug/Release Bundle Identifier 改为自己的唯一反向域名，例如 `me.yourname.yearly`。之后保持 Team 和 Bundle Identifier 稳定，以便覆盖安装、保留缓存。不要提交个人签名文件。更换 Bundle Identifier 会成为另一个 App，旧任务不会自动迁移。
5. 用数据线连接 iPhone，在设备上选择“信任此电脑”。按系统提示启用“设置 → 隐私与安全性 → 开发者模式”，必要时重启。在 Xcode 选择这台 iPhone，点击 **Run（⌘R）**。
6. 如系统要求信任开发者，在“设置 → 通用 → VPN 与设备管理”中信任相应 Apple 账号。首次运行输入可访问且证书有效的家庭站点 **HTTPS 地址**，例如 `https://example.com/yearly/`，在原生登录页输入家庭账号、密码和图片验证码。
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

模拟器的无签名构建仅用于编译检查；运行原生登录和 Keychain 时，应在 Xcode 选择 Team 后正常 Run，或用 `xcodebuild DEVELOPMENT_TEAM=你的TeamID` 默认签名构建。无签名 App 缺少 Keychain 身份会显示安全登录状态读取失败，不能通过改存普通文件绕过。本轮已使用带身份的模拟器构建确认登录页和站点验证码正常显示。

`YEARLY_BUNDLE_ID` 可选，默认为 `family.yearly.app`。站点可在 App 内配置，个人安装无需填写发行隐私/支持 URL。原有 `archive` / `export` 是可选的付费商店发行工具，保留供历史流程使用；它们不是编译、安装、运行、续签的前提，也不代表应用已具备上架条件。

## 手机上如何使用

1. 在原生登录页登录家庭账号。旧网页 Cookie 不迁移，升级后的首次使用需重新登录；密码不保存，会话存入 Keychain。只读账户可以浏览，不能上传。
2. 底部提供 **时间线、上传、家人、我的** 四个原生页面。点击“上传”进入“珍藏原片”；家人页与时间线筛选支持孩子、人物、宠物。
3. 点击“从系统相册选择照片与视频”。首次说明照片权限；可选有限访问。系统选择器支持多选、取消选择，按点选顺序回传。有限访问中不在授权范围内的资源会提示失败，可点“管理允许访问的照片”加入后重试；不会改成有损副本来绕过权限。
4. 逐项提取原始资源到应用私有目录。iCloud 资源允许联网下载，显示 Photos 提供的下载进度；尚未有进度时显示准备状态，不虚构百分比。可取消或暂停。缩略图只是预览，不作为上传源。
5. 资源提取后显示原始文件名、准确大小、可解析的拍摄时间、Live Photo 图片/MOV 两份状态。原件拍摄日期不可用时，时间线使用 iPhone 相册日期归档。可以手动指定本批的归档日期。只有编辑后版本可用时，明确标记“不是相机未修改原片”，确认后才上传。
6. 点击“关联人物与宠物”，搜索并多选孩子、人物、宠物；选择立即保存在本机，重启或下次上传自动恢复。按站点完整路径和账号分别记忆；清空后保持“仅家庭时光”。升级首次会尝试恢复本账号最近一次已确认批次的关联，没有记录时选一次即可。成功读取人物列表后才剔除已删除人物，网络失败不清空记忆。设置批次名称及可选归档日期；归档日期仅影响时间线位置，不改原件、原始拍摄时间或已有重复媒体的信息。
7. 重复选择队列里的项目、确认时发现同原件或服务端判重，都会显示醒目的重复提醒，列出文件名；同一批次聚合提示，其他文件继续处理。点击底部固定的“上传所选 N 项”，确认框显示本次数量、大小和关联人物；随后准备好的其他文件留待下一次确认。每项独立上传、重试、暂停、继续、取消；取消需再次确认。已结束记录默认收起，可打开开关查看。Live Photo 两份资源全部通过服务端校验才完成；MOV 失败时不会宣告整个 Live Photo 成功。
8. 完成后返回原生时间线。点图片进入全屏，图片完整适配屏幕并支持缩放；视频与 Live Photo 使用 AVPlayer 有声播放，LIVE 标识保留在画面上。点击时间线实况图打开后即播放；再次点击画面或 LIVE 总是从头播放，播放结束回到静态图。动态预览仍由既有后端工作进程生成，未生成时显示等待提示。影像信息页可修改人物关联；日记仅阅读，复杂编辑仍使用独立网页。

### 查找和分享回忆

- 点开影像后左右滑动切换，双指放大后可拖动画面。长按缩略图可拖到同一天、同一文件夹的另一项旁边调整顺序。详情的“⋯”提供影像信息、保存到相册和移到回收站。回收站入口在时间线右上角，可恢复误删的影像。
- 编辑影像支持标题、批次、备注、标签、归档日期、拍摄时间校正和时区、地点和经纬度、人物关联及分享权限。保存到相册会下载并校验原件。实况照片的原图和配对视频通过同一次 PhotoKit 写入合成一个相册项目，原件内嵌元数据随文件保留。Yearly 内单独编辑的标签和备注保存在家庭站点。
- 上传页显示原件就绪数量、已读取或已上传的字节数和传输网速。进度按已处理字节除以总字节计算，预计时间按剩余字节除以实测速率计算。相册未提供总大小时，准备阶段先显示已读取字节。上传达到 100% 后仍需等待完整性校验。任务列表默认展示进行中的任务与最多三条等待项，可展开全部。
- 日期分享默认从服务端最早可分享的日期开始。也可选最近一年、最近半年或自定义开始日期，结束日期可独立调整。
- 切换标签页复用已加载的时间线，手动下拉刷新可获取最新内容；账号变化清空原列表和分页状态。图片采用 512 像素缩略图 / 2048 像素预览解码，以及按站点、账号和资源隔离的短时内存缓存（120 秒、32 MiB 成本预算、最多 100 项），减少重复加载与解码；退出、切换账号和内存警告时清理。此处理仅用于屏幕预览，不改动上传原始字节。未进行真机帧率或长时间大批量内存基准测试。
- 时间线支持搜索标题、批次、备注与地点；顶部可切换全部、照片、实况和视频。筛选按钮可多选家人、限定归档日期范围（含结束当天）、切换从早到晚；可一键清除筛选。分页跟随当前条件，切换条件不会复用旧游标。
- 全屏左右滑动按当前时间线的日期顺序浏览。底部显示日期、当天序号和总数、当前筛选范围的序号和总数。跨到下一天时当天序号重新计算，实况照片算一项，日记不计入影像数量。“按上传时间”模式显示上传日期。
- 时间线右上角、“我的 → 创建分享与管理链接”、每天的“分享当天”和详情页分享按钮均可打开原生分享页。
- **指定影像分享**：时间线点“选择”，按顺序勾选 1 至 200 项照片、视频或实况图，再点“分享所选”；可跨日期和分页选择。分享前展示所选缩略图与文件名，Live Photo 作为一个逻辑媒体。详情页分享按钮和长按卡片“分享这项影像”可分享单项，拍摄日期未知也支持。链接不包含未选内容，以后新增照片也不会加入。
- **日期范围分享**：填写标题、起止日期和 1 至 168 小时的有效期。按天发起时预填当天。创建前再次展示范围，链接包含该日期内全部允许分享的家庭回忆及此后新增的可分享内容。
- 创建后可使用 iOS 系统分享面板自行选择微信等接收方式，或复制链接。接收者无需登录，只读浏览图片/视频/Live Photo 预览，不获得原件或编辑权限。复制仅写本机剪贴板，并设置与链接相同的到期时间。
- “分享记录”显示最近 100 条及生效、到期、撤销状态。创建者可以在有效期内打开、复制或再次发送新版链接。老记录只有校验值，可按原范围生成新链接，原链接仍按原有效期和撤销状态生效。只读账号可以通过有效分享链接浏览公开预览。
- 分享复用 `POST/GET /api/shares`、`DELETE /api/shares/{id}` 和 `/yearly/share/{token}` 网页。指定分享提交 `media_ids`，不混入日期参数；范围、权限、撤销和到期均由服务端校验。旧日期链接行为保持不变。
- 指定分享需要后端迁移 **0012**（`timeline_share.media_ids` 可空 JSON，MySQL 5.7 支持）。先升级数据库和接口再安装新版。旧接口会拒绝该请求；客户端若收到未确认指定范围的响应，会尝试撤销且不提供链接，绝不退化成整天分享。回退迁移会先撤销指定分享，避免旧代码扩大链接范围。

### 编辑影像与日期

- 在全屏预览点铅笔图标，或长按卡片进入编辑。可调整标题、备注、标签、人物、地点、拍摄时间校正、归档和分享权限，也可查看原件校验值或移动到当天的文件夹。
- “当天操作”可将归档日期带入上传页、创建当天日记、选中当天已加载的影像。“当天设置”可管理分享权限、文件夹和当天的排序。
- 多选后的“更多操作”可批量改归档和批次，追加、移除或替换人物关联，移动到文件夹，也可用选中影像创建日记。长按日记卡片或从预览点铅笔可以编辑，移到回收站的日记可恢复。

### 编辑家人和宠物档案

- 在“家人”点对应档案的“编辑”。可以填写姓名、昵称、关系或宠物物种与品种、性别、出生日期与时刻、成长时间线和档案介绍。常见关系与物种可直接选择，也可自定义。
- “显示与管理”可以设置主题色、显示顺序和启用／归档状态。归档保留资料和已有的影像关联。
- 头像可以从已有时间线照片选择，也可以从手机相册选一张。手机照片会生成专用头像，点“保存”后走现有头像上传流程，头像文件独立于家庭时间线。

资源缓存最多 8 GiB，至少预留 512 MiB；临近上限先上传已准备的项目，再重试剩余项目。单份原件也必须装得下剩余预算。不会同时把几百张原件载入内存。所有未完成状态和已确认参数保存在 `Application Support/NativeUploads/queue.json`；文件位于每个 UUID 子目录，排除 iCloud 备份并设置 iOS Data Protection。

进入后台立即取消当前可取消操作并保存暂停状态，回到前台恢复原先运行的项目。系统强制结束后不承诺继续上传；下次打开显示已恢复任务，点“继续暂停任务”。原生队列独立持久化，切换原生页面不会丢失它。断网时保留原件和服务端分片，失败项目可单独重试。更换站点先暂停旧任务；每个任务绑定原站点和原账号，不能拿另一账号继续上传。

取消仅停止本机任务、删除本机缓存；现有 API 没有取消服务端任务接口，因此未完成分片按服务端原有 7 天清理策略处理，不额外增加删除权限。若最后一次完成请求已到服务端，取消不能撤回已经发布的媒体，可去网页检查。完整性冲突（409）保留证据、不自动重建；超过任务有效期（410）需取消后重新选择。

## 架构与真实 API 数据流

| 环节 | 实现与复用 |
|---|---|
| 原生界面 | `YearlyApp` 登录与 TabView、`NativeSession` Keychain 会话、`NativeTimelineStore` 分页筛选、`NativeTimeline` 原生图片/AVPlayer 预览，复用 `SiteOrigin` 和既有上传页面 |
| 选择 | `PHPickerConfiguration(photoLibrary: .shared())`，`selectionLimit=0`、`selection=.ordered`；按返回 identifier 顺序取 `PHAsset` |
| 原件 | `PHAssetResource.assetResources(for:)`；普通图片 `.photo`、视频 `.video`；Live Photo 通过 `.photoLive` 识别，优先 `.photo + .pairedVideo` |
| 编辑版本 | 仅在整组原始资源不存在时使用 `.fullSizePhoto + .fullSizePairedVideo`，或普通完整尺寸资源；不混用原始静态图与编辑后 MOV，并显式提示 |
| 提取 | `PHAssetResourceManager.requestData` 原始字节直接写文件，支持 iCloud、取消和写盘预算；无 `UIImage.jpegData`、截图、缩放或转码 |
| 指纹 | CryptoKit SHA-256 + CRC64/XZ（反射 ECMA 多项式，初始/最终异或全 1），每次读取 4 MiB，逐块 autoreleasepool；恢复前重算本机指纹 |
| 创建 | `POST /api/uploads` 一次提交一个逻辑媒体，携带所有 `files`、`child_ids`、批次、归档及原始元数据；每个队列 UUID 作为 `Idempotency-Key` |
| 续传 | `GET /api/uploads/{id}` 取 OSS 权威分片清单，验证序号与大小后跳过已完成分片 |
| 直传 | `POST /api/uploads/{id}/sign?number=N` → HTTPS 临时 URL → 独立无 Cookie 的 URLSession PUT |
| 校验 | `POST /api/uploads/{id}/complete`，原服务合并、HEAD 比较大小/CRC64；每份资源成功后持久化，再完成整个逻辑媒体 |
| 去重与关联 | 本机确认时跳过已有相同原件任务；服务端按原件角色、SHA-256、大小和媒体类型匹配，未完成重复返回 409，已完成重复返回空任务并合并人物关联。两者均不重复传 OSS；App 将重复项单独计为“重复已跳过”，保留旧日期和位置 |
| 清理 | 成功状态先原子写盘，再删除缓存；任一资源失败保留已完成状态，重试跳过成功资源 |

**分片配置以真实响应为准：**旧文档写 4 MiB，但当前 `backend/app/config.py` 和 `.env.*.example` 默认 `UPLOAD_PART_SIZE=16777216`（16 MiB）。客户端按任务返回的 `part_size` 处理，支持 4 MiB 等配置，不改变现有服务端设置。哈希读取固定 4 MiB；测试同时验证 4 MiB 和 16 MiB 上传。顺序资源提取、顺序逻辑媒体上传、每次一个分片，最大原件缓冲由分片大小约束。

PhotoKit 的 `writeData` 能直接导出文件，但不返回可取消的 request ID；为满足中途取消和低磁盘空间硬限，本队列使用同一资源管理器的可取消 `requestData` 字节流，保持同一资源原始字节。历史单张桥接 `LegacyWebShell/LivePhotoTransfer` 使用 `writeData`，现在仅留档，不参与 App 编译。[Apple 原始/完整尺寸资源类型说明](https://developer.apple.com/documentation/photos/phassetresourcetype)、[编辑后 paired video](https://developer.apple.com/documentation/photos/phassetresourcetype/fullsizepairedvideo)。

## 后端最小补充与兼容

仅修改 `backend/app/uploads.py`，无表结构、OSS 对象命名或权限变更；现有响应格式不变，所有客户端的重复未完成任务现在统一返回 409：

- 可选 `Idempotency-Key: UUID`。没有该头的原网页流程不变。
- 所有创建请求先锁定同一个现有用户行，短事务内串行检查内容与回执，避免两个家庭成员同时重复创建。锁定读取使用 MySQL 当前读，避免认证建立的 REPEATABLE READ 快照漏看刚提交的任务。带头请求查询现有媒体元数据中的内部 `_upload_receipt`。同一用户、同一 UUID 和同一规范化请求内容，返回原媒体和两份原任务；参数不同返回 409，过期未完成任务返回 410。记录与媒体在同一事务提交，防止创建响应丢失或手机重启后重复创建。
- 回执占用现有 JSON 元数据，不依赖 MySQL 8 新特性，不新增公共幂等框架。原始元数据来源可标记为 `ImageIO + AVFoundation`。客户端伪造内部回执字段会被清除。
- 已完成原件继续走既有内容去重与关联合并语义。未完成同原件需继续原任务，不另建任务；同一幂等键的恢复请求正常返回原任务。实况照片比较整组图片与 MOV，不会分裂成两个媒体。
- 按原始字节指纹去重；视觉相同但转码或改过元数据导致字节不同的文件，不判为同一原件。回收站媒体仍沿用原有规则，不静默复用。

**使用新原生队列前，家庭服务需要包含本分支这处后端更新。**客户端创建前检查 `GET /api/uploads` 的 `X-Yearly-Upload-Protocol: idempotent-v1` 响应头；旧服务器缺少此能力时直接提示更新，不创建任务，避免忽略未知请求头导致重复创建。本次没有部署生产服务、修改生产配置或数据库。

原生登录直接复用 `/api/auth/captcha`、`/api/auth/login`、`/api/auth/me`、`/api/auth/logout`。会话仅存 Keychain（解锁可访问、仅本设备），按完整站点路径隔离；密码、Cookie、CSRF 不存 UserDefaults、日志或队列 JSON。写请求保留 Origin/CSRF；401 清除会话并返回登录，原上传任务安全暂停。每次上传 API 校验原账号与编辑角色；切换账号不能操作其他账号的缓存任务。

API 网络使用 ephemeral URLSession，禁用共享 Cookie、凭据和响应缓存，拒绝重定向。OSS 上传与图片下载不附带账号凭据；AVPlayer 只接收签名预览 URL。站点地址兼容单域名子路径，如 `https://refblogs.com/yearly/`。无需关闭 CSRF 或放宽 Bucket。

时间线复用 `/api/timeline` 的游标分页与 `child_id` 筛选；人物复用 `/api/children`；预览复用 `/api/media/{id}/files/{file_id}/url`；人物关联使用 `/api/media/batch-children`，避免覆盖原件日期或其他元数据。

## 元数据和时间

ImageIO 只读属性/标签，保存可解析 EXIF、XMP、IPTC、Apple MakerNote、GPS、镜头、曝光、ISO、方向等；AVFoundation 只读 QuickTime metadata/视频尺寸与时长。所有嵌入字段无论是否能解析，始终保留在未修改的原始字节中。数据库 JSON 有大小预算，超预算时明确标为 partial，完整字段仍在原件。

可靠当地时间沿用项目顺序：EXIF DateTimeOriginal → EXIF DateTimeDigitized/CreateDate → 可解释的 QuickTime CreationDate → 未知。只有明确的匹配偏移进入 `original_offset_minutes`。不根据导入时间、临时文件 mtime、无明确时区的 numeric QuickTime 秒数制造拍摄时间。PhotoKit 的 UTC creationDate、位置与尺寸放在 `photokit_auxiliary`，与原始嵌入数据、归档日期分开。

Live Photo 读取图片 Apple MakerNote / XMP ContentIdentifier 与 MOV `com.apple.quicktime.content.identifier`。两者都存在时必须一致；系统没有解析出双方标识时，保留 PhotoKit 同一 PHAsset 的同版本配对依据并显示说明，不按文件名推测配对。未解析出的私有元数据仍随原件保存。

## 本次实际执行的验证

全部自动上传测试使用合成素材、URLProtocol Mock / FakeStorage 和隔离 `_test` MySQL；不上传私人照片到真实 OSS。

- `./scripts/ios.sh verify`：plist、Xcode 源文件清单（禁止活动源码引入 WebKit）、Swift 语法/类型检查、46 项地址策略检查、6 项发行工具测试、143 项原生上传断言、独立上传 HTTP 与原生会话模拟测试。
- 人物选择记忆专项测试使用独立 UserDefaults 测试域，覆盖重新创建实例、多选、显式清空、删除人物、旧批次回填及账号/域名/子路径隔离；会话 Mock 验证切换标签不重复拉取，以及账号变化后重新拉取。本次体验优化实际重跑 iOS 验证和 Personal Team 真机构建；未修改后端或 Vue，下面的后端/前端全套结果来自此前分享功能交付。
- 2026-11-08 人物记忆与体验更新：已在隔离 Mock App 检查上传页固定底栏、已选人物摘要、可搜索多选面板；新包已覆盖安装到 iPhone 15，用户解锁后通过 devicectl 成功启动。此结果仅确认安装和启动，不代替真实相册、iCloud 与大批量上传操作验收。
- 原生会话模拟覆盖登录验证码、Keychain 边界、站点路径隔离、恢复/退出/401、只读权限、CSRF，以及实况双资源时间线解析、人物/搜索/类型/日期筛选、排序、分页隔离和失败后保留列表。分享 Mock 覆盖创建、撤销、只读拒绝、日期/有效期限制、到期禁用、链接路径和令牌校验；使用独立 Mock App 检查原生分享布局，不创建真实分享。
- 上传模拟覆盖完整 Live Photo 才成功、断网保留、签名失效重新获取、分片恢复、重复原件跳过及重启恢复；原有 100 项混合批次和可选 `test-large` 保留。
- 后端全套 150 项测试、28 个子测试通过，包含两个独立 MySQL 事务并发创建、不同用户相同原件冲突、相同幂等键恢复，以及原有鉴权、HEAD 校验、人物关联测试。测试结果见本次交付说明。
- 前端 20 个测试文件、105 项 Vitest 测试与 `vue-tsc` / Vite 构建通过；本轮未修改 Vue 页面。构建保留既有大 chunk 提示。
- Xcode iOS 模拟器 Debug / Release 编译及 Personal Team 真机 Debug 构建通过；已在连接的 iPhone 15 覆盖安装并通过 devicectl 启动。当前免费 profile 到期时间为北京时间 2026-11-15 10:49，后续需重新签名。真实图库与批量上传尚未代替用户验收。
- 之前的 1 GiB 合成零字节流式测试最大 RSS 约 54 MiB，仅是 Mac Mock 进程实测，不能当作 iPhone 内存保证；本轮没有将其称为真机相机视频验收。

### 尚需真机/部署验收

- 需在 iPhone 验证 Personal Team 到期续签、真实系统选择器顺序和取消、有限图库授权更新、iCloud 下载进度及失败、编辑过的 Live Photo 原件选择和 ContentIdentifier。
- 使用专用测试家庭服务和合成媒体，验证真实 HTTPS Cookie/CSRF、OSS 临时签名、合并/HEAD、后台/锁屏/强杀、网络切换、低空间、中途重新登录和实际 100 张/1GB 视频内存。自动测试不向真实生产 OSS 上传。
- 全套自动测试使用本地隔离 MySQL 8.4.13；0012 迁移还在独立临时库验证新建、降级撤销指定分享和重复升级，并已在现有 MySQL 5.7.43 的 `yearly_test` 测试库完成升级。高并发行为仍以本地事务测试为依据。
- 不保证系统不可解析格式能提取所有元数据，不保证后台无限上传，不保证已在服务端完成的请求可被本机取消。网页和原生 Live Photo 预览都依赖既有预览进程；本轮未改变网页播放方式。

## 文件职责

- `Yearly/NativeSharingStore.swift`、`Yearly/NativeSharingView.swift`：限时分享创建、系统分享/复制、分享历史和撤销。
- `Yearly/NativeSession.swift`、`Yearly/NativeTimelineStore.swift`、`Yearly/NativeTimeline.swift`：原生认证、Keychain、分页筛选、影像预览和关联。
- `LegacyWebShell/`：原 WebView、下载、单项导入桥接备查，已从工程目标移除。
- `Yearly/NativeUploadView.swift`：原生选择器、确认页、缩略图、人物/宠物和任务操作。
- `Yearly/UploadPreferences.swift`、`Tests/UploadPreferencesTests.swift`：按账号和站点记忆关联人物及专项验证；仅保存人物 ID，登录凭据仍仅存 Keychain。
- `Yearly/PhotoOriginals.swift`：PhotoKit 原始资源提取、iCloud 进度、取消和磁盘预算。
- `Yearly/OriginalMetadata.swift`：ImageIO / AVFoundation 元数据与日期可信度。
- `Yearly/UploadCore.swift`：持久化模型、原子队列文件、SHA/CRC、原件选择策略、分片续传与退避。
- `Yearly/UploadAPI.swift`：现有 HTTPS Cookie/CSRF API 与隔离的 OSS PUT。
- `Yearly/UploadQueue.swift`：顺序工作队列、逐资源检查点、前后台暂停恢复与清理。
- `Yearly/YearlyApp.swift`、`Yearly.xcodeproj/project.pbxproj`、`PrivacyInfo.xcprivacy`：入口、工程引用和仅本机磁盘空间用途声明。
- `Tests/UploadTests.swift`、`Tests/UploadAPITests.swift`、`Tests/NativeSessionTests.swift`、`backend/tests/test_native_uploads.py`、`backend/tests/test_upload_dedup.py`：合成素材和服务模拟回归。
- `scripts/ios.sh`：CLI 验证、合成大文件测试、无签名模拟器构建与免费开发签名构建。

修改清单以 `git show --stat` 为准。指定分享本轮增加 0012 迁移和公开分享页的“所选影像”展示；不改变原件、上传协议或现有 Live Photo 播放组件。
