"""Native protocol regressions: synthetic bytes, FakeStorage, isolated MySQL test DB."""
from datetime import datetime, timedelta
from uuid import uuid4
from sqlalchemy import func, select
from app.db import now
from app.models import Media, MediaFile, MediaMetadata, UploadTask, UserSession
from app.security import digest
from conftest import file_payload


def live_body():
    return {
        "media_type": "live_photo",
        "batch_name": "Synthetic native batch",
        "files": [file_payload(b"still", "SYNTHETIC.HEIC"), file_payload(b"motion", "SYNTHETIC.MOV", "live_video")],
        "original_taken_at_local": "2020-01-02T03:04:05",
        "original_offset_minutes": 480,
        "time_source": "EXIF.DateTimeOriginal",
        "time_confidence": "high",
        "metadata": {"source": "ios_photokit", "original": {"ContentIdentifier": "synthetic-pair", "GPSLatitude": 30.0}, "live_video": {"com.apple.quicktime.content.identifier": "synthetic-pair"}},
    }


def finish(context, task, content):
    client = context.client
    assert client.post(f"/api/uploads/{task['id']}/sign?number=1").status_code == 200
    with context.db() as db:
        uid = db.get(UploadTask, task["id"]).oss_upload_id
    context.storage.uploads[uid]["parts"][1] = content
    return client.post(f"/api/uploads/{task['id']}/complete")


def test_native_create_lost_response_reuses_both_tasks(context):
    assert context.client.get("/api/uploads").headers["X-Yearly-Upload-Protocol"] == "idempotent-v1"
    key = {"Idempotency-Key": str(uuid4())}
    body = live_body()
    first = context.client.post("/api/uploads", json=body, headers=key)
    assert first.status_code == 200
    again = context.client.post("/api/uploads", json=body, headers=key)
    assert again.status_code == 200
    assert first.json()["media_id"] == again.json()["media_id"]
    for created, recovered in zip(first.json()["tasks"], again.json()["tasks"], strict=True):
        # MySQL DATETIME(3) persists milliseconds; the initial response may include microseconds.
        first_expiry, next_expiry = created.pop("expires_at"), recovered.pop("expires_at")
        assert abs((datetime.fromisoformat(first_expiry) - datetime.fromisoformat(next_expiry)).total_seconds()) < 0.001
        assert created == recovered
    with context.db() as db:
        assert db.scalar(select(func.count()).select_from(Media)) == 1
        assert db.scalar(select(func.count()).select_from(UploadTask)) == 2
        meta = db.get(MediaMetadata, first.json()["media_id"])
        assert meta.parser_name == "ImageIO + AVFoundation"
        assert meta.raw_metadata["original"] == body["metadata"]["original"]
    assert context.storage.initiations == 0
    assert context.client.post("/api/uploads", json={**body, "batch_name": "changed"}, headers=key).status_code == 409


def test_live_photo_does_not_publish_until_mov_verified_then_resumes(context):
    key = {"Idempotency-Key": str(uuid4())}
    body = live_body()
    result = context.client.post("/api/uploads", json=body, headers=key).json()
    still, video = result["tasks"]
    assert finish(context, still, b"still").status_code == 200
    assert context.client.get("/api/media").json()["total"] == 0
    assert context.client.post(f"/api/uploads/{video['id']}/complete").status_code == 409
    resumed = context.client.post("/api/uploads", json=body, headers=key).json()
    assert resumed["media_id"] == result["media_id"]
    assert [t["status"] for t in resumed["tasks"]] == ["complete", "pending"]
    assert finish(context, video, b"motion").status_code == 200
    assert context.client.get("/api/media").json()["total"] == 1
    with context.db() as db:
        media = db.get(Media, result["media_id"])
        assert media.original_taken_at_local.isoformat() == "2020-01-02T03:04:05"
        assert media.original_offset_minutes == 480
    assert context.storage.completions == 2
    assert context.client.post("/api/uploads", json=body, headers={"Idempotency-Key": str(uuid4())}).json()["duplicate"] is True
    assert context.storage.initiations == 2


def test_native_key_is_owner_scoped_and_cannot_be_injected(context):
    key = {"Idempotency-Key": str(uuid4())}
    body = live_body()
    body["metadata"]["_upload_receipt"] = {"key": "forged", "fingerprint": "forged"}
    first = context.client.post("/api/uploads", json=body, headers=key).json()
    context.client.cookies.set("yearly_session", "member")
    context.client.headers["X-CSRF-Token"] = "csrf-member"
    other = context.client.post("/api/uploads", json=body, headers=key).json()
    assert first["media_id"] != other["media_id"]
    assert context.client.post(f"/api/uploads/{first['tasks'][0]['id']}/sign?number=1").status_code == 403
    with context.db() as db:
        assert db.get(MediaMetadata, first["media_id"]).raw_metadata["_upload_receipt"]["key"] == key["Idempotency-Key"]
    no_header = context.client.post("/api/uploads", json=body).json()
    with context.db() as db:
        assert "_upload_receipt" not in db.get(MediaMetadata, no_header["media_id"]).raw_metadata


def test_native_expired_receipt_cannot_create_new_tasks(context):
    key = {"Idempotency-Key": str(uuid4())}
    body = live_body()
    result = context.client.post("/api/uploads", json=body, headers=key).json()
    with context.db() as db:
        db.get(UploadTask, result["tasks"][0]["id"]).expires_at = now() - timedelta(days=1)
        db.commit()
    assert context.client.post("/api/uploads", json=body, headers=key).status_code == 410
    with context.db() as db:
        assert db.scalar(select(func.count()).select_from(Media)) == 1


def test_native_upload_keeps_cookie_csrf_origin_and_role_checks(context):
    client = context.client
    body = live_body()
    task = client.post("/api/uploads", json=body).json()["tasks"][0]
    paths = ["/api/uploads", f"/api/uploads/{task['id']}/sign?number=1"]
    for cookie, csrf, origin, expected in [
        (None, "csrf-admin", "http://testserver", 401),
        ("viewer", "csrf-viewer", "http://testserver", 403),
        ("admin", "bad", "http://testserver", 403),
        ("admin", "csrf-admin", "https://evil.invalid", 403),
    ]:
        client.cookies.clear()
        if cookie:
            client.cookies.set("yearly_session", cookie)
        for path in paths:
            response = client.post(path, json=body if path == "/api/uploads" else {}, headers={"X-CSRF-Token": csrf, "Origin": origin, "Idempotency-Key": str(uuid4())})
            assert response.status_code == expected
    with context.db() as db:
        db.get(UserSession, digest("admin")).expires_at = now() - timedelta(seconds=1)
        db.commit()
    client.headers["Origin"] = "http://testserver"
    client.headers["X-CSRF-Token"] = "csrf-admin"
    assert client.post(paths[1]).status_code == 401
    assert context.storage.initiations == 0


def test_native_rejects_invalid_idempotency_key(context):
    assert context.client.post("/api/uploads", json=live_body(), headers={"Idempotency-Key": "invalid"}).status_code == 422
