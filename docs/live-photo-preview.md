# 实况照片预览

详情和分享页采用 [WebLivePhoto](https://github.com/link9596/WebLivePhoto) 的叠层播放方式，已按 Vue 生命周期和 Yearly 私有资源接口适配，MIT 来源见 [第三方声明](../frontend/THIRD_PARTY_NOTICES.md)。

- 手机长按照片播放，松手回到静态照片。滑动或双指操作会取消播放。
- 电脑将鼠标移到照片上播放，移开后停止。
- 点击照片或 LIVE 均从头播放，正在播放或已经播完也可再次点击重播。视频和实况图默认开启声音，右上角声音按钮可静音。浏览器阻止悬停有声播放时，点击 LIVE 即可重试。
- 时间线与分享列表缩略图等比缩放、完整显示，必要时留边；LIVE 标识保留在图片原位置。
- 分享链接中点击图片、视频或实况图，直接铺满当前屏幕预览；右上角关闭后回到分享列表。加载时也保持全屏，适配手机安全区域，无需浏览器全屏授权。
- 登录后的详情页可切换静态照片进行缩放，也可点全屏按钮放大预览区域。
- 动态预览尚未生成时会保留静态图，后台就绪后可播放。失败时点 LIVE 重试，会重新获取签名。
- 默认播放已有 H.264 MP4 预览。点击“查看动态原件”才请求原始 MOV，原件播放能力取决于浏览器。

本次修改不改变上传协议、原始 HEIC/MOV、配对信息、数据库或分享权限。网页更新后重新打开页面即可。原生 App 使用独立 SwiftUI/AVPlayer：点击实况缩略图打开即播放，再次点击画面或 LIVE 从头播放；需安装新版 App。

## 自动验收

使用项目要求的 Node.js 22 或更新版本。

```bash
cd frontend
npm test
npm run build -- --base /yearly/
```

浏览器测试可使用已安装的 Playwright WebKit 和 FFmpeg，仅生成纯色静态图与测试图案视频。测试启动本地 HTTP Mock，不连接实际 OSS、后端或私人照片。

```bash
# 仓库根目录。Playwright 单独安装于测试工具目录即可，不是应用运行依赖。
fixture_dir=$(mktemp -d)
ffmpeg -f lavfi -i color=c=gold:s=360x640 -frames:v 1 "$fixture_dir/still.webp"
ffmpeg -f lavfi -i testsrc2=size=360x640:rate=24 \
  -f lavfi -i sine=frequency=440:sample_rate=44100 -t 2.5 \
  -c:v libx264 -c:a aac -pix_fmt yuv420p -movflags +faststart "$fixture_dir/motion.mp4"
node scripts/check-live-photo.mjs frontend/dist "$fixture_dir" /path/to/playwright/index.mjs
```

检查手机和桌面 WebKit 下的登录后详情、日期分享和指定影像分享预览、真实 MP4 播放、连续点击画面与 LIVE 重播、静音切换、播放结束返回静态图、手机无交互不请求视频、全屏与键盘焦点、静态缩放入口、无横向溢出。截图仅含合成素材，保存在 `fixture_dir`。

2026-11-08 实际结果：105 项前端测试通过，`/yearly/` 构建通过，WebKit 手机/桌面浏览器验收通过。构建仍有已有 HEIC 解码包较大的提示。这里的手机验收使用 WebKit 的 iPhone 视口模拟，不能代替真实 iPhone Safari/WKWebView、低电量模式、真实网络与私有 OSS 的验收。

有声播放遵守 [WebKit 用户手势策略](https://webkit.org/blog/6784/new-video-policies-for-ios/)，不会用强制静音掩盖播放限制。设备音量、静音开关和没有音轨的原素材仍会影响实际可听声音。
