# 可恢复备份与长期迁移

**简体中文** | [English](en/backup-restore.md) · [返回首页](../README.md)

## 备份内容

完整备份包含 MySQL 全库 dump、便携 manifest.json、原始 OSS 对象的逐文件副本及 SHA-256 / CRC64 清单。JSON / CSV 下载只是清单，完整原件需通过 CLI 备份。完整 MySQL dump 含账户密码哈希及会话，便携清单主动排除 sys_user、user_session、captcha、login_guard、upload_task。

yearly 清单保留孩子、媒体、物理文件、元数据、media_child、事件、event_media 顺序和 event_child 的稳定 ID。重命名昵称、头像不会改变关联。

## 备份操作

使用与 MySQL 5.7 兼容的 mysqldump / mysql 客户端。先进入维护窗口，暂停创建或修改内容，等待上传任务结束。已有 Nginx 可临时只允许维护管理员访问。快照生成和下载原件期间不要修改数据库或进行 OSS 物理维护，保证一致性。

备份介质目录权限 700，以下 MySQL 客户端配置权限必须 600，用户名密码填写实际备份账户。密码不放命令行参数、不提交 Git。

```ini
[client]
host=127.0.0.1
user=yearly_backup
password=REPLACE_WITH_BACKUP_PASSWORD
```

```bash
cd /opt/yearly
umask 077
mkdir -p /secure-backups/yearly-20261103
./deploy/backup-mysql.sh /secure/mysql-client.cnf yearly \
  /secure-backups/yearly-20261103/mysql.sql.gz
export APP_ENV=production
export PYTHONPATH="$PWD/backend"
.venv/bin/python -m app.cli backup /secure-backups/yearly-20261103
```

CLI 输出 manifest.json 与 objects/<media_file.id>，逐份 HEAD 校验、下载原件、用 4 MiB 读取计算 SHA-256。下载使用临时 .partial 文件，校验后原子更名，重复执行跳过已正确备份的原件。所有 complete 文件都备份，包括软删除媒体的原件。文件名保存在清单中，磁盘副本使用 ID，避免重名与路径注入。

必须等命令成功退出后才将此目录标记为完成。中途失败的备份不可作为唯一恢复来源。将整目录复制到异地加密存储，保留多个历史版本，定期抽查 SHA-256。

`verify-oss` 比较对象大小、CRC64 和声明 SHA-256 元数据，完整字节 SHA-256 校验由 `backup` 完成。前者速度快，后者会产生 OSS 下行流量。

## 路径一，完整 MySQL 恢复

准备独立空库与原 Bucket 或其完整恢复副本。不要向已有内容库直接覆盖导入。

```bash
./deploy/restore-mysql.sh /secure/mysql-client.cnf yearly_restored \
  /secure-backups/yearly-20261103/mysql.sql.gz
```

随后 `.env.production` 指向恢复库。MySQL dump 保留 Alembic 版本，不再重复执行初始建表。建议销毁已恢复的 user_session 记录或轮换 SESSION_SECRET，避免恢复旧会话。OSS Bucket / key 必须与数据库对应。若迁移到新 Bucket，使用便携恢复路径将 key 和校验关系统一重建。

## 路径二，便携 JSON 与原件恢复

1. 新库执行 Alembic migration。
2. `create-admin` 建立目标管理员，记录其 user ID（新空库通常是 1）。
3. `.env.production` 配置目标私有 Bucket 与域名。
4. 使用离线副本恢复。

```bash
export APP_ENV=production
export PYTHONPATH="$PWD/backend"
.venv/bin/python -m app.cli restore /secure-backups/yearly-20261103/manifest.json \
  --owner-id 1 --objects /secure-backups/yearly-20261103/objects
.venv/bin/python -m app.cli verify-oss
```

恢复命令分段读取 JSON，保持低内存，预检 objects 文件大小与 SHA-256，采用单线程 OSS resumable_upload 恢复大文件。上传设置禁止覆盖，已存在对象必须通过校验。所有对象核验成功后，在单个数据库事务内按依赖顺序恢复表，暂缓孩子头像 FK，最后补齐。目标内容库必须为空。上传中断可重跑，数据库事务失败可在排查后重跑，不覆盖已有原件。

`--objects` 省略时，仅恢复清单，适用于继续使用相同原 Bucket 的场景。此时必须保留原 Bucket / Key，恢复后马上执行 verify-oss。迁移目标 Bucket 不同必须带 --objects，否则数据库文件指向与实际存储可能不一致。

已完成文件的 owner / created_by 映射到指定管理员，媒体、孩子、文件和日记的稳定 ID 不变。便携清单不恢复密码、会话和上传授权，家庭成员需重新创建。

## 恢复验收

- 对比孩子、媒体、事件、物理文件数量与便携清单。
- 核对一张共同照片在两个孩子中出现，全部时间线只出现一次。
- 核对共同日记的孩子关联、显式媒体顺序和封面。
- 修改测试孩子生日，确认年龄由拍摄日期即时计算，随后恢复生日。
- HEIC / MOV 分别下载并重算 SHA-256，抽查照片 EXIF 和视频时长。
- 原件验证通过后再恢复家庭正常访问。至少每季度进行一次独立恢复演练。

回收站提供逻辑媒体 / 日记恢复。孩子删除默认解除关联，历史备份保留删除前的关系。应用没有物理永久删除入口，物理清理需由家庭管理员在独立维护流程中处理，并先验证备份。

便携清单仅接受当前 `format: yearly`、`version: 1`，且表集合与各表字段必须与当前模型完全一致。旧名称、缺表或缺字段的清单会在写入数据库和上传对象前被拒绝，不再自动补齐历史格式。请使用与导出时相同版本的恢复工具。
