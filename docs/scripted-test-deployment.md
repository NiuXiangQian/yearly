# 用脚本部署测试环境

**简体中文** | [English](en/scripted-test-deployment.md) · [返回首页](../README.md)

本流程在本地构建前端，再将发布包上传到已有 Linux 服务器，用独立 Docker 容器运行 API 与视频预览。使用已有 Nginx、MySQL 和私有 OSS，只读取服务器测试配置，数据库名必须以 `_test` 结尾。

## 首次准备服务器

服务器需要 Docker、Nginx、Bash、Python 3 和 curl。创建以下路径：

- `/opt/yearly-test/config/.env.test`：参考 `.env.test.example`，设置 `APP_ENV=test`、测试数据库账号和 OSS 配置。HTTP 测试站设置 `COOKIE_SECURE=false`、`ALLOWED_ORIGIN=http://yearly.example.com`。
- `/opt/yearly-test/config/mysql-ca.pem`：MySQL 的可信 CA；`DATABASE_URL` 中设置 `ssl_ca=/app/certs/mysql-ca.pem`。同机数据库地址可用 `127.0.0.1`。
- 测试配置文件归 UID/GID `10001:10001` 所有、权限 `600`，配置目录权限 `700`。Docker 按文件只读挂载配置，密钥不进入镜像或发布包。
- 默认 Python 镜像为 `python:3.12-slim-bookworm`；如果需要镜像代理，将完整镜像引用（建议包含 digest）写入 `/opt/yearly-test/config/python-image`。

把 `deploy/nginx-test.conf` 中的 `YEARLY_HOST` 替换为测试域名，`YEARLY_OSS_ORIGINS` 替换为 OSS HTTPS Bucket 域名与已绑定的自定义域名。作为独立配置引入现有 Nginx 的 `http {}` 块，执行 `nginx -t` 后再 reload。API 只监听 `127.0.0.1:18080`，页面由 Nginx 提供。

## 构建并部署

本地需要 Node.js 22.12+、Git 和 SSH。先提交需要发布的代码，保持构建源码与提交编号一致，再运行：

```bash
./scripts/deploy-remote-test.sh your-user@your-server 22
```

该脚本依次执行依赖安装、全部前端测试、类型检查与生产构建；仅打包明确列出的后端、前端产物和部署文件。环境配置、凭据、照片及本地文件不会进入包。SSH 使用已有密钥或交互式密码，不把登录密码写入脚本。

也可分开执行：

```bash
./scripts/build-release.sh
scp yearly-test.tgz your-user@your-server:/opt/yearly-test/incoming/
# 在服务器解压到新的 /opt/yearly-test/releases/<版本目录> 后：
bash /opt/yearly-test/releases/<版本目录>/deploy/deploy-test.sh
```

部署脚本构建 Python 镜像，停止已有 `yearly-test-api` / `yearly-test-previews`，升级测试库，启动 API 并等待数据库健康检查通过，再启动预览进程、切换 `current` 静态目录。容器配置重启策略及内存、CPU、日志上限。部署期间会短暂停止测试服务；迁移或健康检查失败时脚本返回非零，查看容器日志后处理。

```bash
curl --fail http://yearly.example.com/api/health
docker ps --filter name=yearly-test
docker logs --tail 50 yearly-test-api
docker logs --tail 50 yearly-test-previews
```

健康检查应返回 `environment: test`。登录使用测试库中已有的账号；首次空库可参考部署文档在容器中交互执行 `python -m app.cli create-admin`。后台清理可通过当前 API 容器执行 `docker exec yearly-test-api python -m app.cli cleanup` 并按需设置定时任务。

## 本地与服务器共用测试库

同一数据库只允许一个视频预览进程。服务器预览进程启用后，本地启动时跳过该进程：

```bash
YEARLY_LOCAL_PREVIEWS=false ./scripts/start-local.sh
```

这仍会启动本地 API 和前端，视频预览由服务器统一生成。
