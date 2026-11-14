import json
import re
import pytest
from pathlib import Path
from sqlalchemy import delete, select
from sqlalchemy.dialects import mysql
from sqlalchemy.schema import CreateTable
from app.db import Base
from app.models import (
    Child,
    Media,
    MediaChild,
    Event,
    EventChild,
    EventMedia,
    MediaFile,
    MediaMetadata,
    UploadTask,
)
from app.backup import TABLES, restore_manifest
from conftest import child, upload


@pytest.mark.parametrize("archive_format", ["yearly", "family-timeline"])
def test_export_restore_stable_ids_and_relationships(context, archive_format):
    a, b = child(context), child(context, "妹妹", "2023-01-01")
    mid = upload(context, [a["id"], b["id"]])["media_id"]
    eid = context.client.post(
        "/api/events",
        json={"title": "共同事件", "child_ids": [a["id"], b["id"]], "media_ids": [mid]},
    ).json()["id"]
    response = context.client.get("/api/export/manifest")
    assert response.status_code == 200
    document = response.json()
    assert document["format"] == "yearly"
    document["format"] = archive_format
    assert (
        "sys_user" not in document["tables"]
        and "user_session" not in document["tables"]
    )
    csv = context.client.get("/api/export/files.csv")
    assert "sha256" in csv.text
    target = context.tmp_path / "manifest.json"
    target.write_text(json.dumps(document))
    if archive_format != "yearly":
        with pytest.raises(ValueError, match="不支持的清单格式"):
            restore_manifest(target, 1)
        assert context.client.get(f"/api/media/{mid}").status_code == 200
        return
    with context.db() as db:
        db.execute(delete(UploadTask))
        for model in reversed(TABLES):
            db.execute(delete(model))
        db.commit()
    restore_manifest(target, 1)
    items = context.client.get("/api/media").json()
    assert items["items"][0]["id"] == mid
    assert set(items["items"][0]["child_ids"]) == {a["id"], b["id"]}
    event = context.client.get("/api/events/" + str(eid)).json()
    assert event["media_ids"] == [mid]
    assert set(event["child_ids"]) == {a["id"], b["id"]}


def test_mysql57_schema_compiles():
    for table in Base.metadata.sorted_tables:
        ddl = str(CreateTable(table).compile(dialect=mysql.dialect()))
        assert "ENGINE=InnoDB" in ddl
        assert "CHARSET=utf8mb4" in ddl
        assert not re.search(r"\b(JSON_TABLE|ROW_NUMBER|WITH RECURSIVE)\b", ddl, re.I)
    media_indexes = {tuple(c.name for c in i.columns) for i in Media.__table__.indexes}
    assert ("status", "taken_at_local", "id") in media_indexes
    constraints = MediaChild.__table__.constraints
    assert any(getattr(c, "name", None) == "uq_media_child" for c in constraints)


def test_backup_originals_and_restore_preflight(context, monkeypatch):
    import hashlib
    import pytest
    from app.backup import backup_objects

    result = upload(context, content=b"original-for-offline-backup")

    class Bucket:
        bucket_name = "test-target"

        def get_object_to_file(self, key, path):
            Path(path).write_bytes(context.storage.objects[key])

    context.storage.bucket = Bucket()
    directory = context.tmp_path / "backup"
    assert backup_objects(directory, context.storage) == 1
    assert backup_objects(directory, context.storage) == 1
    fileid = result["tasks"][0]["file_id"]
    original = directory / "objects" / str(fileid)
    assert original.read_bytes() == b"original-for-offline-backup"
    with context.db() as db:
        db.execute(delete(UploadTask))
        for model in reversed(TABLES):
            db.execute(delete(model))
        db.commit()
    original.write_bytes(b"corrupted")
    with pytest.raises(ValueError, match="SHA-256"):
        restore_manifest(
            directory / "manifest.json", 1, context.storage, directory / "objects"
        )
    assert context.client.get("/api/media").json()["total"] == 0
    original.write_bytes(b"original-for-offline-backup")
    restore_manifest(
        directory / "manifest.json", 1, context.storage, directory / "objects"
    )
    assert (
        context.client.get("/api/media").json()["items"][0]["id"] == result["media_id"]
    )
    with context.db() as db:
        assert db.get(MediaFile, fileid).oss_bucket == "test-target"
