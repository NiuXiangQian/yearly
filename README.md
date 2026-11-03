# yearly

私人家庭成长影像档案。Python 3.12 / FastAPI / SQLAlchemy 2 / MySQL 5.7，Vue 3 / TypeScript / Pinia / Vue Router / Element Plus。已有 Nginx 托管前端并代理 API，systemd 运行后端，原件通过浏览器直接上传私有阿里云 OSS。

## 已实现

- 家庭 Cookie Session、图形验证码、Argon2id、CSRF、登录限制、管理员 / 成员 / 只读访客权限，关闭公开注册。
- 多孩子档案、头像引用、归档、显示顺序和二次确认删除。解除关联后保留家庭原件。
- 独立逻辑媒体与物理文件，多孩子共享照片和共同成长日记，EXISTS 筛选去重，时间线游标分页。
- 拍摄当地日期动态日历年龄、出生前 / 未知时间标签、满月 / 百天 / 生日导航、自定义月龄阶段。
- 浏览器 EXIF / GPS / 设备参数解析、分段 QuickTime 元数据读取、4 MiB 增量 SHA-256 / CRC64，上传前确认及手动修正。
- OSS V4 分片签名直传、分片重试、重新选择原件恢复任务、服务端大小 / CRC64 / 声明 SHA-256 元数据核验。原件不经 API / Nginx。
- Live Photo 可靠标识配对及手动 HEIC/JPEG + MOV 双文件导入，一条逻辑媒体，分别下载原件。可独立导入兼容预览。
- 瀑布流、私有媒体详情、原始元数据、修正时间、GPS、备注、标签、批量孩子关联、回收站。
- Shift 连选、PC 框选模式、移动端长按多选。日记明确保存媒体顺序、封面、孩子和起止时间，支持纯文字。
- JSON / CSV 清单、MySQL 备份恢复、低内存 OSS 原件备份与 SHA-256 校验、稳定 ID 及关系恢复。
- 浅深主题、响应式布局、无第三方照片分析 / 字体请求。

## 正式与测试环境

通过 `APP_ENV=test|production` 选择环境，默认 `test`。配置文件按项目根目录定位，命令行环境变量优先。应用、迁移、管理命令与自动化测试统一使用 MySQL。

- 测试配置为 `.env.test`，数据库为 `yearly_test`，使用独立测试账号。允许本机 HTTP，Cookie Secure 为 false，开放 `/api/docs`，页面标识“测试环境”。
- 正式配置为 `.env.production`，数据库为 `yearly`，使用独立正式账号。要求 HTTPS / Secure Cookie，页面标识“正式环境”。
- 两套账号仅授权各自的数据库，Session 密钥和 OSS 配置分别管理。测试数据库名强制以 `_test` 结尾，正式配置拒绝指向 `_test` 库。
- 运行时读取所选环境文件。`.env.example` 提供入口说明，`.env.test.example` 与 `.env.production.example` 提供完整模板。真实配置和密码文件均被 Git 忽略。

## 本地启动测试环境

Python 3.12 和 Node.js 22.12+，已有 MySQL 5.7.8+。本仓库提供 `.nvmrc`，安装 nvm 的终端可先运行 `nvm use`。

```bash
python3.12 -m venv .venv
.venv/bin/pip install -r backend/requirements.txt
# 首次配置时复制模板。已有 .env.test 时保留现有连接与密码。
cp -n .env.test.example .env.test
chmod 600 .env.test
# 填写测试 MySQL 连接、随机 SESSION_SECRET 和测试 OSS 配置
(cd frontend && npm ci)
./scripts/manage.sh test migrate
# 首次使用且尚无管理员时执行
./scripts/manage.sh test create-admin your-admin-name
./scripts/start-local.sh
```

`start-local.sh` 先迁移测试库，再同时启动 FastAPI 热更新与 Vite，按 Ctrl+C 结束两者。访问 <http://127.0.0.1:5173/>，健康检查为 `/api/health`，返回当前 environment。

也可分开启动，后端使用 `./scripts/start-api.sh test --reload`，前端使用 `cd frontend && npm run dev -- --port 5173`。

## 正式环境运行

```bash
cp -n .env.production.example .env.production
chmod 600 .env.production
# 填写正式 MySQL、独立 Session 密钥、正式 HTTPS origin 和私有 OSS
./scripts/manage.sh production migrate
./scripts/manage.sh production create-admin your-admin-name
(cd frontend && npm ci && npm run build)
./scripts/start-api.sh production
```

长期运行使用已有 Nginx 与提供的 systemd 服务。systemd 显式设置 `APP_ENV=production` 并读取 `.env.production`。前端构建复用同源 `/api`，环境标识由后端返回。

远程 MySQL 使用 TLS 时，在 DATABASE_URL 中配置 `ssl_ca`。相对证书路径按项目根目录解析。当前服务器账号已要求 TLS，部署时同步受限配置中引用的 CA 证书。

## 自动化测试

```bash
./scripts/test.sh
```

后端连接 `.env.test` 的真实 MySQL 测试库，OSS 使用 Mock 并保留真实 V4 签名测试。每项数据库用例使用外层事务和 SAVEPOINT 隔离，API 内部提交在用例结束后整体回滚，恢复测试库既有记录，自增序列会继续向前推进。执行自动化测试前先停止本地测试服务，避免同时写测试库。

前端测试覆盖 EXIF/GPS 固件、分块 SHA-256 / CRC64、分片重试与选择交互。验证结果见 [测试说明](docs/verification.md)。

## 文档与部署入口

- [部署指南](docs/deployment.md)
- [OSS 配置、可靠性与原件边界](docs/storage-and-metadata.md)
- [备份、恢复与迁移](docs/backup-restore.md)
- [验收与已知限制](docs/verification.md)
- [MySQL 5.7 建表脚本](deploy/schema-mysql57.sql)
- [Nginx 配置](deploy/nginx.conf)
- [systemd 服务](deploy/yearly.service)

新库推荐 Alembic。手工建表脚本是替代入口，使用它后执行 `alembic ... stamp 0002`，不要重复建表。

## 数据与运行约定

一个部署实例代表一个家庭，所有启用账户共享家庭内容。管理员管理账户、删除孩子、导出数据。成员编辑孩子、媒体与日记。访客只读。上传任务仅创建者可签名或恢复。

原始元数据与修正字段独立保存，年龄实时计算。无时区的当地时间不自动转 UTC。默认使用设备提供的文件修改时间作为低可信度备用，页面清楚标注，用户可在详情中明确标记时间未知或手动修正。真实日历运算使用月末截断规则，2 月 29 日的非闰年周年为 2 月 28 日。百天节点定义为出生日期加 100 天，出生当天为第 0 天。

每份物理原件使用 UUID key。多孩子关联和解除关联只改变数据库关系。重复选择同一批文件会按 SHA-256 去重，独立的再次导入可以创建新的记录。删除媒体、日记和孩子均为软删除，系统没有自动永久删除原件的操作。

生产上限默认单文件 50 GiB、分片 16 MiB、逐文件顺序上传。API JSON 不超过 2 MiB，原始元数据不超过 1 MiB。后端一个 worker 即可运行，无 Redis 或任务队列。元数据与哈希耗时取决于文件大小，恢复上传需要重新选择本机原件。
