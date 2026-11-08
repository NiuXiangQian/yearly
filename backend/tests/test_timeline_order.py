from datetime import date, datetime
from urllib.parse import quote
import pytest
from app.models import Media, MediaFile, UploadTask, TimelineFolder, Event, TimelineDay
from test_shares import share, public


@pytest.mark.parametrize("order", ["asc", "desc"])
def test_private_cursor_order_with_unknown_dates_and_manual_positions(context, order):
    with context.db() as db:
        rows = [
            Media(
                owner_id=1,
                media_type="photo",
                status="active",
                taken_at_local=datetime(2024, 3, 30, 12),
            ),
            Media(
                owner_id=1,
                media_type="photo",
                status="active",
                taken_at_local=datetime(2024, 3, 31, 8),
            ),
            Media(
                owner_id=1,
                media_type="photo",
                status="active",
                taken_at_local=datetime(2024, 3, 31, 18),
            ),
            Media(
                owner_id=1,
                media_type="photo",
                status="active",
                taken_at_local=datetime(2024, 3, 31, 11),
                sort_order=10,
            ),
            Media(
                owner_id=1,
                media_type="photo",
                status="active",
                timeline_date=date(2024, 3, 31),
            ),
            Media(owner_id=1, media_type="photo", status="active"),
        ]
        folder = TimelineFolder(name="Folder", timeline_date=date(2024, 3, 31))
        db.add_all([*rows, folder])
        db.commit()
        ids = [m.id for m in rows]
        fid = folder.id
    same_day = [("media", ids[3]), ("folder", fid)] + [
        ("media", ids[i]) for i in ([1, 2, 4] if order == "asc" else [2, 1, 4])
    ]
    expected = (
        [("media", ids[0])] + same_day
        if order == "asc"
        else same_day + [("media", ids[0])]
    ) + [("media", ids[5])]
    collected, cursor = [], None
    for page in range(10):
        response = context.client.get(
            f"/api/timeline?group_folders=true&page_size=2&order={order}"
            + (f"&cursor={quote(cursor)}" if cursor else "")
        )
        assert response.status_code == 200, response.text
        data = response.json()
        collected.extend((m["kind"], m["id"]) for m in data["items"])
        cursor = data["next_cursor"]
        if page == 0:
            opposite = "asc" if order == "desc" else "desc"
            assert (
                context.client.get(
                    f"/api/timeline?group_folders=true&order={opposite}&cursor={quote(cursor)}"
                ).status_code
                == 422
            )
        if not cursor:
            break
    assert collected == expected
    assert len(collected) == len(set(collected))
    # Starting at an undated entry still walks back through manual positions and dates.
    prior, cursor = [], None
    for _ in range(10):
        params = {"anchor_media_id": ids[5], "before": "true", "page_size": 2, "order": order}
        if cursor:
            params["cursor"] = cursor
        response = context.client.get("/api/timeline", params=params)
        assert response.status_code == 200, response.text
        data = response.json()
        prior = [item["id"] for item in data["items"]] + prior
        cursor = data["previous_cursor"]
        if not cursor:
            break
    assert prior == [mid for kind, mid in expected[:-1] if kind == "media"]


def test_upload_time_pagination_and_archive_anchor(context):
    with context.db() as db:
        old_photo = Media(
            owner_id=1,
            media_type="photo",
            status="active",
            timeline_date=date(2017, 8, 9),
            created_at=datetime(2026, 11, 1),
        )
        recent_photo = Media(
            owner_id=1,
            media_type="photo",
            status="active",
            timeline_date=date(2026, 11, 5),
            created_at=datetime(2026, 11, 6),
            sort_order=9,
        )
        undated = Media(
            owner_id=1, media_type="photo", status="active", created_at=datetime(2026, 11, 4)
        )
        db.add_all([old_photo, recent_photo, undated])
        db.flush()
        file = MediaFile(
            media_id=old_photo.id,
            file_role="original",
            oss_bucket="private-test",
            oss_object_key="test/recent.jpg",
            original_filename="recent.jpg",
            mime_type="image/jpeg",
            file_size=1,
            sha256="a" * 64,
            crc64="1",
            upload_status="complete",
        )
        db.add(file)
        db.flush()
        db.add(
            UploadTask(
                id="test-recent-upload",
                owner_id=1,
                media_id=old_photo.id,
                file_id=file.id,
                part_size=1,
                status="complete",
                expires_at=datetime(2026, 11, 12),
                updated_at=datetime(2026, 11, 8, 2, 30),
            )
        )
        db.commit()
        old_id, recent_id, undated_id = old_photo.id, recent_photo.id, undated.id

    response = context.client.get("/api/timeline?date_basis=upload&page_size=1")
    assert response.status_code == 200, response.text
    first = response.json()
    assert first["items"][0]["id"] == old_id
    assert first["items"][0]["uploaded_at"] == "2026-11-08T02:30:00"
    cursor = first["next_cursor"]
    next_page = context.client.get("/api/timeline", params={"date_basis": "upload", "cursor": cursor})
    assert [item["id"] for item in next_page.json()["items"]] == [recent_id, undated_id]
    assert context.client.get("/api/timeline", params={"cursor": cursor}).status_code == 422
    response = context.client.get("/api/timeline", params={"anchor_media_id": old_id, "page_size": 1})
    assert response.status_code == 200, response.text
    anchored = response.json()
    assert anchored["items"][0]["timeline_day"] == "2017-08-09"
    assert anchored["items"][0]["id"] == old_id
    response = context.client.get("/api/timeline", params={"anchor_media_id": old_id, "cursor": anchored["next_cursor"]})
    assert [item["id"] for item in response.json()["items"]] == [undated_id]
    response = context.client.get("/api/timeline", params={"anchor_media_id": undated_id})
    assert [item["id"] for item in response.json()["items"]] == [undated_id]


