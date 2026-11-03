from sqlalchemy import select, func
from app.models import Media, MediaFile, MediaChild
from conftest import child, upload


def test_shared_media_one_object_and_dynamic_ages(context):
    a = child(context)
    b = child(context, "妹妹", "2023-03-01")
    only_a = upload(context, [a["id"]])
    shared = upload(context, [a["id"], b["id"]])
    client = context.client
    all_items = client.get("/api/media").json()
    assert all_items["total"] == 2
    assert len({m["id"] for m in all_items["items"]}) == 2
    assert client.get(f"/api/media?child_id={a['id']}").json()["total"] == 2
    assert client.get(f"/api/media?child_id={b['id']}").json()["total"] == 1
    assert (
        client.get(
            f"/api/media?child_id={a['id']}&child_id={b['id']}&match=all"
        ).json()["total"]
        == 1
    )
    assert (
        client.get(
            f"/api/media?child_id={a['id']}&child_id={b['id']}&match=any"
        ).json()["total"]
        == 2
    )
    shared_row = client.get("/api/media/" + str(shared["media_id"])).json()
    assert shared_row["children"][0]["age"] != shared_row["children"][1]["age"]
    assert len(context.storage.objects) == 2
    assert context.storage.completions == 2
    with context.db() as db:
        assert (
            db.scalar(
                select(func.count(MediaFile.id)).where(
                    MediaFile.media_id == shared["media_id"]
                )
            )
            == 1
        )
    a["birthday"] = "2024-03-31"
    assert client.put("/api/children/" + str(a["id"]), json=a).status_code == 200
    row = client.get(f"/api/media?child_id={a['id']}").json()["items"][0]
    assert row["children"][0]["age"] == "出生当天"
    # Single-child queries show only that child's age tags.
    assert len(row["children"]) == 1


def test_unlink_and_child_delete_preserve_original(context):
    a, b = child(context), child(context, "妹妹", "2023-01-01")
    result = upload(context, [a["id"], b["id"]])
    client = context.client
    assert (
        client.post(
            "/api/media/batch-children",
            json={
                "media_ids": [result["media_id"]],
                "child_ids": [a["id"]],
                "mode": "remove",
            },
        ).status_code
        == 200
    )
    assert client.get(f"/api/media?child_id={a['id']}").json()["total"] == 0
    assert client.get(f"/api/media?child_id={b['id']}").json()["total"] == 1
    assert (
        client.delete(f"/api/children/{b['id']}?confirm_name=错误名字").status_code
        == 422
    )
    assert (
        client.delete(f"/api/children/{b['id']}?confirm_name=妹妹").status_code == 200
    )
    assert client.get("/api/media").json()["total"] == 1
    assert len(context.storage.objects) == 1


def test_time_correction_preserves_raw_and_original_bytes(context):
    a = child(context)
    result = upload(context, [a["id"]], taken=None)
    client = context.client
    mid = result["media_id"]
    before = client.get(f"/api/media/{mid}").json()
    assert before["children"][0]["age"] is None
    assert before["taken_at_utc"] is None
    original_bytes = dict(context.storage.objects)
    data = {
        "title": "一起长大",
        "remark": "备注 <script>alert(1)</script>",
        "child_ids": [a["id"]],
        "corrected_taken_at_local": "2024-03-31T00:10:00",
        "corrected_offset_minutes": 480,
        "latitude": 30.3,
        "longitude": 120.2,
        "location_name": "家里",
    }
    after = client.put(f"/api/media/{mid}", json=data).json()
    assert after["taken_at_local"] == "2024-03-31T00:10:00"
    assert after["taken_at_utc"] == "2024-03-30T16:10:00"
    assert after["original_taken_at_local"] is None
    assert after["metadata"] == before["metadata"]
    assert context.storage.objects == original_bytes
    data["corrected_taken_at_local"] = None
    data["corrected_offset_minutes"] = None
    after = client.put(f"/api/media/{mid}", json=data).json()
    assert after["taken_at_local"] is None
    assert after["taken_at_utc"] is None


