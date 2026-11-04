from urllib.parse import quote
from conftest import upload


def test_batch_name_and_archive_date_preserve_original_time(context):
    result = upload(context, batch_name="第一次旅行", timeline_date="2024-04-01")
    client = context.client
    media = client.get(f"/api/media/{result['media_id']}").json()
    assert media["batch_name"] == "第一次旅行"
    assert media["timeline_day"] == "2024-04-01"
    assert media["original_taken_at_local"] == "2024-03-31T10:30:00"
    assert media["taken_at_local"] == "2024-03-31T10:30:00"
    assert (
        client.get(
            "/api/timeline?start=2024-04-01T00:00:00&end=2024-04-02T00:00:00"
        ).json()["total"]
        == 1
    )
    assert client.get("/api/timeline?q=第一次旅行").json()["total"] == 1
    assert client.get("/api/media?q=第一次旅行").json()["total"] == 1
    assert (
        client.get(
            "/api/timeline?date_basis=capture&start=2024-03-31T00:00:00&end=2024-04-01T00:00:00"
        ).json()["total"]
        == 1
    )
    assert (
        client.get(
            "/api/timeline?date_basis=capture&start=2024-04-01T00:00:00&end=2024-04-02T00:00:00"
        ).json()["total"]
        == 0
    )
    # An older editor that omits the new fields preserves existing organization.
    assert (
        client.put(
            f"/api/media/{result['media_id']}", json={"title": "旅行第一天"}
        ).status_code
        == 200
    )
    assert (
        client.get(f"/api/media/{result['media_id']}").json()["timeline_day"]
        == "2024-04-01"
    )


def test_batch_organize_and_restore_capture_date(context):
    ids = [upload(context)["media_id"], upload(context, taken=None)["media_id"]]
    client = context.client
    before = client.get(f"/api/media/{ids[0]}").json()["metadata"]
    assert (
        client.post(
            "/api/media/batch-organize",
            json={
                "media_ids": ids,
                "batch_name": "满月",
                "timeline_date": "2024-05-01",
            },
        ).status_code
        == 200
    )
    data = client.get("/api/timeline?q=满月").json()
    assert data["total"] == 2
    assert {m["timeline_day"] for m in data["items"]} == {"2024-05-01"}
    assert (
        client.post(
            "/api/media/batch-organize", json={"media_ids": ids, "timeline_date": None}
        ).status_code
        == 200
    )
    rows = client.get("/api/timeline?q=满月").json()["items"]
    assert [m["timeline_day"] for m in rows] == ["2024-03-31", None]
    assert client.get(f"/api/media/{ids[0]}").json()["metadata"] == before


def test_reorder_persists_across_cursor_pages_and_keeps_unloaded_items(context):
    ids = [upload(context)["media_id"] for _ in range(4)]
    client = context.client
    assert (
        client.post(
            "/api/media/reorder",
            json={
                "media_ids": [ids[0], ids[1]],
                "target_id": ids[3],
                "placement": "before",
            },
        ).status_code
        == 200
    )
    expected = [ids[0], ids[1], ids[3], ids[2]]
    seen, cursor = [], None
    for _ in expected:
        path = "/api/timeline?page_size=1"
        if cursor:
            path += "&cursor=" + quote(cursor)
        result = client.get(path).json()
        seen.extend(m["id"] for m in result["items"])
        cursor = result["next_cursor"]
    assert seen == expected
    assert cursor is None
    assert [m["id"] for m in client.get("/api/timeline").json()["items"]] == expected
    appended = upload(context)["media_id"]
    assert [
        m["id"] for m in client.get("/api/timeline").json()["items"]
    ] == expected + [appended]


def test_organization_validation_and_viewer_permissions(context):
    first = upload(context)["media_id"]
    other_day = upload(context, taken="2024-04-01T12:00:00")["media_id"]
    client = context.client
    assert (
        client.post(
            "/api/media/reorder", json={"media_ids": [first], "target_id": other_day}
        ).status_code
        == 422
    )
    assert (
        client.post(
            "/api/media/reorder", json={"media_ids": [first], "target_id": first}
        ).status_code
        == 422
    )
    assert (
        client.post(
            "/api/media/batch-organize", json={"media_ids": [first]}
        ).status_code
        == 422
    )
    assert (
        client.post(
            "/api/media/batch-organize",
            json={"media_ids": [first, 99999999], "batch_name": "不应部分保存"},
        ).status_code
        == 404
    )
    assert client.get(f"/api/media/{first}").json()["batch_name"] == ""
    client.cookies.set("yearly_session", "viewer")
    client.headers["X-CSRF-Token"] = "csrf-viewer"
    assert (
        client.post(
            "/api/media/batch-organize",
            json={"media_ids": [first], "batch_name": "无权限"},
        ).status_code
        == 403
    )
    assert (
        client.post(
            "/api/media/reorder", json={"media_ids": [first], "target_id": other_day}
        ).status_code
        == 403
    )


