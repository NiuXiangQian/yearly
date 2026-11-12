# iOS 相册分享上传

相册选中照片、视频或实况照片（最多 20 项）→ 分享或操作菜单中的 yearly → 预览、移除媒体、选择人物或宠物 → 确认上传。

- 更新安装后先打开 yearly 一次，以同步当前家庭站点；分享扩展复用钥匙串中的现有登录状态。未登录、登录过期和只读账号会提示在 App 内登录或切换账号。
- 支持常见照片、MOV / MP4 视频和实况照片。保留实际收到的文件字节；实况照片读取同一资源组的图片和配对视频，校验配对标识。系统声明实况类型时必须完整读取，不会退回 JPEG 静态封面上传。用户明确关闭实况、系统仅提供静态类型时按普通照片上传。系统可能提供编辑或转换后的文件，不能保证是相册未修改原片。
- 复用现有 `/uploads` 协议、人物权限、幂等请求、哈希与 CRC64 校验和断点续传，不需要后端或 Android 更新。图片没有拍摄日期时可以指定归档日期，否则按现有服务端规则归档。
- 上传期间保持分享窗口打开。关闭或进入后台会暂停；下次打开同一分享入口时可继续或取消此前未完成任务。两个扩展各自的队列位于其独立沙盒，不迁移、不覆盖 App 现有的 `NativeUploads` 队列。
- 未确认的新照片在点击关闭时取消；已确认任务保留服务端任务 ID 和原件缓存。上传成功后清理缓存。再次上传相同内容使用现有重复处理规则。

## 签名与兼容

`YearlyShare` 为随 App 打包的 Share Extension，Bundle ID 为主 App Bundle ID 加 `.share`；`YearlyAction` 为操作菜单扩展，Bundle ID 加 `.action`。两个扩展复用同一上传界面。主 App 和扩展使用主 App 原有的默认 Keychain Access Group，确保历史登录记录仍可读取；不使用 App Groups，也不把凭据写入 UserDefaults 或队列 JSON。

`scripts/ios.sh` 继续接受 `YEARLY_BUNDLE_ID`，并将其作为 `YEARLY_APP_BUNDLE_ID` 同时传给三个 target，避免为二者指定相同 Bundle ID。真机签名需要现有有效证书，以及同时允许主 App、两个扩展和目标设备的描述文件。缺少任一扩展描述文件时停止真机交付，不自动注册设备、更新描述文件或吊销证书。