def test_stable_pagination_and_trash(context):
    a, b = child(context), child(context, "妹妹", "2022-01-01")
    ids = [upload(context, [a["id"], b["id"]])["media_id"] for _ in range(4)]
    client = context.client
    pages = [
        client.get(
            f"/api/media?child_id={a['id']}&child_id={b['id']}&page_size=1&page={n}"
        ).json()
        for n in range(1, 5)
    ]
    assert [p["items"][0]["id"] for p in pages] == sorted(ids, reverse=True)
    assert all(p["total"] == 4 for p in pages)
    assert client.delete(f"/api/media/{ids[0]}").status_code == 200
    assert client.get(f"/api/media/{ids[0]}").status_code == 404
    assert client.get("/api/media?status=deleted").json()["total"] == 1
    assert client.post(f"/api/media/{ids[0]}/restore", json={}).status_code == 200
    assert client.get("/api/media").json()["total"] == 4
    assert len(context.storage.objects) == 4


def test_explicit_unknown_preserves_original_time(context):
    a = child(context)
    mid = upload(context, [a["id"]])["media_id"]
    row = context.client.put(
        f"/api/media/{mid}", json={"time_unknown": True, "child_ids": [a["id"]]}
    ).json()
    assert row["taken_at_local"] is None
    assert row["children"][0]["age"] is None
    assert row["original_taken_at_local"] == "2024-03-31T10:30:00"
    row = context.client.put(
        f"/api/media/{mid}", json={"time_unknown": False, "child_ids": [a["id"]]}
    ).json()
    assert row["taken_at_local"] == "2024-03-31T10:30:00"


def test_mixed_timeline_dedup_filters_and_pagination(context):
    a, b = child(context), child(context, "妹妹", "2023-01-01")
    mid = upload(context, [a["id"], b["id"]])["media_id"]
    eid = context.client.post(
        "/api/events",
        json={
            "title": "共同成长",
            "child_ids": [a["id"], b["id"]],
            "media_ids": [mid],
            "start_at": "2024-03-31T10:30:00",
        },
    ).json()["id"]
    base = f"/api/timeline?child_id={a['id']}&child_id={b['id']}&match=all"
    data = context.client.get(base).json()
    assert data["total"] == 2
    assert {i["kind"] for i in data["items"]} == {"event", "media"}
    first = context.client.get(base + "&page_size=1&page=1").json()["items"][0]
    second = context.client.get(base + "&page_size=1&page=2").json()["items"][0]
    assert first["kind"] != second["kind"]
    assert context.client.get(base + "&start=2024-04-01T00:00:00").json()["total"] == 0
    assert context.client.get(base + "&media_type=photo").json()["total"] == 1
    assert (
        context.client.get(base + "&q=共同成长").json()["items"][0]["kind"] == "event"
    )


def test_cursor_load_more_avoids_duplicate_rows_after_new_upload(context):
    from urllib.parse import quote

    original_ids = [upload(context)["media_id"] for _ in range(3)]
    first = context.client.get("/api/timeline?page_size=1").json()
    assert first["items"][0]["id"] == original_ids[-1]
    upload(context, taken="2025-01-01T00:00:00")
    second = context.client.get(
        "/api/timeline?page_size=1&cursor=" + quote(first["next_cursor"])
    ).json()
    assert second["items"][0]["id"] == original_ids[-2]
    third = context.client.get(
        "/api/timeline?page_size=1&cursor=" + quote(second["next_cursor"])
    ).json()
    assert third["items"][0]["id"] == original_ids[0]
    assert third["next_cursor"] is None
    assert context.client.get("/api/timeline?cursor=bad").status_code == 422


def test_cursor_unknown_dates_are_stably_last(context):
    from urllib.parse import quote

    unknown = upload(context, taken=None)["media_id"]
    known = upload(context)["media_id"]
    first = context.client.get("/api/timeline?page_size=1").json()
    assert first["items"][0]["id"] == known
    second = context.client.get(
        "/api/timeline?page_size=1&cursor=" + quote(first["next_cursor"])
    ).json()
    assert second["items"][0]["id"] == unknown
    assert second["next_cursor"] is None