def test_reset_order_scopes_and_capture_time_sort(context):
    from datetime import date, datetime
    from app.models import Media, TimelineFolder

    with context.db() as db:
        folder = TimelineFolder(name="当天文件夹", timeline_date=date(2024, 3, 31))
        db.add(folder)
        db.flush()
        rows = [
            Media(
                owner_id=1,
                media_type="photo",
                status="active",
                timeline_date=date(2024, 3, 31),
                original_taken_at_local=datetime(2024, 3, 30, 10),
                taken_at_local=datetime(2024, 3, 30, 10),
                sort_order=90,
            ),
            Media(
                owner_id=1,
                media_type="photo",
                status="active",
                timeline_date=date(2024, 3, 31),
                original_taken_at_local=datetime(2024, 3, 31, 11),
                taken_at_local=datetime(2024, 3, 31, 11),
                sort_order=10,
            ),
            Media(
                owner_id=1,
                media_type="photo",
                status="active",
                timeline_date=date(2024, 3, 31),
                folder_id=folder.id,
                sort_order=80,
            ),
            Media(
                owner_id=1,
                media_type="photo",
                status="active",
                timeline_date=date(2024, 4, 1),
                sort_order=70,
            ),
            Media(
                owner_id=1,
                media_type="photo",
                status="deleted",
                timeline_date=date(2024, 3, 31),
                sort_order=60,
            ),
            Media(
                owner_id=1,
                media_type="photo",
                status="active",
                purpose="avatar",
                timeline_date=date(2024, 3, 31),
                sort_order=50,
            ),
            Media(owner_id=1, media_type="photo", status="active", sort_order=40),
        ]
        db.add_all(rows)
        db.commit()
        ids = [m.id for m in rows]
        fid = folder.id
    client = context.client
    assert (
        client.post(
            "/api/media/reset-order", json={"day": "2024-03-31", "folder_id": fid}
        ).status_code
        == 200
    )
    with context.db() as db:
        assert db.get(Media, ids[0]).sort_order == 90
        assert db.get(Media, ids[2]).sort_order == 0
        assert db.get(Media, ids[2]).folder_id == fid
    assert (
        client.post("/api/media/reset-order", json={"day": "2024-03-31"}).status_code
        == 200
    )
    with context.db() as db:
        assert [db.get(Media, mid).sort_order for mid in ids] == [
            0,
            0,
            0,
            70,
            60,
            50,
            40,
        ]
        assert db.get(Media, ids[0]).original_taken_at_local == datetime(
            2024, 3, 30, 10
        )
    timeline = client.get(
        "/api/timeline?start=2024-03-31T00:00:00&end=2024-04-01T00:00:00"
    ).json()
    assert [m["id"] for m in timeline["items"]] == [ids[1], ids[0], ids[2]]
    assert client.post("/api/media/reset-order", json={"day": None}).status_code == 200
    with context.db() as db:
        assert db.get(Media, ids[6]).sort_order == 0
        assert db.get(Media, ids[3]).sort_order == 70


def test_reset_order_validates_day_and_permissions(context):
    client = context.client
    fid = client.post(
        "/api/folders", json={"name": "测试", "timeline_date": "2024-03-31"}
    ).json()["id"]
    assert client.post("/api/media/reset-order", json={}).status_code == 422
    assert (
        client.post(
            "/api/media/reset-order", json={"day": "2024-04-01", "folder_id": fid}
        ).status_code
        == 422
    )
    client.cookies.set("yearly_session", "viewer")
    client.headers["X-CSRF-Token"] = "csrf-viewer"
    assert (
        client.post("/api/media/reset-order", json={"day": "2024-03-31"}).status_code
        == 403
    )
