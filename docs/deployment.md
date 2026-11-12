# 部署到已有 MySQL 与 Nginx

**简体中文** | [English](en/deployment.md) · [返回首页](../README.md)

## 环境选择

本地测试使用 `.env.test`、`yearly_test` 与测试数据库账号，启动命令为 `scripts/start-local.sh`。正式部署使用 `.env.production`、`yearly` 与正式数据库账号。两套配置均使用 MySQL，页面和健康检查显示当前环境。以下步骤针对正式环境，首次数据库初始化完成后可跳过建库与建表步骤。

## 当前线上入口

当前站点统一使用 `https://refblogs.com/yearly/`，`yearly.refblogs.com` 自 2026-11-12 起废弃，服务器对旧域名返回 HTTP 410。后续发布仅构建和切换 `/yearly/` 子路径版本，不再部署旧域名的根路径版本。网页、App 的站点地址和分享链接均使用上述 HTTPS 入口。

前端构建设置 `VITE_SHARE_ORIGIN=https://refblogs.com`，执行 `npm run build -- --base /yearly/`；后端对应 `ALLOWED_ORIGIN=https://refblogs.com`、`APP_BASE_PATH=/yearly`。旧站点配置中仍被 HTTPS 入口引用的共享限流区应保留，停用旧入口不删除数据库、媒体或历史发布备份。

## 1. 运行依赖

Linux、Python 3.12、Node.js 22.12+、已有 MySQL 5.7.8+、已有 Nginx。JSON 字段要求 MySQL 至少 5.7.8，推荐最新 5.7 补丁版本。无需 Docker，也无需新建 MySQL / Nginx 容器。建议数据库时间保持 UTC，拍摄当地时间单独按 DATETIME 保存。

将仓库放在 `/opt/yearly`，创建系统用户 `yearly`。Nginx 运行用户需能读取 `frontend/dist`，`.env.production` 权限设为 600、归 `yearly` 所有。应用源码与 venv 为只读运行，API 不落地媒体；视频预览工作进程需要临时目录空间（至少容纳当前原件与压缩副本），处理后自动清理。

```bash
cd /opt/yearly
python3.12 -m venv .venv
.venv/bin/pip install -r backend/requirements.txt
cp .env.production.example .env.production
chmod 600 .env.production
# 使用 secrets.token_urlsafe(48) 生成 SESSION_SECRET，填入 .env.production，妥善保管。
```

`.env.production` 必须使用 `APP_ENV=production`、`COOKIE_SECURE=true`，`ALLOWED_ORIGIN` 精确匹配页面 HTTPS origin，不带末尾 `/`。本地测试环境使用 APP_ENV=test 和独立 .env.test 关闭 Secure Cookie。应用在生产启动时验证该约束。数据库密码中的特殊字符需 URL 编码，禁止将 .env.production 提交到版本控制。

## 2. 已有 MySQL 实例创建应用库

由数据库管理员在新实例首次初始化时执行。已完成初始化的部署可以跳过此步骤。两套密码应独立生成。

```sql
CREATE DATABASE yearly CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE yearly_test CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'yearly_app'@'%' IDENTIFIED BY 'REPLACE_WITH_RANDOM_PRODUCTION_PASSWORD' REQUIRE SSL;
CREATE USER 'yearly_test_app'@'%' IDENTIFIED BY 'REPLACE_WITH_RANDOM_TEST_PASSWORD' REQUIRE SSL;
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES
  ON `yearly`.* TO 'yearly_app'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES
  ON `yearly\_test`.* TO 'yearly_test_app'@'%';
```

当前账号支持本地开发机远程连接，并要求 TLS。权限限定各自的库，数据库名中的下划线在授权中已转义。DATABASE_URL 中填写对应账号和可信 CA 路径。若部署位置固定，可按实际来源进一步限定账号 Host。建表迁移所需 CREATE / ALTER / INDEX / DROP / REFERENCES 权限已经包括在各自库的授权内。

```bash
export APP_ENV=production
export PYTHONPATH="$PWD/backend"
# 本命令读取 .env.production 中的正式数据库账号。
.venv/bin/alembic -c backend/alembic.ini upgrade head
.venv/bin/python -m app.cli create-admin your-admin-name
```

