import json
from urllib.parse import quote
from sqlalchemy import select, delete
from app.models import Media, TimelineFolder, UploadTask, Child
from app.backup import TABLES, restore_manifest
from conftest import upload, child


def folder(context, name="出生纪念", day="2024-03-31"):
    r = context.client.post("/api/folders", json={"name": name, "timeline_date": day})
    assert r.status_code == 200, r.text
    return r.json()


def test_folder_membership_flat_views_and_filters(context):
    a, b = child(context), child(context, "妹妹")
    f = folder(context)
    m = upload(context, [a["id"]])["media_id"]
    other = upload(context, [b["id"]])["media_id"]
    assert (
        context.client.post(
            "/api/folders/move-media", json={"media_ids": [m], "folder_id": f["id"]}
        ).status_code
        == 200
    )
    root = context.client.get("/api/timeline?group_folders=true").json()
    assert [(r["kind"], r["id"]) for r in root["items"]] == [
        ("folder", f["id"]),
        ("media", other),
    ]
    assert root["items"][0]["media_count"] == 1
    page = context.client.get("/api/timeline?group_folders=true&page_size=1").json()
    next_page = context.client.get(
        "/api/timeline?group_folders=true&page_size=1&cursor="
        + quote(page["next_cursor"])
    ).json()
    assert next_page["items"][0]["kind"] == "media"
    assert next_page["items"][0]["id"] == other
    assert next_page["next_cursor"] is None
    assert (
        context.client.get(f"/api/media?folder_id={f['id']}").json()["items"][0]["id"]
        == m
    )
    assert context.client.get("/api/timeline").json()["total"] == 2
    assert (
        context.client.get(
            f"/api/timeline?group_folders=true&child_id={a['id']}"
        ).json()["items"][0]["kind"]
        == "folder"
    )
    assert all(
        r["kind"] != "folder"
        for r in context.client.get(
            f"/api/timeline?group_folders=true&child_id={b['id']}"
        ).json()["items"]
    )
    assert (
        context.client.get(
            "/api/timeline?group_folders=true&date_basis=capture"
        ).json()["total"]
        == 2
    )


def test_folder_order_pagination_rename_and_delete_keep_media(context):
    first, second = folder(context), folder(context, "家人合影")
    m = upload(context)["media_id"]
    context.client.post(
        "/api/folders/move-media", json={"media_ids": [m], "folder_id": first["id"]}
    )
    assert (
        context.client.put(
            f"/api/folders/{first['id']}", json={"name": " 初见 "}
        ).json()["name"]
        == "初见"
    )
    assert (
        context.client.post(
            f"/api/folders/{first['id']}/reorder", json={"target_id": second["id"]}
        ).status_code
        == 200
    )
    page = context.client.get("/api/timeline?group_folders=true&page_size=1").json()
    assert page["items"][0]["id"] == first["id"]
    page2 = context.client.get(
        "/api/timeline?group_folders=true&page_size=1&cursor="
        + quote(page["next_cursor"])
    ).json()
    assert page2["items"][0]["id"] == second["id"] and page2["next_cursor"] is None
    assert context.client.delete(f"/api/folders/{first['id']}").status_code == 200
    with context.db() as db:
        assert (
            db.get(Media, m).folder_id is None and db.get(Media, m).status == "active"
        )
        assert db.get(TimelineFolder, first["id"]).status == "deleted"
    assert context.client.get(f"/api/folders/{first['id']}").status_code == 404
    assert len(context.storage.objects) == 1


def test_move_validation_and_scope_of_media_order(context):
    f = folder(context)
    one, two = upload(context)["media_id"], upload(context)["media_id"]
    other = upload(context, taken="2024-04-01T12:00:00")["media_id"]
    r = context.client.post(
        "/api/folders/move-media",
        json={"media_ids": [one, other], "folder_id": f["id"]},
    )
    assert r.status_code == 422
    with context.db() as db:
        assert db.get(Media, one).folder_id is None
    context.client.post(
        "/api/folders/move-media", json={"media_ids": [one], "folder_id": f["id"]}
    )
    assert (
        context.client.post(
            "/api/media/reorder", json={"media_ids": [one], "target_id": two}
        ).status_code
        == 422
    )
    assert (
        context.client.post(
            "/api/folders/move-media", json={"media_ids": [one], "folder_id": None}
        ).status_code
        == 200
    )
    assert (
        context.client.post(
            "/api/media/reorder", json={"media_ids": [one], "target_id": two}
        ).status_code
        == 200
    )