def test_share_bounds_respect_content_permissions(context):
    with context.db() as db:
        private_folder = TimelineFolder(
            name="Private", timeline_date=date(2020, 1, 1), share_allowed=False
        )
        db.add(private_folder)
        db.flush()
        db.add_all(
            [
                Media(
                    owner_id=1,
                    media_type="photo",
                    status="active",
                    taken_at_local=datetime(2020, 1, 1),
                    folder_id=private_folder.id,
                ),
                Media(
                    owner_id=1,
                    media_type="photo",
                    status="active",
                    taken_at_local=datetime(2021, 1, 1),
                    share_allowed=False,
                ),
                Media(
                    owner_id=1,
                    media_type="photo",
                    status="active",
                    taken_at_local=datetime(2022, 1, 1),
                ),
                TimelineDay(timeline_date=date(2022, 1, 1), share_allowed=False),
                Media(
                    owner_id=1,
                    media_type="photo",
                    status="active",
                    purpose="avatar",
                    taken_at_local=datetime(2019, 1, 1),
                ),
                Media(owner_id=1, media_type="photo", status="active"),
                Event(title="Allowed", start_at=datetime(2024, 1, 1), created_by=1),
                Media(
                    owner_id=1,
                    media_type="photo",
                    status="active",
                    taken_at_local=datetime(2024, 2, 1),
                ),
            ]
        )
        db.commit()
    assert context.client.get("/api/shares/bounds").json() == {
        "earliest": "2024-01-01",
        "latest": "2024-02-01",
    }
    context.client.cookies.clear()
    assert context.client.get("/api/shares/bounds").status_code == 401


@pytest.mark.parametrize("order", ["asc", "desc"])
def test_public_order_day_pagination_and_entry_pagination(context, order):
    with context.db() as db:
        for day in range(1, 10):
            db.add(Event(title=str(day), start_at=datetime(2024, 4, day), created_by=1))
        media = [
            Media(
                owner_id=1,
                media_type="photo",
                status="active",
                taken_at_local=datetime(2024, 4, 9, hour),
            )
            for hour in range(10)
        ]
        db.add_all(media)
        db.commit()
        ids = [m.id for m in media]
    data = share(context, start_date="2024-04-01", end_date="2024-04-09")
    base = public(context, data)
    first = context.client.get(f"{base}?order={order}").json()
    expected = [
        f"2024-04-{d:02}" for d in (range(1, 10) if order == "asc" else range(9, 0, -1))
    ]
    assert [d["day"] for d in first["days"]] == expected[:7]
    param = "after" if order == "asc" else "before"
    cursor = first["next_" + param]
    second = context.client.get(f"{base}?order={order}&{param}={cursor}").json()
    assert [d["day"] for d in second["days"]] == expected[7:]
    assert second["next_" + param] is None
    first_day = next(
        d for d in first["days"] + second["days"] if d["day"] == "2024-04-09"
    )
    rest = context.client.get(f"{base}/days/2024-04-09?offset=8&order={order}").json()
    returned = [
        m["id"] for m in first_day["items"] + rest["items"] if m["kind"] == "media"
    ]
    assert returned == (ids if order == "asc" else ids[::-1])


@pytest.mark.parametrize("order", ["asc", "desc"])
def test_share_date_index_and_anchor_keep_scope_and_permissions(context, order):
    from app.models import TimelineShare

    with context.db() as db:
        db.add_all(
            [
                Event(title="visible", start_at=datetime(2024, 4, 1), created_by=1),
                Event(
                    title="visible later", start_at=datetime(2024, 4, 9), created_by=1
                ),
                Event(
                    title="private",
                    start_at=datetime(2024, 4, 4),
                    created_by=1,
                    share_allowed=False,
                ),
                Event(title="blocked day", start_at=datetime(2024, 4, 5), created_by=1),
                TimelineDay(timeline_date=date(2024, 4, 5), share_allowed=False),
                Event(title="outside", start_at=datetime(2024, 5, 1), created_by=1),
            ]
        )
        db.commit()
    data = share(context, start_date="2024-04-01", end_date="2024-04-09")
    base = public(context, data)
    assert context.client.get(base + "/dates").json() == {
        "dates": ["2024-04-01", "2024-04-09"]
    }
    anchor = "2024-04-09" if order == "asc" else "2024-04-01"
    rows = context.client.get(f"{base}?order={order}&anchor={anchor}").json()
    assert [d["day"] for d in rows["days"]] == [anchor]
    # Supplying an outside or excluded anchor cannot extend the link's scope.
    for anchor in ["2024-03-01", "2024-05-01", "2024-04-04", "2024-04-05"]:
        rows = context.client.get(f"{base}?order={order}&anchor={anchor}").json()
        assert {d["day"] for d in rows["days"]} <= {"2024-04-01", "2024-04-09"}
    with context.db() as db:
        db.get(TimelineShare, data["id"]).revoked = True
        db.commit()
    assert context.client.get(base + "/dates").status_code == 404
    assert context.client.get(base + "?anchor=2024-04-01").status_code == 404