也可手动导入 `deploy/schema-mysql57.sql`，之后执行 `alembic -c backend/alembic.ini stamp 0013`。然后运行 `./scripts/manage.sh production migrate` 同步后续迁移。两个入口任选其一。已有库执行该迁移命令后再启动新版后端。账户与日志迁移为 `0013`，历史文件夹和档案缺少创建人时由管理员管理，修改日志从升级后开始记录。所有表为 InnoDB / utf8mb4，ID 使用 BIGINT，时间为 DATETIME(3)，坐标为 DECIMAL，原始元数据为 JSON。模型没有 MySQL 8 专属 SQL。

## 3. 配置私有 OSS

按 [存储与元数据说明](storage-and-metadata.md) 创建或选择私有 Bucket，配置 V4 所需地域、CORS、RAM 权限及 HTTPS 域名。生产配置使用独立 RAM 用户密钥，禁止使用主账号密钥。只将密钥放在服务器 `.env.production`。

### 原件深度冷归档与独立预览

执行数据库迁移 `0015`，安装更新后的 `backend/requirements.txt`，并启动现有 `generate-previews --watch` 服务。任务同时保存照片的 480px / 1600px WebP、视频 MP4 与 WebP 封面。旧文件自动补齐，失败任务可通过 `generate-previews --retry-failed` 重新生成。OSS 拒绝处理超大图片时，后台从已校验原件本地生成 WebP，HEIC 由 pillow-heif 解码。

在对应环境配置 `OSS_ARCHIVE_ORIGINALS=true`，并执行 `scripts/manage.sh test configure-archive`（正式环境将 test 改为 production）。命令保留既有生命周期规则，添加 `originals/` 且带 `yearly-preview=ready-v1` 标签的深度冷归档规则，上传满 1 天后转换。后台在独立预览完整就绪后标记每份原件，头像和 `previews/` 继续标准存储。同地域 ECS 后台可配置 `OSS_INTERNAL_ENDPOINT`，API 为浏览器签发地址继续使用公网 Endpoint / 自定义域名。

新增权限见 `deploy/oss-ram-policy.json`。原件深度冷归档采用本地冗余，最短保留期 180 天。查看原件接口返回 archived / restoring 状态，登录用户可通过 POST `/api/media/{mid}/files/{fid}/restore` 申请 Bulk 解冻，通常 48 小时，完成后提供 1 天下载窗口。Web 展示解冻申请与状态，iOS 保存到相册时为 Live Photo 的两份原件一起申请解冻。公开分享继续读取独立预览。

`backup` 会为缺少本地备份的归档原件申请解冻，保留本次已下载文件并提示解冻后重试。清单恢复会清除旧 Bucket 的归档就绪标记，由目标环境重新生成预览并标记。

## 4. 构建静态前端

账户昵称需要迁移 `0016`：先运行对应环境的 `migrate`，再更新后端和客户端。昵称为可选的 80 字符字段，旧账号默认为空，展示时回退到登录用户名；仅修改昵称不会撤销会话或分享。旧客户端未提交昵称时保留原昵称，显式传空字符串可清除。已有修改日志按操作账号当前的昵称/用户名展示，日志中的原始操作人快照仍保留。

```bash
cd frontend
npm ci
npm test
npm run build
cd ..
```

前端固定使用同源 `/api`，无需向前端注入数据库密码或 OSS 永久密钥。更新应用时先构建到临时发布目录，再原子切换版本目录，避免用户加载到半份 dist。

## 5. 启动 systemd

```bash
sudo cp deploy/yearly.service deploy/yearly-previews.service /etc/systemd/system/
sudo cp deploy/yearly-cleanup.service deploy/yearly-cleanup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now yearly.service yearly-previews.service yearly-cleanup.timer
sudo systemctl status yearly.service
```

单 worker 默认避免在小内存机器重复常驻 Python 进程，所有阻塞 SDK 与 SQL 调用由 FastAPI 同步路由线程池处理。任务状态与登录限制持久化在 MySQL，重启不会丢失已签发任务。按实际 CPU / 内存测量后再调整 worker。

服务仅监听 127.0.0.1。`--forwarded-allow-ips=127.0.0.1` 只信任本机 Nginx 的代理头。禁止将 8000 端口直接暴露公网。

