# yearly iOS App

面向 iPhone（iOS 16+）的 SwiftUI + WKWebView 客户端。沿用现有 Vue 页面、HTTPS 家庭站点、登录 Cookie 和 OSS 上传流程；原生部分提供连接设置、系统实况照片选择、下载与分享、返回手势和错误恢复。不需要修改数据库，也不需要引入 Capacitor 或另建一套 API。

当前交付为 **App 工程及发布工具**，不是已经签名、真机验收或通过 App Store 审核的安装包。提审阻塞项见下文。

## 本地安装与验证

1. 在 Mac 安装完整 Xcode 和 iOS 平台组件。仅 Command Line Tools 无法编译 UIKit / WebKit iOS App。
2. 部署本仓库的前端与 API，使用可被 iPhone 访问且证书有效的 HTTPS 根地址。App 不放开 HTTP 或忽略证书错误。
3. 打开 `ios/Yearly.xcodeproj`，选择共享 Scheme **Yearly**。
4. 在 **Signing & Capabilities** 选择自己的 Team，把 `family.yearly.app` 改为自己的唯一 Bundle Identifier。
5. 连接 iPhone，在 Xcode 选择该设备并运行；按系统提示完成设备信任和开发者模式设置。
6. 首次打开输入家庭站点并登录。上传页的「选择实况照片并上传」沿用已有原生桥接，一次选择一张 Live Photo；照片和视频合计上限 128 MiB。

