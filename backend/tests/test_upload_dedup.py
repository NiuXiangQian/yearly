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
