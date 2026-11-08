from sqlalchemy import select, func
from app.models import MediaFile, Media
from conftest import upload, child, file_payload


def test_repeat_upload_reuses_original_and_unions_children(context):
    a, b = child(context), child(context, "妹妹")
    content = b"same-original"
    first = upload(context, [a["id"]], content=content, batch_name="旧批次")
    before = dict(context.storage.objects)
    duplicate = context.client.post(
        "/api/uploads",
        json={
            "media_type": "photo",
            "files": [file_payload(content, "renamed.jpg")],
            "child_ids": [b["id"]],
            "batch_name": "新批次",
            "timeline_date": "2025-01-01",
        },
    ).json()
    assert duplicate["duplicate"] and duplicate["tasks"] == []
    assert duplicate["media_id"] == first["media_id"]
    item = context.client.get(f"/api/media/{first['media_id']}").json()
    assert set(item["child_ids"]) == {a["id"], b["id"]}
    assert item["batch_name"] == "旧批次"
    assert item["timeline_day"] == "2024-03-31"
    assert context.client.get(f"/api/timeline?child_id={b['id']}").json()["total"] == 1
    assert context.storage.objects == before
    assert context.storage.initiations == 1
    with context.db() as db:
        assert db.scalar(select(func.count()).select_from(MediaFile)) == 1


def test_same_name_different_content_is_not_a_duplicate(context):
    a = upload(context, content=b"first")
    b = upload(context, content=b"second")
    assert a["media_id"] != b["media_id"]
    assert context.client.get("/api/timeline").json()["total"] == 2


def test_live_photo_matches_both_resources_and_never_confuses_still_photo(context):
    content = b"paired-original"
    still = upload(context, content=content, files=[file_payload(content, "a.heic")])
    files = [
        file_payload(content, "a.heic"),
        file_payload(content, "a.mov", "live_video"),
    ]
    live = upload(context, content=content, files=files, media_type="live_photo")
    assert live["media_id"] != still["media_id"]
    repeat = context.client.post(
        "/api/uploads", json={"media_type": "live_photo", "files": files}
    ).json()
    assert repeat["media_id"] == live["media_id"] and repeat["duplicate"]
    changed = [files[0], file_payload(b"different-movie", "b.mov", "live_video")]
    different = context.client.post(
        "/api/uploads", json={"media_type": "live_photo", "files": changed}
    ).json()
    assert different["media_id"] != live["media_id"] and len(different["tasks"]) == 2


def test_recycled_media_does_not_silently_steal_a_new_upload(context):
    original = upload(context, content=b"recoverable")
    context.client.delete(f"/api/media/{original['media_id']}")
    result = upload(context, content=b"recoverable")
    assert result["media_id"] != original["media_id"]
    with context.db() as db:
        assert db.get(Media, original["media_id"]).status == "deleted"


def test_inflight_original_cannot_create_a_second_upload(context):
    payload = {"media_type": "photo", "files": [file_payload(b"reserved", "a.heic")]}
    first = context.client.post("/api/uploads", json=payload)
    assert first.status_code == 200
    payload["files"][0]["original_filename"] = "renamed.heic"
    second = context.client.post("/api/uploads", json=payload)
    assert second.status_code == 409
    assert "未完成上传" in second.json()["detail"]
    with context.db() as db:
        assert db.scalar(select(func.count()).select_from(Media)) == 1
        assert db.scalar(select(func.count()).select_from(MediaFile)) == 1
    assert context.storage.initiations == 0


def test_inflight_live_photo_matches_both_resources(context):
    payload = {"media_type": "live_photo", "files": [
        file_payload(b"still", "a.heic"), file_payload(b"motion", "a.mov", "live_video")
    ]}
    assert context.client.post("/api/uploads", json=payload).status_code == 200
    assert context.client.post("/api/uploads", json=payload).status_code == 409
    payload["files"][1] = file_payload(b"another-motion", "b.mov", "live_video")
    assert context.client.post("/api/uploads", json=payload).status_code == 200


def test_same_idempotency_request_can_still_resume_inflight(context):
    from uuid import uuid4
    headers = {"Idempotency-Key": str(uuid4())}
    payload = {"media_type": "photo", "files": [file_payload(b"resuming", "a.heic")]}
    first = context.client.post("/api/uploads", json=payload, headers=headers)
    second = context.client.post("/api/uploads", json=payload, headers=headers)
    assert first.status_code == second.status_code == 200
    assert first.json()["media_id"] == second.json()["media_id"]
    assert [t["id"] for t in first.json()["tasks"]] == [t["id"] for t in second.json()["tasks"]]


def test_concurrent_creation_and_receipt_use_current_reads(mysql_engine):
    """Two independent MySQL transactions with snapshots established before either commit."""
    from concurrent.futures import ThreadPoolExecutor
    from threading import Barrier
    from uuid import uuid4
    from sqlalchemy import delete
    from sqlalchemy.orm import sessionmaker
    from fastapi import HTTPException
    from app.models import User, UploadTask, MediaMetadata
    from app.schemas import UploadIn
    from app.uploads import create_upload
    from conftest import FakeStorage

    factory = sessionmaker(bind=mysql_engine, expire_on_commit=False)
    marker = uuid4().hex
    ids = []
    storage = FakeStorage()
    try:
        with factory.begin() as db:
            for n in range(2):
                user = User(username=f"race-{marker}-{n}", password_hash="synthetic-unused", role="member")
                db.add(user)
                db.flush()
                ids.append(user.id)

        for replay in (False, True):
            barrier = Barrier(2)
            key = str(uuid4()) if replay else None
            payload = {"media_type": "live_photo", "files": [
                file_payload(f"still-{marker}-{replay}".encode(), "race.heic"),
                file_payload(f"motion-{marker}-{replay}".encode(), "race.mov", "live_video"),
            ]}

            def create(n):
                with factory() as db:
                    # Auth normally creates this consistent-read snapshot before upload locking.
                    user = db.get(User, ids[0] if replay else ids[n])
                    db.scalar(select(func.count()).select_from(Media))
                    barrier.wait(timeout=10)
                    try:
                        return 200, create_upload(UploadIn(**payload), key, db, user, storage)
                    except HTTPException as error:
                        return error.status_code, error.detail

            with ThreadPoolExecutor(max_workers=2) as pool:
                results = list(pool.map(create, (0, 1)))
            if replay:
                assert [code for code, _ in results] == [200, 200]
                assert results[0][1]["media_id"] == results[1][1]["media_id"]
                assert [t["id"] for t in results[0][1]["tasks"]] == [t["id"] for t in results[1][1]["tasks"]]
            else:
                assert sorted(code for code, _ in results) == [200, 409]
        assert storage.initiations == 0
        with factory() as db:
            assert db.scalar(select(func.count()).select_from(Media).where(Media.owner_id.in_(ids))) == 2
    finally:
        # Only remove records owned by these unique synthetic users; leave other test data intact.
        if ids:
            with factory.begin() as db:
                mids = list(db.scalars(select(Media.id).where(Media.owner_id.in_(ids))))
                db.execute(delete(UploadTask).where(UploadTask.owner_id.in_(ids)))
                db.execute(delete(MediaMetadata).where(MediaMetadata.media_id.in_(mids)))
                db.execute(delete(MediaFile).where(MediaFile.media_id.in_(mids)))
                db.execute(delete(Media).where(Media.id.in_(mids)))
                db.execute(delete(User).where(User.id.in_(ids)))