无签名的模拟器构建不能安装到 iPhone。设备运行与发行签名方式参见 [Apple 设备运行说明](https://help.apple.com/xcode/mac/current/en.lproj/dev5a825a1ca.html)。

```bash
# 在仓库根目录执行；基础校验只需要 macOS CLI 开发工具
./scripts/ios.sh verify

# 完整 Xcode：编译 Debug、Release 模拟器版本，不需要签名
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/ios.sh build
```

`verify` 检查 Swift 语法、站点同源限制、下载 URL、Xcode 源文件与资源引用、图标尺寸/透明度和 plist。它不等同于 iOS SDK 类型检查或真机测试。新增的 GitHub Actions 在后续 push / PR 时执行模拟器构建；本次未触发远端工作流。

## App 内行为

- 站点地址只接受 HTTPS 根地址，不接受账号密码、页面路径或查询参数。站点和登录状态可跨启动保存。
- 顶部菜单提供重新加载、站点设置、隐私政策与支持页面；默认地址可在发行时设置。
- WebView 保持在配置的同源站点，相册接口只接受该站点主框架的请求。外部 HTTPS 普通链接交给系统浏览器，新窗口同源链接在当前 App 打开。
- JSON / CSV 导出保留 App 登录 Cookie；OSS 带 attachment 参数的原件链接使用原生下载，完成后显示系统分享菜单，可选择「存储到文件」。同时仅处理一项下载，失败后手动重试。
- 使用系统相册选择器读取用户选中的实况资源，不请求整个图库的授权。相机、麦克风、保存相册用途说明供网页拍摄/系统保存操作触发时使用，不在启动时主动请求。
- 上传/下载请保持 App 在前台。当前没有离线图库、后台持续上传、推送、通用链接或 StoreKit 购买。
- 更换站点会结束当前操作，但不注销旧站点账号；退出登录使用网站自己的退出按钮。

## App Store 归档

使用已加入 Apple Developer Program 的发布账号，在 Xcode 登录。先注册 Bundle ID 并在 App Store Connect 创建对应记录。不要把证书私钥、账号密码、审核账号或签名配置提交到仓库。

归档脚本要求明确填写实际站点和公开政策链接，拒绝空值、示例域名和本地地址。支持页面和隐私页面必须无需登录即可访问。下方值需要替换为真实信息：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export YEARLY_TEAM_ID='你的10位TeamID'
export YEARLY_BUNDLE_ID='你的已注册BundleID'
export YEARLY_SITE_URL='https://你的正式站点'
export YEARLY_PRIVACY_URL='https://你的政策页面'
export YEARLY_SUPPORT_URL='https://你的支持页面'
export YEARLY_VERSION='1.0'
export YEARLY_BUILD_NUMBER='1'

./scripts/ios.sh archive
./scripts/ios.sh export
```

归档位于 `.local/ios/Yearly-版本-构建号.xcarchive`，导出 IPA 位于 `.local/ios/Export-版本-构建号/`。已有同名输出不会被覆盖；每次发布递增构建号。脚本不上传、不创建商店记录、不提交审核。用 Xcode Organizer 打开归档，先 **Validate App**，再选择 **Distribute App → App Store Connect**。导出的 App Store IPA 不能作为任意 iPhone 的直接安装包；测试安装走 TestFlight，正式安装走 App Store。

在 Xcode 手动 Archive 时，同样要在目标的 User-Defined Build Settings 设置 `YEARLY_SITE_URL`、`YEARLY_PRIVACY_URL`、`YEARLY_SUPPORT_URL`，否则 Info.plist 中相应链接为空。

发行方式以 [Apple 发布文档](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases) 和 [TestFlight 文档](https://help.apple.com/xcode/mac/current/en.lproj/dev2539d985f.html) 为准。使用符合提交时要求的 Xcode / iOS SDK；最低运行版本 16.0 不代表使用 iOS 16 SDK 提交。

## 提审前必须补齐

1. **永久注销账户流程。** 现有网页允许管理员创建账户，但 `DELETE /api/users/{uid}` 只停用账户和撤销登录，不是永久注销。需要在 App 内提供可发起永久删除的流程，并确定家庭共同照片、日记、分享、原件和备份的保留/删除方式、最后一位管理员的处理方式。不能把停用改名为注销。此项尚未实现，不应直接提交审核。参见 [Apple 账户删除要求](https://developer.apple.com/help/app-review/guideline-reference/5-1-1-account-deletion/)。
2. **发布者信息与实际链接。** 提供 Team ID、Bundle ID、正式 HTTPS 服务、隐私政策、用户支持页面。服务器、MySQL 和 OSS 需要持续可用，支持页面应提供真实运营者联系方式。
3. **隐私披露核对。** `PrivacyInfo.xcprivacy` 已声明本机 UserDefaults 的 CA92.1 用途，并按现有功能列出姓名、账号 ID、照片/视频、音频、日记等用户内容、EXIF 位置和生日等其他数据，仅用于 App 功能，不用于追踪。这是代码层面的初始清单；发布者仍需核对实际托管、访问日志、OSS、保留期限和备份行为，完成政策正文与 App Store Connect 隐私问卷，不能因为没有定位权限就遗漏照片里的 GPS。参见 [Apple 隐私清单说明](https://developer.apple.com/documentation/technotes/tn3184-adding-data-collection-details-to-your-privacy-manifest)。
4. **真实构建与真机验收。** 当前开发机没有完整 Xcode / iOS SDK，未完成 iOS SDK 编译、签名、模拟器或真机验收。`swiftc -parse` 通过不能证明 App 可以安装。
5. **审核资料。** 准备使用虚拟家庭资料的可用审核账号及完整测试说明，说明服务的部署/登录前提。截图必须来自实际 App。不能用个人真实家庭照片、凭据或未验证的界面效果充数。
6. **产品与审核范围。** App 保留 Web 页面，并提供原生照片选择、下载/分享等能力；仍需按实际体验核对 [App Review Guidelines 4.2](https://developer.apple.com/app-store/review/guidelines/#minimum-functionality)，不能保证通过审核。商店文案应明确是需连接 yearly 家庭服务的客户端，不宣传离线、后台备份或自动同步。

## 真机验收清单

- 首次连接、无效地址、证书失败、断网重试；退出重启保留站点和登录。
- 登录、退出、角色权限、中文/英文网页、浅色/深色网页；系统深色、横屏、字体放大和键盘弹出。
- 时间线、日记、人物与宠物、设置；底部导航不被 Home Indicator 遮挡，返回手势正常。
- 普通照片/视频、HEIC、单张 Live Photo；本地/iCloud 资源、取消选择、拒绝拍摄权限和上传失败重试。
- 实况照片只生成一条记录，静态/动态原件可分别下载，动态预览可播放。
- CSV、JSON、OSS 原件下载后分享/存储，失败与重复点击有反馈；同源新窗口分享页可打开。
- 切换站点、上传中重载、App 进入后台、Web 内容进程终止；外部页面不能调用原生相册桥接。
- 完成注销流程后，验证删除确认、身份校验、关联数据处理、旧会话失效和最后管理员场景。
- TestFlight 安装发行版本，再确认隐私/支持链接、图标、版本号和所有原生功能。

## 图标

`Assets.xcassets/AppIcon.appiconset` 包含 iPhone 所需尺寸和无透明通道的 1024px 商店图标。使用项目现有鼠尾草绿和叶片元素，生成脚本可以复现：

```bash
swift ios/scripts/generate-icon.swift ios/Yearly/Assets.xcassets/AppIcon.appiconset
```
