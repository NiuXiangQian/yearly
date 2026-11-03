"""Portable manifests and bounded-memory original-object backup/restore."""

import csv
import hashlib
import io
import json
import ijson
from datetime import datetime, date, time
from decimal import Decimal
from pathlib import Path
from sqlalchemy import select, delete
from .db import SessionLocal, Base
from .models import (
    User,
    Child,
    Media,
    MediaFile,
    MediaMetadata,
    MediaChild,
    Event,
    EventMedia,
    EventChild,
)

# Upload authorizations, sessions, captcha and password hashes never enter portable exports.
TABLES = [
    Child,
    Media,
    MediaFile,
    MediaMetadata,
    MediaChild,
    Event,
    EventMedia,
    EventChild,
]


def encode(value):
    if isinstance(value, (datetime, date, time)):
        return value.isoformat()
    if isinstance(value, Decimal):
        return str(value)
    raise TypeError(type(value).__name__)


def manifest_stream():
    with SessionLocal() as db:
        # A consistent read transaction keeps all relationship tables from the same snapshot.
        yield '{"format":"yearly","version":1,"tables":{'
        for i, model in enumerate(TABLES):
            yield ("," if i else "") + json.dumps(model.__tablename__) + ":["
            first = True
            rows = db.execute(select(model.__table__).execution_options(yield_per=10))
            for row in rows.mappings():
                yield ("" if first else ",") + json.dumps(
                    dict(row), default=encode, ensure_ascii=False
                )
                first = False
            yield "]"
        yield "}}"


def csv_stream():
    output = io.StringIO()
    writer = csv.writer(output)
    writer.writerow(
        [
            "file_id",
            "media_id",
            "role",
            "bucket",
            "object_key",
            "filename",
            "bytes",
            "sha256",
            "crc64",
        ]
    )
    yield "\ufeff" + output.getvalue()
    with SessionLocal() as db:
        for row in db.scalars(select(MediaFile).execution_options(yield_per=100)):
            output.seek(0)
            output.truncate()
            # Excel-safe user-provided names.
            name = row.original_filename
            if name.startswith(("=", "+", "-", "@")):
                name = "'" + name
            writer.writerow(
                [
                    row.id,
                    row.media_id,
                    row.file_role,
                    row.oss_bucket,
                    row.oss_object_key,
                    name,
                    row.file_size,
                    row.sha256,
                    row.crc64,
                ]
            )
            yield output.getvalue()


def hash_file(path):
    sha = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(4 * 1024 * 1024), b""):
            sha.update(block)
    return sha.hexdigest()


def backup_objects(directory, storage):
    from .storage import verify_object

    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / "manifest.json").open("w") as output:
        for chunk in manifest_stream():
            output.write(chunk)
    (directory / "objects").mkdir(exist_ok=True)
    count = 0
    with SessionLocal() as db:
        for file in db.scalars(
            select(MediaFile)
            .where(MediaFile.upload_status == "complete")
            .execution_options(yield_per=100)
        ):
            verify_object(file, storage.head(file))
            target = directory / "objects" / str(file.id)
            if not target.exists() or hash_file(target) != file.sha256:
                temporary = target.with_suffix(".partial")
                storage.bucket.get_object_to_file(file.oss_object_key, str(temporary))
                if (
                    temporary.stat().st_size != file.file_size
                    or hash_file(temporary) != file.sha256
                ):
                    raise ValueError(f"原件校验失败 file_id={file.id}")
                temporary.replace(target)
            count += 1
    return count


def restore_manifest(path, owner_id, storage=None, object_directory=None):
    # Administrative, offline import into an empty content database, stable IDs preserved.
    path = Path(path)

    def rows(table):
        with path.open("rb") as source:
            yield from ijson.items(source, f"tables.{table}.item", use_float=True)

    with path.open("rb") as source:
        header = next(ijson.items(source, "format"), None)
    with path.open("rb") as source:
        version = next(ijson.items(source, "version"), None)
    # Import historical archives created before the yearly rename.
    if header not in ("yearly", "family-timeline") or version != 1:
        raise ValueError("不支持的清单格式")
    with path.open("rb") as source:
        names = {
            value
            for prefix, event, value in ijson.parse(source)
            if prefix == "tables" and event == "map_key"
        }
    if names != {m.__tablename__ for m in TABLES}:
        raise ValueError("清单表不完整")
    from sqlalchemy import Date, DateTime, Time

    with SessionLocal() as db:
        if not db.get(User, owner_id):
            raise ValueError("恢复目标账户不存在")
        if any(
            db.scalar(
                select(
                    m.id
                    if hasattr(m, "id")
                    else next(iter(m.__table__.primary_key.columns))
                ).limit(1)
            )
            for m in TABLES
        ):
            raise ValueError("请使用已迁移且无内容的新数据库恢复")
        # Upload verified objects first. A failed DB restore can retry without overwriting originals.
        if storage and object_directory:
            for row in rows("media_file"):
                if row["upload_status"] != "complete":
                    continue
                source = Path(object_directory) / str(int(row["id"]))
                if (
                    not source.is_file()
                    or source.stat().st_size != row["file_size"]
                    or hash_file(source) != row["sha256"]
                ):
                    raise ValueError(
                        f"备份原件缺失或 SHA-256 不一致 file_id={row['id']}"
                    )
                file = MediaFile(**row)
                file.oss_bucket = storage.bucket.bucket_name
                import oss2

                try:
                    from .storage import verify_object

                    verify_object(file, storage.head(file))
                except oss2.exceptions.NoSuchKey:
                    with source.open("rb") as stream:
                        oss2.resumable_upload(
                            storage.bucket,
                            file.oss_object_key,
                            stream.name,
                            headers={
                                "x-oss-forbid-overwrite": "true",
                                "Content-Type": file.mime_type,
                                "x-oss-meta-sha256": file.sha256,
                                "x-oss-meta-client-crc64": file.crc64,
                            },
                            multipart_threshold=16 * 1024**2,
                            part_size=16 * 1024**2,
                            num_threads=1,
                        )
                    verify_object(file, storage.head(file))
        avatars = []
        for model in TABLES:
            for original in rows(model.__tablename__):
                row = dict(original)
                if model is MediaFile and storage and object_directory:
                    row["oss_bucket"] = storage.bucket.bucket_name
                if model is Media:
                    row["owner_id"] = owner_id
                if model is Event:
                    row["created_by"] = owner_id
                if model is Child and row.get("avatar_media_id"):
                    avatars.append((row["id"], row["avatar_media_id"]))
                    row["avatar_media_id"] = None
                for column in model.__table__.columns:
                    value = row.get(column.name)
                    if value is not None and isinstance(value, str):
                        if isinstance(column.type, DateTime):
                            row[column.name] = datetime.fromisoformat(value)
                        elif isinstance(column.type, Date):
                            row[column.name] = date.fromisoformat(value)
                        elif isinstance(column.type, Time):
                            row[column.name] = time.fromisoformat(value)
                db.execute(model.__table__.insert().values(**row))
        for cid, mid in avatars:
            db.get(Child, cid).avatar_media_id = mid
        db.commit()