def test_changing_day_leaves_folder_and_upload_can_target_folder(context):
    f = folder(context)
    m = upload(context, folder_id=f["id"])["media_id"]
    assert context.client.get(f"/api/media/{m}").json()["folder_id"] == f["id"]
    assert context.client.get(f"/api/media/{m}").json()["timeline_day"] == "2024-03-31"
    context.client.post(
        "/api/media/batch-organize",
        json={"media_ids": [m], "timeline_date": "2024-04-01"},
    )
    assert context.client.get(f"/api/media/{m}").json()["folder_id"] is None
    another = upload(context, folder_id=f["id"])["media_id"]
    context.client.put(f"/api/media/{another}", json={"timeline_date": "2024-04-02"})
    assert context.client.get(f"/api/media/{another}").json()["folder_id"] is None


def test_read_only_users_cannot_modify_folders(context):
    f = folder(context)
    context.client.cookies.set("yearly_session", "viewer")
    context.client.headers["X-CSRF-Token"] = "csrf-viewer"
    assert context.client.get(f"/api/folders/{f['id']}").status_code == 200
    assert (
        context.client.post(
            "/api/folders", json={"name": "新文件夹", "timeline_date": "2024-03-31"}
        ).status_code
        == 403
    )
    assert (
        context.client.put(f"/api/folders/{f['id']}", json={"name": "更改"}).status_code
        == 403
    )
    assert context.client.delete(f"/api/folders/{f['id']}").status_code == 403
    assert (
        context.client.post(
            "/api/folders/move-media", json={"media_ids": [1], "folder_id": f["id"]}
        ).status_code
        == 403
    )


def test_backup_restores_folder_and_accepts_older_manifest(context):
    f = folder(context)
    m = upload(context, folder_id=f["id"])["media_id"]
    document = context.client.get("/api/export/manifest").json()
    assert document["tables"]["timeline_folder"][0]["name"] == "出生纪念"
    path = context.tmp_path / "folders.json"
    path.write_text(json.dumps(document))
    with context.db() as db:
        db.execute(delete(UploadTask))
        for model in reversed(TABLES):
            db.execute(delete(model))
        db.commit()
    restore_manifest(path, 1)
    with context.db() as db:
        assert db.get(Media, m).folder_id == f["id"]
        db.execute(delete(UploadTask))
        for model in reversed(TABLES):
            db.execute(delete(model))
        db.commit()
    del document["tables"]["timeline_folder"]
    for row in document["tables"]["media"]:
        row.pop("folder_id", None)
    path.write_text(json.dumps(document))
    restore_manifest(path, 1)
    with context.db() as db:
        assert db.get(Media, m).folder_id is None


def test_folder_thumbnails_are_bounded_ordered_and_filtered(context):
    from datetime import datetime

    f = folder(context)
    a, b = child(context), child(context, "妹妹")
    from app.models import MediaChild

    with context.db() as db:
        ids = []
        for hour in range(6):
            m = Media(
                owner_id=1,
                media_type="photo",
                status="active",
                folder_id=f["id"],
                taken_at_local=datetime(2024, 3, 31, hour),
                title=f"相片{hour}",
            )
            db.add(m)
            db.flush()
            ids.append(m.id)
            db.add(MediaChild(media_id=m.id, child_id=a["id"] if hour < 3 else b["id"]))
        db.get(Media, ids[0]).sort_order = 10
        db.add(
            Media(
                owner_id=1,
                media_type="photo",
                status="deleted",
                folder_id=f["id"],
                sort_order=99,
            )
        )
        db.add(
            Media(
                owner_id=1,
                media_type="photo",
                status="active",
                purpose="avatar",
                folder_id=f["id"],
                sort_order=99,
            )
        )
        db.commit()
    previews = context.client.get("/api/timeline?group_folders=true").json()["items"][
        0
    ]["previews"]
    assert [p["id"] for p in previews] == [ids[0], ids[5], ids[4], ids[3]]
    filtered = context.client.get(
        f"/api/timeline?group_folders=true&child_id={a['id']}"
    ).json()
    assert [p["id"] for p in filtered["items"][0]["previews"]] == [
        ids[0],
        ids[2],
        ids[1],
    ]
    searched = context.client.get("/api/timeline?group_folders=true&q=相片4").json()
    assert [p["id"] for p in searched["items"][0]["previews"]] == [ids[4]]


