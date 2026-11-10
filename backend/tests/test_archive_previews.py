from io import BytesIO
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

import oss2
import pytest
from PIL import Image
from sqlalchemy import select

from app.models import MediaFile, DisplayPreview, VideoPreview
from app.previews import generate_display_one, tag_archive_one
from app.storage import OSSStorage
from conftest import upload, file_payload


def image_bytes(format="JPEG"):
    stream = BytesIO()
    Image.new("RGB", (40, 60), "red").save(stream, format)
    return stream.getvalue()


@pytest.mark.parametrize("deleted", [False, True])
def test_display_images_persist_before_archive_tag(context, deleted):
    content = image_bytes()
    result = upload(context, content=content, files=[file_payload(content)])
    if deleted:
        assert context.client.delete(f"/api/media/{result['media_id']}").status_code == 200
    stored = dict(context.storage.objects)
    processed = image_bytes("WEBP")
    bucket = Mock()
    bucket.get_object_to_file.side_effect = lambda key, path, **kw: Path(
        path
    ).write_bytes(processed)
    bucket.put_object_from_file.side_effect = lambda key, path, **kw: stored.update(
        {key: Path(path).read_bytes()}
    )
    bucket.head_object.side_effect = lambda key: SimpleNamespace(
        content_length=len(stored[key])
    )
    context.storage.bucket = bucket
    context.storage.mark_archive_ready = Mock()
    with context.db() as db:
        assert not tag_archive_one(db, context.storage)
        assert generate_display_one(db, context.storage)
        assert not generate_display_one(db, context.storage)
        preview = db.scalar(select(DisplayPreview))
        assert preview.status == "ready"
        assert preview.thumbnail_size == len(processed)
        assert preview.image_size == len(processed)
        assert tag_archive_one(db, context.storage)
        assert not tag_archive_one(db, context.storage)
        assert db.get(MediaFile, result["tasks"][0]["file_id"]).archive_tagged_at
    url = f"/api/media/{result['media_id']}/files/{result['tasks'][0]['file_id']}/url"
    if deleted:
        assert context.client.post(f"/api/media/{result['media_id']}/restore", json={}).status_code == 200
    resource = context.client.get(url).json()
    assert resource["url"].endswith("/preview.webp")
    assert resource["mime_type"] == "image/webp"
    assert "x-oss-process" not in resource["url"]
    context.storage.mark_archive_ready.assert_called_once()


def test_oversized_oss_image_falls_back_to_verified_original(context):
    content = image_bytes()
    upload(context, content=content, files=[file_payload(content)])
    stored = dict(context.storage.objects)
    bucket = Mock()

    def download(key, path, **kwargs):
        if kwargs.get("process"):
            raise oss2.exceptions.ServerError(400, {}, b"", {"Code": "ImageTooLarge"})
        Path(path).write_bytes(stored[key])

    bucket.get_object_to_file.side_effect = download
    bucket.put_object_from_file.side_effect = lambda key, path, **kw: stored.update(
        {key: Path(path).read_bytes()}
    )
    bucket.head_object.side_effect = lambda key: SimpleNamespace(
        content_length=len(stored[key])
    )
    context.storage.bucket = bucket
    with context.db() as db:
        assert generate_display_one(db, context.storage)
        preview = db.scalar(select(DisplayPreview))
        assert preview.status == "ready"
        for key in (preview.thumbnail_key, preview.image_key):
            with Image.open(BytesIO(stored[key])) as image:
                assert image.format == "WEBP"
    assert all(
        value == content
        for key, value in stored.items()
        if key.startswith("originals/")
    )


def test_partial_display_upload_failure_never_allows_archive(context):
    content = image_bytes()
    upload(context, content=content, files=[file_payload(content)])
    bucket = Mock()
    bucket.get_object_to_file.side_effect = lambda key, path, **kw: Path(
        path
    ).write_bytes(image_bytes("WEBP"))
    bucket.put_object_from_file.side_effect = RuntimeError("upload interrupted")
    context.storage.bucket = bucket
    context.storage.mark_archive_ready = Mock()
    with context.db() as db:
        assert generate_display_one(db, context.storage)
        assert db.scalar(select(DisplayPreview)).status == "failed"
        assert not tag_archive_one(db, context.storage)
    context.storage.mark_archive_ready.assert_not_called()


