import hashlib
import pytest
import oss2
from sqlalchemy import select
from app.models import Media, MediaFile, UploadTask
from app.storage import OSSStorage
from conftest import upload, child, file_payload


@pytest.mark.parametrize(
    "name,kind",
    [
        ("original.jpg", "photo"),
        ("original.heic", "photo"),
        ("original.mov", "video"),
        ("original.mp4", "video"),
    ],
)
def test_original_bytes_and_checksums(context, name, kind):
    content = bytes(range(256)) * 1001
    result = upload(
        context, content=content, files=[file_payload(content, name)], media_type=kind
    )
    with context.db() as db:
        f = db.scalar(select(MediaFile).where(MediaFile.media_id == result["media_id"]))
        assert context.storage.objects[f.oss_object_key] == content
        assert f.sha256 == hashlib.sha256(content).hexdigest()
        assert f.upload_status == "complete"
    assert (
        context.client.get(
            f"/api/media/{result['media_id']}/files/{result['tasks'][0]['file_id']}/url"
        ).status_code
        == 200
    )


def test_live_photo_one_logical_media_two_objects(context):
    content = b"original-resource"
    a, b = child(context), child(context, "妹妹", "2022-01-01")
    files = [
        file_payload(content, "IMG.HEIC"),
        file_payload(content, "IMG.MOV", "live_video"),
    ]
    result = upload(
        context,
        [a["id"], b["id"]],
        content=content,
        files=files,
        media_type="live_photo",
    )
    assert context.client.get("/api/media").json()["total"] == 1
    row = context.client.get("/api/media").json()["items"][0]
    assert row["media_type"] == "live_photo"
    assert len(row["files"]) == 2
    assert len(context.storage.objects) == 2


def test_crc_mismatch_does_not_publish(context):
    client = context.client
    payload = {"media_type": "photo", "files": [file_payload()], "child_ids": []}
    task = client.post("/api/uploads", json=payload).json()["tasks"][0]
    client.post(f"/api/uploads/{task['id']}/sign?number=1", json={})
    with context.db() as db:
        t = db.get(UploadTask, task["id"])
        f = db.get(MediaFile, t.file_id)
        context.storage.objects[f.oss_object_key] = b"X" * f.file_size
    assert (
        client.post(f"/api/uploads/{task['id']}/complete", json={}).status_code == 409
    )
    assert client.get("/api/media").json()["total"] == 0


def test_resume_missing_parts_completion_retry(context):
    client = context.client
    content = b"resumable-original"
    task = client.post(
        "/api/uploads", json={"media_type": "photo", "files": [file_payload(content)]}
    ).json()["tasks"][0]
    assert (
        client.post(f"/api/uploads/{task['id']}/sign?number=2", json={}).status_code
        == 422
    )
    for _ in range(2):
        assert (
            client.post(f"/api/uploads/{task['id']}/sign?number=1", json={}).status_code
            == 200
        )
    assert context.storage.initiations == 1
    assert (
        client.post(f"/api/uploads/{task['id']}/complete", json={}).status_code == 409
    )
    with context.db() as db:
        uid = db.get(UploadTask, task["id"]).oss_upload_id
    context.storage.uploads[uid]["parts"][1] = content
    assert client.get(f"/api/uploads/{task['id']}").json()["parts"] == [
        {"number": 1, "size": len(content)}
    ]
    assert (
        client.post(f"/api/uploads/{task['id']}/complete", json={}).status_code == 200
    )
    assert (
        client.post(f"/api/uploads/{task['id']}/complete", json={}).status_code == 200
    )
    assert context.storage.completions == 1
    assert (
        client.post(f"/api/uploads/{task['id']}/sign?number=1", json={}).status_code
        == 409
    )


def test_upload_validation_and_ownership(context):
    client = context.client
    for name in ["../evil.jpg", "script.svg", "file.exe"]:
        result = client.post(
            "/api/uploads",
            json={"media_type": "photo", "files": [file_payload(name=name)]},
        )
        assert result.status_code == 422
    assert (
        client.post(
            "/api/uploads", json={"media_type": "live_photo", "files": [file_payload()]}
        ).status_code
        == 422
    )
    assert (
        client.post(
            "/api/uploads",
            json={"media_type": "photo", "files": [file_payload()], "child_ids": [999]},
        ).status_code
        == 422
    )
    task = client.post(
        "/api/uploads", json={"media_type": "photo", "files": [file_payload()]}
    ).json()["tasks"][0]
    client.cookies.set("yearly_session", "member")
    client.headers["X-CSRF-Token"] = "csrf-member"
    assert client.get(f"/api/uploads/{task['id']}").status_code == 403


def test_production_v4_scoped_signature(monkeypatch):
    from app.config import settings

    cfg = settings()
    monkeypatch.setattr(cfg, "oss_bucket", "yearly-test")
    monkeypatch.setattr(cfg, "oss_access_key_id", "test-id")
    monkeypatch.setattr(cfg, "oss_access_key_secret", "test-secret")
    storage = OSSStorage()
    f = MediaFile(oss_object_key="originals/uuid.jpg", original_filename="原始.jpg")
    url = storage.sign_part(f, "opaque-upload-id", 1)
    assert "OSS4-HMAC-SHA256" in url
    assert "partNumber=1" in url
    assert "uploadId=opaque-upload-id" in url
    assert "originals" in url
    assert "test-secret" not in url