def test_mixed_day_order_pagination_legacy_routes_and_reset(context):
    from datetime import date, datetime

    with context.db() as db:
        db.add_all(
            [
                TimelineFolder(id=i, name=f"目录{i}", timeline_date=date(2024, 3, 31))
                for i in (100, 101)
            ]
        )
        db.flush()
        db.add_all(
            [
                Media(
                    id=i,
                    owner_id=1,
                    media_type="photo",
                    status="active",
                    taken_at_local=datetime(2024, 3, 31, i - 100),
                    title=f"影像{i}",
                )
                for i in range(100, 104)
            ]
        )
        db.commit()
    client = context.client
    request = {
        "items": [{"kind": "folder", "id": 100}],
        "target": {"kind": "media", "id": 102},
        "placement": "after",
    }
    result = client.post("/api/timeline/reorder", json=request)
    assert result.status_code == 200, result.text
    expected = [
        ("folder", 101),
        ("media", 103),
        ("media", 102),
        ("folder", 100),
        ("media", 101),
        ("media", 100),
    ]
    seen, cursor = [], None
    for _ in expected:
        path = "/api/timeline?group_folders=true&page_size=1"
        if cursor:
            path += "&cursor=" + quote(cursor)
        page = client.get(path).json()
        seen.extend((item["kind"], item["id"]) for item in page["items"])
        cursor = page["next_cursor"]
    assert seen == expected and cursor is None
    assert (
        client.post(
            "/api/timeline/reorder",
            json={
                "items": [{"kind": "media", "id": 100}],
                "target": {"kind": "folder", "id": 100},
                "placement": "before",
            },
        ).status_code
        == 200
    )
    assert (
        client.post(
            "/api/media/reorder", json={"media_ids": [101], "target_id": 103}
        ).status_code
        == 200
    )
    rows = client.get("/api/timeline?group_folders=true").json()["items"]
    assert [(r["kind"], r["id"]) for r in rows] == [
        ("folder", 101),
        ("media", 101),
        ("media", 103),
        ("media", 102),
        ("media", 100),
        ("folder", 100),
    ]
    # Folder-only controls must preserve the positions of all intervening media too.
    assert (
        client.post("/api/folders/100/reorder", json={"target_id": 101}).status_code
        == 200
    )
    assert (
        client.post("/api/media/reset-order", json={"day": "2024-03-31"}).status_code
        == 200
    )
    rows = client.get("/api/timeline?group_folders=true").json()["items"]
    assert [(r["kind"], r["id"]) for r in rows] == [
        ("folder", 101),
        ("folder", 100),
        ("media", 103),
        ("media", 102),
        ("media", 101),
        ("media", 100),
    ]


def test_mixed_day_order_rejects_cross_day_nested_media_and_viewers(context):
    from datetime import date, datetime

    with context.db() as db:
        db.add(TimelineFolder(id=100, name="目录", timeline_date=date(2024, 3, 31)))
        db.flush()
        db.add_all(
            [
                Media(
                    id=100,
                    owner_id=1,
                    media_type="photo",
                    status="active",
                    taken_at_local=datetime(2024, 3, 31),
                ),
                Media(
                    id=101,
                    owner_id=1,
                    media_type="photo",
                    status="active",
                    taken_at_local=datetime(2024, 4, 1),
                ),
                Media(
                    id=102,
                    owner_id=1,
                    media_type="photo",
                    status="active",
                    folder_id=100,
                    taken_at_local=datetime(2024, 3, 31),
                ),
            ]
        )
        db.commit()
    client = context.client
    for mid in (101, 102):
        response = client.post(
            "/api/timeline/reorder",
            json={
                "items": [{"kind": "media", "id": mid}],
                "target": {"kind": "folder", "id": 100},
            },
        )
        assert response.status_code == 422
    assert (
        client.post(
            "/api/timeline/reorder",
            json={
                "items": [{"kind": "folder", "id": 100}],
                "target": {"kind": "folder", "id": 100},
            },
        ).status_code
        == 422
    )
    client.cookies.set("yearly_session", "viewer")
    client.headers["X-CSRF-Token"] = "csrf-viewer"
    assert (
        client.post(
            "/api/timeline/reorder",
            json={
                "items": [{"kind": "folder", "id": 100}],
                "target": {"kind": "media", "id": 100},
            },
        ).status_code
        == 403
    )
    with context.db() as db:
        assert db.get(Media, 102).folder_id == 100
        assert db.get(TimelineFolder, 100).sort_order == 0