`yearly-previews.service` 必须一起启用，否则新视频会保持「预览正在准备」。它每 15 秒发现已完成上传的历史或新视频，串行转码并按 SHA-256 复用副本。`imageio-ffmpeg` 提供独立 FFmpeg 可执行文件；无对应平台 wheel 时可安装系统 FFmpeg，并通过 `IMAGEIO_FFMPEG_EXE=/绝对路径/ffmpeg` 指定。需包含 libx264、AAC、zscale、tonemap。转码使用两个编码线程，部署前确认临时空间和 CPU 配额。

```bash
# 一次性处理历史记录（与常驻进程二选一，同库只允许一个生成进程）
./scripts/manage.sh production generate-previews
# 重试失败任务前先停常驻进程
sudo systemctl stop yearly-previews.service
./scripts/manage.sh production generate-previews --retry-failed
sudo systemctl start yearly-previews.service
journalctl -u yearly-previews.service
```

## 6. 现有 Nginx 配置

把 `deploy/nginx.conf` 合并到已有 Nginx 的 `http {}` 范围，替换站点域名、证书、静态根路径与 CSP 中的 OSS / 自定义域名。`log_format` 和 `limit_req_zone` 属于 http 级别，不要放入 server 块。此文件供已有 Nginx 使用。

```bash
sudo nginx -t
sudo systemctl reload nginx
curl --fail https://yearly.example.com/api/health
```

证书可通过现有 ACME 流程签发和续期。启用 HTTPS 后再开放家庭账户。CSP 允许 hash-wasm 的 WebAssembly 和 Element Plus 的 inline style，不允许第三方分析脚本。分片 PUT 请求直接发送到 OSS，Nginx 的 2 MiB 请求上限仅覆盖元数据 API。

### 在已有 HTTPS 域名的子路径部署

例如部署到 `https://example.com/yearly/` 时，后端设置 `APP_BASE_PATH=/yearly`、`ALLOWED_ORIGIN=https://example.com`、`COOKIE_SECURE=true`。Origin 只包含协议、域名和可选端口。Cookie 作用路径会设置为 `/yearly/`。

在 `frontend/` 执行 `npm run build -- --base /yearly/`，将 dist 放在 `/opt/yearly/www/yearly/`。在主域名的 HTTPS server 块 include [子路径配置](../deploy/nginx-yearly-subpath.conf)，设置实际静态目录、上游端口和 OSS 域名，并按主配置定义 `yearly_auth` 限速区。代理把 `/yearly/api/` 转为后端 `/api/`。验证 `https://example.com/yearly/api/health`，并将 `https://example.com` 加入私有 OSS 的 CORS 精确来源以支持网页直传。

iPhone 的站点地址填完整 `https://example.com/yearly/`。同域的不同路径共享浏览器的同源权限，应只与受信任的站点内容共用域名。

## 7. 发布检查

1. 浏览器登录，确认 Cookie 有 HttpOnly、Secure、SameSite=Strict。
2. 新增两个不同生日的孩子，上传一份共同照片。网络面板应显示 PUT 目标为 OSS 域名，API 不出现文件二进制。
3. 核对两个孩子时间线及全部时间线数量，下载原件比较 SHA-256。
4. 测试大视频分片中断，刷新后重新选择同一原件恢复，旧分片应跳过。
5. HEIC / MOV 的本机兼容性、Live Photo 双文件、GPS 和拍摄时间需用实际设备原件复核。
6. 按备份文档执行一次恢复演练。

## 运维

- `journalctl -u yearly.service` 查看不含访问参数的服务日志。应用隐藏 SQL 参数，OSS SDK 日志级别为 WARNING，错误接口不返回 OSS SDK 原始签名 URL。
- `yearly-cleanup.timer` 每日清理过期授权、未完成分片及认证记录。原始对象始终保留。OSS 生命周期另设“清理未完成分片”，不要给 originals 配置自动过期。
- 备份任务与恢复在维护窗口运行，停写后创建完整快照。系统导出包含家庭隐私，备份目录设为 700，文件 600，加密异地保存。
- 修改 SESSION_SECRET 会使所有已登录会话失效。密码修改会注销该账户所有会话。
- 首次真实部署前执行 `scripts/test.sh`，确认 Nginx / MySQL / OSS 参数符合本机环境。仓库提供部署能力，本地开发验证不代表线上发布。