CLI 验证：`./scripts/ios.sh verify`。完整 Xcode 构建：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/ios.sh build`。

旧 App 的请求和响应、本机队列格式、站点偏好及登录服务保持不变；旧版本继续在 App 内选择照片上传。新增系统分享入口只在安装新版后提供。

## 首版验证记录（2026-11-12，仅普通照片）

- `scripts/ios.sh verify` 通过：项目打包与签名脚本检查、现有上传与会话回归，以及新分享文件的格式识别、原始字节、EXIF、账号隔离和任务恢复检查。
- 主 App 与扩展的 Debug、Release 模拟器构建通过。
- iOS 27.2 模拟器的 5 项真实界面测试通过：系统分享面板唤起扩展并接收两张图片，人物与归档日期选择及确认上传，深色 320pt 窄屏与移除照片，未登录提示，失败后重新打开窗口继续上传。
- 界面测试使用虚拟图片、虚拟账号及模拟网络响应；未验证真实 OSS、真机钥匙串共享、iOS 16 实机或旧版 App 覆盖升级。当前手机未连接，且本地没有新 `.share` 扩展的描述文件，未执行真机安装或签名材料变更。
- 测试日志、结果包及截图保存在 `.local/share-upload-20261112/`。


## 照片、视频与实况照片扩展验证（2026-11-12）

本次完整工作区通过主 App、分享扩展、操作扩展三个 target 的 clean 构建：Debug / Release 模拟器、Release 真机签名构建均成功。命令行回归覆盖真实照片和视频文件字节、EXIF、生成的 Live Photo 图片 / MOV 配对标识、账号隔离、请求字段、恢复及非法文件。

完整包已覆盖安装到 iPhone 15，版本 `2026111210`，启动及运行进程已核验；保留应用数据。复用原证书和主 App、分享扩展描述文件，新增操作扩展使用本机已有且有效、覆盖设备的 `.action` 描述文件；未自动注册设备或吊销证书。构建源码、签名和安装记录在 `.local/ios-full-20261112/`。本轮未在真机自动操作完整分享上传，也未验证旧版系统实机。

## 照片、实况、视频与快捷操作扩展验证

- 本轮使用合成 JPEG、带 ContentIdentifier 和 still-image-time 的 MOV 生成真实 `PHLivePhoto`；不使用私人影像。
- CLI 媒体与既有上传/会话回归通过。6 项模拟器界面检查通过：三种媒体混合上传、实况失败后重开续传、未登录、深色 320pt 窄屏及移除、上方分享入口、下方快捷操作。实况入口由测试 Provider 提供系统构造的 `PHLivePhoto`，照片与视频另经系统分享面板真实交接给两个扩展。
- 首次窄屏检查和 Release 构建曾因本机磁盘空间不足中断，清理本任务生成的构建缓存后重跑；没有修改缓存空间保护规则。
- 最终主 App、分享扩展和快捷操作扩展的 Debug / Release 模拟器构建通过，下方操作的系统上传图标已截图核验。
- 测试日志、结果包与截图位于 `.local/share-media-20261112/`。网络仍使用模拟响应，真机钥匙串共享、真实 OSS 和旧版本实机覆盖升级未验证。
- 本次不变更后端协议、上传记录结构或 App 内历史队列；普通照片、实况和视频继续沿用已有 `photo`、`live_photo`、`video` 及 `original`/`live_video` 契约。

## 原生相册实况丢失动态修复（2026-11-12）

- 真机原任务核验：分享和快捷操作队列记录为 `photo`，仅有 JPEG `original`，没有 `live_video`。问题发生在读取相册分享资源时，早于创建上传任务。
- 原生 Photos 在模拟器提供 `public.jpeg` 和 `com.apple.live-photo`，但 `canLoadObject(PHLivePhoto.self)` 为 false；强制 `loadObject`、读取 Live Photo 文件或数据表征均失败。原逻辑因此选中了 JPEG。此前构造 Provider 的测试没有覆盖该系统交接路径。
- 增加 Objective-C 类型明确的 `loadItem` 回调读取 Photos 的旧式实况对象，同时保留现代 `NSItemProviderReading` 路径。类型明确的回调是公开 API 的类型转换约定：[Apple loadItem 文档](https://developer.apple.com/documentation/foundation/nsitemprovider/loaditem(fortypeidentifier:options:completionhandler:))。两扩展显式声明实况类型；声明实况后读取失败不会静默降为照片。
- 用合成图片和 3 秒 MOV 导入系统 Photos 为实况，通过原生相册上方分享和下方快捷操作分别提取并确认上传，两项 UI 测试通过。两个扩展的实际队列均为 `live_photo`，各含 `original: image/jpeg` 和 `live_video: video/quicktime`，状态 `complete`；网络使用模拟响应，没有上传私人影像。
- CLI 全套回归及现代 Provider 的照片、视频、实况混合确认上传通过；本次保持服务端协议、队列字段、登录钥匙串和主 App 上传路径不变。已变成静态照片的历史记录无法凭 JPEG 恢复 MOV，需要从相册原实况重新分享。
- Release 完整代码包 `2026111213` 已保留数据覆盖安装至 iPhone 15。全部代码提交 `bfbbe78` 已推送，安装包源码与该提交一致；用户解锁后启动成功，版本及运行进程已核验，记录在 `.local/push-all-install-20261112/`。复用同一证书及三个现有描述文件，证书 OCSP 校验通过；证书到期 UTC `2027-11-12 00:45:12`，三个描述文件到期 UTC `2026-11-19`。未更新描述文件、注册设备或吊销证书。
- 证据保存在 `.local/share-live-fix-20261112/`：`native-live-both.xcresult`、`native-screenshots/`、两个 `*-verified-queue.json`、`final-verify.log`、源码快照、签名与安装记录。尚未自动验证真机真实 OSS 上传、iOS 16 实机及旧版二进制覆盖升级。
