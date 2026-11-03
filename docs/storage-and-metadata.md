# OSS、原件与元数据

## 数据流与完整性

浏览器选择原件 → 范围读取元数据 → 4 MiB 分块计算 SHA-256 和 CRC64/XZ → 用户确认 → API 创建逻辑媒体 / 多孩子关联 / 任务 → API 签名每份分片 → 浏览器 PUT 到 OSS → API 从 OSS 获取权威分片清单并完成合并 → HEAD 验证大小与 CRC64 → 全部逻辑资源完成才发布媒体。

原件使用 `originals/YYYY/MM/UUID.ext`，兼容预览使用 `previews/YYYY/MM/UUID.ext`，不使用用户路径，不重用对象 Key。合并请求附带 `x-oss-forbid-overwrite=true`。分片 ETag 只作为 OSS 完成分片的标识，不作为整个文件 MD5。浏览器先计算整文件 CRC64，服务端比较 OSS 整对象 `x-oss-hash-crc64ecma`。SHA-256 为浏览器计算值，记录于数据库及对象元数据。HEAD 的 SHA-256 元数据是上传时的声明，不能单独证明对象字节 SHA-256。CLI 完整备份会逐字节分块重算 SHA-256，作为独立审计。

API 不接收二进制原件、不执行压缩、不修改 EXIF、不转码。可选预览文件通过相同独立任务上传，与 original / live_video 分角色保存。默认前端优先使用 preview，其次尝试原件，浏览器解码失败显示原件下载。没有内置服务端视频转码，未提供预览时，HEIC / RAW / 不兼容编码会显示下载入口。

浏览器每份文件顺序分片上传，每片失败自动重试 3 次并重新签名。任务有效 7 天，签名有效 15 分钟，下载 URL 有效 5 分钟。重新打开页面后从“接着珍藏”选择原文件，SHA-256 和大小必须一致，恢复时读取 OSS 已上传分片并跳过它们。浏览器没有后台永久运行保证，大视频上传时应保持前台。多个 Live Photo 资源分别恢复，最后一份完成后媒体出现。

完整性错误返回 409，媒体不会发布。若已合并对象与声明不一致，保留记录供核查，重新创建上传任务。每日清理会中止过期分片，保留已完成对象以供恢复调查，不执行自动物理删除。

## Bucket 与 RAM

1. Bucket 访问权限为私有，关闭公共读写，开启阻止公共访问。
2. 开启版本控制。应用不授予删除权限，清理器只中止分片。版本控制与离线备份共同使用。
3. RAM 专用用户参考 `deploy/oss-ram-policy.json`，将 bucket 名替换为实际值，仅授予 originals / previews 前缀的 GetObject / PutObject / AbortMultipartUpload / ListParts。备份工具使用同范围权限即可。
4. `OSS_REGION` 必须是如 `cn-hangzhou` 的地域标识，endpoint 为 `https://oss-cn-hangzhou.aliyuncs.com`。使用官方 SDK AuthV4 签名，永久密钥从不下发浏览器。
5. 浏览器 CORS 参考 `deploy/oss-cors.xml`。AllowedOrigin 精确为家庭站点 origin，允许 PUT / GET / HEAD，允许签名与内容头，暴露 ETag 和 CRC64。开发时单独添加 `http://127.0.0.1:5173`，生产移除开发来源。
6. URL 签名由数据库中的文件 ID 推导 Key。接口没有任意对象 Key 签名能力，且上传授权仅任务创建人可以获取。

不要关闭 SDK 的 CRC 检查，不要授予 Bucket 公共访问来解决跨域问题。调试 CORS、签名时查看 OSS request-id，请勿把完整带签名 URL 粘贴到日志或公开问题单。

## 中国内地 Endpoint 与自定义域名

新开通的中国内地 OSS 账户可能受到默认公网域名访问、默认域名预览或流量接入限制。实际限制以当前账户控制台和 OSS 官方提示为准，不假设仅填 Bucket endpoint 就一定可用。

可行部署路径是准备已备案域名，例如 `media.example.com`，在 OSS 控制台完成域名绑定，按控制台要求配置 CNAME、HTTPS 证书，再设置 `OSS_CUSTOM_DOMAIN=https://media.example.com`。SDK 使用 `is_cname=True`，仍保留正确 `OSS_REGION` 进行 V4 签名。前端 CSP 和 CORS 同时匹配站点与 OSS 域名。该域名必须直接指向 OSS，避免将数 GB 媒体流量绕回应用 Nginx。