def test_video_poster_reuses_compressed_video(context, monkeypatch):
    content = b"original"
    result = upload(
        context,
        content=content,
        files=[file_payload(content, "clip.mov")],
        media_type="video",
    )
    bucket = Mock()
    bucket.get_object_to_file.side_effect = lambda key, path: Path(path).write_bytes(
        b"compressed"
    )
    context.storage.bucket = bucket
    stored = {}
    bucket.put_object_from_file.side_effect = lambda key, path, **kw: stored.update(
        {key: Path(path).read_bytes()}
    )
    bucket.head_object.side_effect = lambda key: SimpleNamespace(
        content_length=len(stored[key])
    )
    monkeypatch.setattr(
        "app.previews.subprocess.run",
        lambda args, **kw: Path(args[-1]).write_bytes(image_bytes("WEBP")),
    )
    with context.db() as db:
        file = db.get(MediaFile, result["tasks"][0]["file_id"])
        db.add(
            VideoPreview(
                sha256=file.sha256,
                status="ready",
                object_key="previews/existing.mp4",
                file_size=10,
            )
        )
        db.commit()
        assert generate_display_one(db, context.storage)
        assert db.scalar(select(DisplayPreview)).status == "ready"
    assert bucket.get_object_to_file.call_args.args[0] == "previews/existing.mp4"


def test_archive_original_api_requires_explicit_restore_and_authenticated_access(
    context, monkeypatch
):
    result = upload(context)
    mid, fid = result["media_id"], result["tasks"][0]["file_id"]
    monkeypatch.setattr(context.storage, "original_status", lambda file: "archived")
    restore = Mock(return_value="restoring")
    monkeypatch.setattr(context.storage, "restore_original", restore)
    path = f"/api/media/{mid}/files/{fid}"
    data = context.client.get(path + "/url?purpose=original").json()
    assert data["status"] == "archived" and data["url"] is None
    restore.assert_not_called()
    assert (
        context.client.post(path + "/restore", json={}).json()["status"] == "restoring"
    )
    assert (
        context.client.post(
            f"/api/media/{mid}/files/999999/restore", json={}
        ).status_code
        == 404
    )
    context.client.cookies.clear()
    assert context.client.post(path + "/restore", json={}).status_code == 401


def test_restore_status_and_bulk_request_are_idempotent():
    storage = OSSStorage.__new__(OSSStorage)
    storage.bucket = Mock()
    file = SimpleNamespace(oss_object_key="originals/file.jpg")
    storage.bucket.head_object.return_value.headers = {
        "x-oss-storage-class": "DeepColdArchive"
    }
    assert storage.original_status(file) == "archived"
    assert storage.restore_original(file) == "restoring"
    config = storage.bucket.restore_object.call_args.kwargs["input"]
    assert config.days == 1 and config.job_parameters.tier == "Bulk"
    xml = oss2.xml_utils.to_put_restore_config(config)
    assert b"<Tier>Bulk</Tier>" in xml and b"<Days>1</Days>" in xml
    storage.bucket.restore_object.reset_mock()
    storage.bucket.head_object.return_value.headers["x-oss-restore"] = (
        'ongoing-request="true"'
    )
    assert storage.restore_original(file) == "restoring"
    storage.bucket.restore_object.assert_not_called()
    storage.bucket.head_object.return_value.headers["x-oss-restore"] = (
        'ongoing-request="false", expiry-date="tomorrow"'
    )
    assert storage.original_status(file) == "ready"


def test_archive_lifecycle_and_tags_preserve_existing_configuration():
    storage = OSSStorage.__new__(OSSStorage)
    storage.bucket = Mock()
    old = oss2.models.LifecycleRule(
        "existing",
        "old/",
        abort_multipart_upload=oss2.models.AbortMultipartUpload(days=7),
    )
    storage.bucket.get_bucket_lifecycle.return_value.rules = [old]
    storage.configure_archive()
    rules = storage.bucket.put_bucket_lifecycle.call_args.args[0].rules
    assert rules[0] is old
    rule = rules[1]
    assert rule.prefix == "originals/" and rule.tagging.tag_set.tagging_rule == {
        "yearly-preview": "ready-v1"
    }
    assert rule.storage_transitions[0].storage_class == "DeepColdArchive"
    assert rule.storage_transitions[0].days == 1
    assert rule.expiration is None
    xml = oss2.xml_utils.to_put_bucket_lifecycle(oss2.models.BucketLifecycle(rules))
    assert b"yearly-preview" in xml and b"DeepColdArchive" in xml
    assert b"AllowSmallFile" not in xml
    tags = oss2.models.TaggingRule()
    tags.add("existing", "keep")
    storage.bucket.get_object_tagging.return_value.tag_set = tags
    storage.mark_archive_ready(SimpleNamespace(oss_object_key="originals/photo"))
    assert storage.bucket.put_object_tagging.call_args.args[1].tag_set.tagging_rule == {
        "existing": "keep",
        "yearly-preview": "ready-v1",
    }
