from datetime import date, datetime
from urllib.parse import quote
import pytest
from app.models import Media, TimelineFolder, Event, TimelineDay
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