签名时使用的域名必须与实际上传请求域名完全一致，不要在生成 V4 URL 后自行替换 Host。HTTPS 页面不得使用 HTTP OSS endpoint。使用适用地域的 OSS 自定义域名路径，并按账户能力复核下载 / 预览响应，所有上传大小与校验不受格式预览能力影响。

## 照片解析

exifr 通过 Blob 的分段读取器读取 JPEG、PNG、WebP、HEIC/HEIF、TIFF/DNG 和部分 TIFF-based RAW 的 EXIF / XMP / IPTC。配置保留日期字符串，避免无时区 EXIF 被浏览器先转换到 UTC。读取到的 Make、Model、LensModel、Software、Orientation、ISO、曝光、光圈、焦距、闪光灯、白平衡和 GPS 等原样保存。常用时间、坐标、设备、尺寸独立存储。

格式容器、厂商 MakerNote 或浏览器导出方式均可能导致字段缺失，CR3 / 厂商 RAW 等不保证完整解析。可上传保存这些原件，未读字段保持未知。原始 JSON 是浏览器实际解析结果，并不等于文件所有字节所承载的每一种厂商标签。元数据每个逻辑媒体限制 1 MiB，超出需保留原件后使用离线工具检查。

GPS 纬经度从 EXIF 或 QuickTime ISO6709 获取，海拔从可用字段读取，GPS 时间、方向等保存在 raw JSON。无默认地理编码或第三方位置请求。手工地点和 GPS 修正仅更新数据库，raw JSON 继续保留原值。

## 视频解析与时间可信度

有界 ISO-BMFF walker 按 box 范围读取，跳过 mdat，最大深度 12、总 box 数 12,000、单叶最多 1 MiB、元数据总读取 8 MiB。不把数 GB 视频载入内存。支持常见 MOV / MP4 的 mvhd 时长、tkhd 尺寸与旋转、stsd 编码、hdlr 音轨、mdhd/stts 恒定帧率近似及 QuickTime keyed metadata 的日期、位置和标识。

VFR、特殊音视频 track、旧式 ©day / 厂商私有字段、超出读取预算或不常见封装可能无法完整解析，不能把所有提取值都当成权威。原始 numeric QuickTime creation seconds 保存在 raw JSON，因厂商 UTC / 本地写法差异，默认不据此强行生成当地时间。只有可解释的 CreationDate 字符串进入可靠日期候选。

时间优先级为用户修正、EXIF DateTimeOriginal、EXIF CreateDate / 可靠 QuickTime CreationDate、文件修改时间（低可信度）、未知。无时区字符串保留原当地日期，只有明确偏移时计算 UTC。文件修改时间展示的是设备当前时区解释的文件 mtime，仅作备用候选，不宣称是拍摄日期。

系统保存原始时间、原偏移、原时间来源和独立修正时间。修改修正时间不会覆盖原元数据。详情清空修正可恢复原值。需要将低可信度时间改为未知时，使用上传前时间确认的“拍摄时间未知”选项。

## Live Photo 与 iPhone 限制

可靠配对优先使用解析到的 ContentIdentifier 或 `com.apple.quicktime.content.identifier`。Apple MakerNote 中的 assetIdentifier 不一定被 exifr 暴露，系统不会仅根据同名文件自动配对。

没有标识时，在批量上传列表将静态 HEIC/JPEG 的“手动配对”指向对应 MOV，组合为一条逻辑 media，两个 media_file 分别保存，孩子关联只对逻辑媒体生效。用户可在上传前解除配对。长按详情画面播放 MOV，两个原件各自提供下载入口。浏览器不支持 HEIC 或 MOV 编码时，额外提供 JPG / MP4 预览或下载原件。

iPhone Safari 从照片图库选择的文件可能经过格式转换、编辑导出，也可能只提供静态资源。纯 Web 无法强制取得 PhotoKit 原始照片和所有 pairedVideo 资源。想保留原件，应在系统照片中导出“未修改的原片”到文件 App，并双文件导入。系统只保证所选字节无损上传，不根据扩展名宣称相机原件真实性。

未来原生 iOS PhotoKit 助手可以复用逻辑媒体创建 / 任务 / 分片签名 / 完成核验接口，将 PHAsset 的原始照片和 pairedVideo 分别作为 original、live_video 提交。会话认证、CSRF 和权限边界继续生效。
