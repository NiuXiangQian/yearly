import argparse
import getpass
import json
from datetime import timedelta
from pathlib import Path
from sqlalchemy import select, delete
from .db import SessionLocal, now
from .models import User, UploadTask, MediaFile, Media, UserSession, LoginGuard, Captcha
from .security import passwords
from .storage import get_storage, verify_object, OSSStorage
from .backup import backup_objects, restore_manifest


def main():
    parser = argparse.ArgumentParser(description="yearly管理工具")
    sub = parser.add_subparsers(dest="command", required=True)
    user = sub.add_parser("create-admin")
    user.add_argument("username")
    sub.add_parser("cleanup")
    sub.add_parser("verify-oss")
    sub.add_parser("configure-archive")
    previews = sub.add_parser("generate-previews")
    previews.add_argument("--watch", action="store_true")
    previews.add_argument("--retry-failed", action="store_true")
    search = sub.add_parser("build-search-index")
    search.add_argument("--watch", action="store_true")
    search.add_argument("--retry-failed", action="store_true")
    search.add_argument("--limit", type=int, default=100)
    backup = sub.add_parser("backup")
    backup.add_argument("directory")
    restore = sub.add_parser("restore")
    restore.add_argument("manifest")
    restore.add_argument("--owner-id", required=True, type=int)
    restore.add_argument("--objects")
    args = parser.parse_args()
    if args.command == "build-search-index":
        import logging
        from .ai_search import build_index
        if args.limit < 1:
            parser.error("--limit 必须大于 0")
        logging.basicConfig(level=logging.INFO)
        logging.getLogger("oss2").setLevel(logging.WARNING)
        print("已处理索引:", build_index(OSSStorage(internal=True), args.limit, args.watch, args.retry_failed))
    elif args.command == "generate-previews":
        import logging
        import signal
        from .previews import generate_previews

        logging.basicConfig(level=logging.INFO)
        logging.getLogger("oss2").setLevel(logging.WARNING)

        def stop_worker(signum, frame):
            raise KeyboardInterrupt

        signal.signal(signal.SIGTERM, stop_worker)
        try:
            generate_previews(OSSStorage(internal=True), args.watch, args.retry_failed)
        except KeyboardInterrupt:
            pass
    elif args.command == "configure-archive":
        get_storage().configure_archive()
        print("已配置深度冷归档生命周期，仅匹配预览就绪标记的 originals/ 对象，上传满1天后转换")
    elif args.command == "create-admin":
        password = getpass.getpass("新管理员密码（至少12位）: ")
        if len(password) < 12 or password != getpass.getpass("再次输入密码: "):
            parser.error("密码长度不足或两次输入不同")
        with SessionLocal() as db:
            if db.scalar(select(User.id).where(User.username == args.username)):
                parser.error("账户已存在")
            db.add(
                User(
                    username=args.username,
                    password_hash=passwords.hash(password),
                    role="admin",
                )
            )
            db.commit()
        print("管理员已创建")
    elif args.command == "backup":
        count = backup_objects(args.directory, get_storage())
        print(f"已核验并备份 {count} 份原件")
    elif args.command == "restore":
        restore_manifest(
            args.manifest,
            args.owner_id,
            get_storage() if args.objects else None,
            args.objects,
        )
        print("清单及关联恢复完成，请运行 verify-oss 验证原件")
    elif args.command == "verify-oss":
        storage = get_storage()
        count = 0
        with SessionLocal() as db:
            for file in db.scalars(
                select(MediaFile)
                .where(MediaFile.upload_status == "complete")
                .execution_options(yield_per=100)
            ):
                verify_object(file, storage.head(file))
                count += 1
        print(
            f"已验证 {count} 个对象的大小、CRC64 和 SHA-256 元数据。字节 SHA-256 审计请运行 backup。"
        )
    elif args.command == "cleanup":
        with SessionLocal() as db:
            tasks = db.scalars(
                select(UploadTask).where(
                    UploadTask.status.in_(["pending", "uploading"]),
                    UploadTask.expires_at < now(),
                )
            ).all()
            storage = get_storage() if tasks else None
            for task in tasks:
                file = db.get(MediaFile, task.file_id)
                if task.oss_upload_id:
                    import oss2

                    try:
                        storage.abort(file, task.oss_upload_id)
                    except oss2.exceptions.NoSuchUpload:
                        pass
                task.status = "expired"
                file.upload_status = "expired"
                # Completed original objects remain recoverable and are never deleted by cleanup.
                db.get(Media, task.media_id).status = "uploading"
            db.execute(delete(UserSession).where(UserSession.expires_at < now()))
            db.execute(delete(Captcha).where(Captcha.expires_at < now()))
            db.execute(delete(LoginGuard).where(LoginGuard.reset_at < now()))
            db.commit()
        print(f"已清理 {len(tasks)} 个过期任务及过期认证记录")


if __name__ == "__main__":
    main()
