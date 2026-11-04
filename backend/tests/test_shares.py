import hashlib
from datetime import timedelta
import pytest
from sqlalchemy import select
from app.db import now
from app.models import Media, TimelineShare, User, VideoPreview, MediaFile
from conftest import upload, file_payload
from test_folders import folder


def share(context, **kwargs):
    response = context.client.post(
        "/api/shares",
        json={
            "start_date": "2024-03-31",
            "end_date": "2024-04-02",
            "hours": 24,
            **kwargs,
        },
    )
    assert response.status_code == 200, response.text
    return response.json()


def public(context, data):
    context.client.cookies.clear()
    return "/api/public/shares/" + data["token"]


@pytest.mark.parametrize("hours", [0, 169, -1, 1.5])
def test_duration_validation(context, hours):
    assert (
        context.client.post(
            "/api/shares",
            json={
                "start_date": "2024-03-31",
                "end_date": "2024-04-02",
                "hours": hours,
            },
        ).status_code
        == 422
    )


@pytest.mark.parametrize("hours", [1, 168])
def test_duration_boundaries_and_token_not_exported(context, hours):
    data = share(context, hours=hours)
    with context.db() as db:
        row = db.get(TimelineShare, data["id"])
        assert row.token_hash == hashlib.sha256(data["token"].encode()).hexdigest()
        assert (
            hours * 3600 - 5 <= (row.expires_at - now()).total_seconds() <= hours * 3600
        )
    assert "token" not in context.client.get("/api/shares").json()[0]
    assert (
        "timeline_share"
        not in context.client.get("/api/export/manifest").json()["tables"]
    )
    assert (
        context.client.post(
            "/api/shares",
            json={
                "start_date": "2024-04-02",
                "end_date": "2024-03-31",
            },
        ).status_code
        == 422
    )


def test_content_permissions_and_direct_access(context):
    visible = upload(context)["media_id"]
    blocked = upload(context)["media_id"]
    outside = upload(context, taken="2024-04-03T12:00:00")["media_id"]
    day_hidden = upload(context, taken="2024-04-01T12:00:00")["media_id"]
    f = folder(context)
    folder_hidden = upload(context)["media_id"]
    context.client.post(
        "/api/folders/move-media",
        json={"folder_id": f["id"], "media_ids": [folder_hidden]},
    )
    avatar = upload(context)["media_id"]
    with context.db() as db:
        db.get(Media, avatar).purpose = "avatar"
        db.commit()
    assert (
        context.client.put(
            f"/api/media/{blocked}", json={"share_allowed": False}
        ).status_code
        == 200
    )
    assert (
        context.client.put(
            f"/api/folders/{f['id']}", json={"name": f["name"], "share_allowed": False}
        ).status_code
        == 200
    )
    assert (
        context.client.put(
            "/api/timeline/days/2024-04-01/sharing", json={"share_allowed": False}
        ).status_code
        == 200
    )
    data = share(context)
    base = public(context, data)
    response = context.client.get(base)
    assert response.status_code == 200
    assert "no-store" in response.headers["cache-control"]
    assert "noindex" in response.headers["x-robots-tag"]
    items = response.json()["days"][0]["items"]
    assert [m["id"] for m in items] == [visible]
    assert set(items[0]) == {"kind", "id", "title", "media_type"}
    for mid in [blocked, outside, day_hidden, folder_hidden, avatar]:
        for purpose in ["thumbnail", "preview"]:
            assert (
                context.client.get(
                    f"{base}/media/{mid}/url?purpose={purpose}"
                ).status_code
                == 404
            )
    assert context.client.get(f'{base}/folders/{f["id"]}').status_code == 404
    assert context.client.get(base + "/days/2024-04-01").json()["items"] == []
    assert (
        context.client.get(f"{base}/media/{visible}/url")
        .json()["url"]
        .endswith("/preview")
    )
    assert context.storage.last_expiry == 60
    assert (
        context.client.get(f"{base}/media/{visible}/url?purpose=original").status_code
        == 422
    )
    for path in ["/api/media", "/api/events", "/api/children", "/api/shares"]:
        assert context.client.get(path).status_code == 401


def test_folder_previews_counts_paging_and_event_cover_exclusion(context):
    f = folder(context)
    ids = [upload(context)["media_id"] for _ in range(5)]
    context.client.post(
        "/api/folders/move-media", json={"folder_id": f["id"], "media_ids": ids}
    )
    event = context.client.post(
        "/api/events",
        json={
            "title": "Shared diary",
            "content": "A happy day",
            "start_at": "2024-03-31T12:00:00",
            "media_ids": ids,
            "cover_media_id": ids[0],
        },
    )
    assert event.status_code == 200, event.text
    for mid in ids[:2]:
        assert (
            context.client.put(
                f"/api/media/{mid}", json={"share_allowed": False}
            ).status_code
            == 200
        )
    data = share(context)
    base = public(context, data)
    items = context.client.get(base).json()["days"][0]["items"]
    folder_item = next(m for m in items if m["kind"] == "folder")
    assert folder_item["media_count"] == 3
    assert {m["id"] for m in folder_item["previews"]} == set(ids[2:])
    diary = next(m for m in items if m["kind"] == "event")
    assert set(diary) == {"id", "kind", "title", "content"}
    inside = context.client.get(f'{base}/folders/{f["id"]}').json()
    assert {m["id"] for m in inside["items"]} == set(ids[2:])
    assert inside["total"] == 3
    assert (
        context.client.get(f'{base}/folders/{f["id"]}?offset=3').json()["items"] == []
    )


def test_day_fold_and_mixed_order(context):
    ids = [upload(context)["media_id"] for _ in range(10)]
    f = folder(context)
    with context.db() as db:
        db.get(Media, ids[0]).sort_order = 20
        db.commit()
    data = share(context)
    base = public(context, data)
    day = context.client.get(base).json()["days"][0]
    assert day["total"] == 11 and len(day["items"]) == 8
    assert day["items"][0]["id"] == ids[0]
    assert day["items"][1]["kind"] == "folder"
    more = context.client.get(base + "/days/2024-03-31?offset=8").json()["items"]
    assert len(more) == 3
    keys = [(m["kind"], m["id"]) for m in day["items"] + more]
    assert len(set(keys)) == 11


def test_expiry_revocation_owner_and_ttl(context):
    mid = upload(context)["media_id"]
    data = share(context)
    base = public(context, data)
    with context.db() as db:
        db.get(TimelineShare, data["id"]).expires_at = now() + timedelta(seconds=20)
        db.commit()
    assert context.client.get(f"{base}/media/{mid}/url").status_code == 200
    assert 1 <= context.storage.last_expiry <= 20
    with context.db() as db:
        db.get(TimelineShare, data["id"]).expires_at = now() - timedelta(seconds=1)
        db.commit()
    for suffix in ["", "/days/2024-03-31", f"/media/{mid}/url", "/folders/1"]:
        assert context.client.get(base + suffix).status_code == 404
    context.client.cookies.set("yearly_session", "admin")
    data = share(context)
    assert context.client.delete("/api/shares/" + str(data["id"])).status_code == 200
    assert context.client.get(public(context, data)).status_code == 404
    context.client.cookies.set("yearly_session", "admin")
    data = share(context)
    with context.db() as db:
        db.get(User, 1).active = False
        db.commit()
    assert context.client.get(public(context, data)).status_code == 404
    assert context.client.get("/api/public/shares/invalid").status_code == 404


def test_share_management_permissions_and_csrf(context):
    data = share(context)
    client = context.client
    client.cookies.set("yearly_session", "viewer")
    client.headers["X-CSRF-Token"] = "csrf-viewer"
    assert (
        client.post(
            "/api/shares", json={"start_date": "2024-01-01", "end_date": "2024-12-31"}
        ).status_code
        == 403
    )
    assert client.delete("/api/shares/" + str(data["id"])).status_code == 403
    client.cookies.set("yearly_session", "member")
    client.headers["X-CSRF-Token"] = "csrf-member"
    assert client.get("/api/shares").json() == []
    assert client.delete("/api/shares/" + str(data["id"])).status_code == 404
    own = share(context)
    assert client.delete("/api/shares/" + str(own["id"])).status_code == 200
    client.headers["X-CSRF-Token"] = "invalid"
    assert (
        client.post(
            "/api/shares", json={"start_date": "2024-01-01", "end_date": "2024-12-31"}
        ).status_code
        == 403
    )


def test_video_only_returns_compressed_preview(context):
    file = file_payload(name="clip.mp4")
    file["mime_type"] = "video/mp4"
    uploaded = upload(context, files=[file], media_type="video")
    mid = uploaded["media_id"]
    data = share(context)
    base = public(context, data)
    assert context.client.get(f"{base}/media/{mid}/url").json()["url"] is None
    with context.db() as db:
        db.add(
            VideoPreview(
                sha256=file["sha256"],
                status="ready",
                object_key="derived.mp4",
                file_size=123,
                error="",
            )
        )
        db.commit()
    assert (
        context.client.get(f"{base}/media/{mid}/url")
        .json()["url"]
        .endswith("compressed.mp4")
    )
    assert context.storage.last_expiry <= 60


def test_day_pagination_and_diary_exclusion(context):
    from datetime import datetime
    from app.models import Event

    with context.db() as db:
        for day in range(1, 10):
            db.add(
                Event(
                    title=f"Day {day}",
                    content="Public story",
                    start_at=datetime(2024, 4, day),
                    created_by=1,
                    status="active",
                )
            )
        db.commit()
        hidden = db.scalar(select(Event.id).where(Event.title == "Day 5"))
    assert (
        context.client.put(
            f"/api/events/{hidden}",
            json={
                "title": "Day 5",
                "start_at": "2024-04-05T00:00:00",
                "share_allowed": False,
            },
        ).status_code
        == 200
    )
    data = share(context, start_date="2024-04-01", end_date="2024-04-09")
    base = public(context, data)
    first = context.client.get(base).json()
    assert len(first["days"]) == 7
    assert first["next_before"] == "2024-04-02"
    assert "2024-04-05" not in [d["day"] for d in first["days"]]
    second = context.client.get(base + "?before=" + first["next_before"]).json()
    assert [d["day"] for d in second["days"]] == ["2024-04-01"]
    assert second["next_before"] is None
    assert context.client.get(base + "/days/2024-04-05").json()["items"] == []


def test_permissions_apply_to_existing_links_and_survive_other_edits(context):
    mid = upload(context)["media_id"]
    f = folder(context)
    context.client.post(
        "/api/folders/move-media", json={"folder_id": f["id"], "media_ids": [mid]}
    )
    links = [share(context), share(context)]
    bases = ["/api/public/shares/" + item["token"] for item in links]
    for base in bases:
        assert context.client.get(f"{base}/media/{mid}/url").status_code == 200
    result = context.client.put(f"/api/media/{mid}", json={"share_allowed": False})
    assert result.status_code == 200 and result.json()["share_allowed"] is False
    # Editing another field with an older client must not re-enable sharing.
    assert (
        context.client.put(f"/api/media/{mid}", json={"title": "Still private"}).json()[
            "share_allowed"
        ]
        is False
    )
    for base in bases:
        assert context.client.get(f"{base}/media/{mid}/url").status_code == 404
        data = context.client.get(f'{base}/folders/{f["id"]}').json()
        assert data["total"] == 0 and data["items"] == []
    assert context.client.get(f"/api/media/{mid}").status_code == 200
    context.client.put(f"/api/media/{mid}", json={"share_allowed": True})
    context.client.put(
        f'/api/folders/{f["id"]}', json={"name": f["name"], "share_allowed": False}
    )
    assert (
        context.client.put(f'/api/folders/{f["id"]}', json={"name": "New name"}).json()[
            "share_allowed"
        ]
        is False
    )
    for base in bases:
        assert context.client.get(f"{base}/media/{mid}/url").status_code == 404
        assert context.client.get(f'{base}/folders/{f["id"]}').status_code == 404
    context.client.put(
        f'/api/folders/{f["id"]}', json={"name": f["name"], "share_allowed": True}
    )
    context.client.put(
        "/api/timeline/days/2024-03-31/sharing", json={"share_allowed": False}
    )
    assert context.client.get("/api/timeline").json()["day_sharing"] == {
        "2024-03-31": False
    }
    for base in bases:
        assert context.client.get(base).json()["days"] == []
        assert context.client.get(f"{base}/media/{mid}/url").status_code == 404
    context.client.put(
        "/api/timeline/days/2024-03-31/sharing", json={"share_allowed": True}
    )
    for base in bases:
        assert context.client.get(f"{base}/media/{mid}/url").status_code == 200


def test_day_permissions_and_removed_selection_contract(context):
    client = context.client
    assert (
        client.post(
            "/api/shares",
            json={
                "start_date": "2024-03-31",
                "end_date": "2024-04-02",
                "exclusions": {"media": [1]},
            },
        ).status_code
        == 422
    )
    client.cookies.set("yearly_session", "viewer")
    client.headers["X-CSRF-Token"] = "csrf-viewer"
    assert (
        client.put(
            "/api/timeline/days/2024-03-31/sharing", json={"share_allowed": False}
        ).status_code
        == 403
    )
    client.cookies.clear()
    assert (
        client.put(
            "/api/timeline/days/2024-03-31/sharing", json={"share_allowed": False}
        ).status_code
        == 401
    )


def test_backup_preserves_content_and_day_sharing_permissions(context):
    import json
    from sqlalchemy import delete
    from app.backup import TABLES, restore_manifest
    from app.models import UploadTask

    mid = upload(context)["media_id"]
    context.client.put(f"/api/media/{mid}", json={"share_allowed": False})
    context.client.put(
        "/api/timeline/days/2024-03-31/sharing", json={"share_allowed": False}
    )
    document = context.client.get("/api/export/manifest").json()
    assert document["tables"]["media"][0]["share_allowed"] is False
    assert document["tables"]["timeline_day"] == [
        {"timeline_date": "2024-03-31", "share_allowed": False}
    ]
    target = context.tmp_path / "sharing-backup.json"
    target.write_text(json.dumps(document))
    with context.db() as db:
        db.execute(delete(UploadTask))
        for model in reversed(TABLES):
            db.execute(delete(model))
        db.commit()
    restore_manifest(target, 1)
    assert context.client.get(f"/api/media/{mid}").json()["share_allowed"] is False
    assert (
        context.client.get("/api/timeline").json()["day_sharing"]["2024-03-31"] is False
    )


def test_public_signing_cannot_cross_share_ranges_or_choose_another_object(
    context, monkeypatch
):
    from unittest.mock import Mock

    allowed = upload(context)
    other = upload(context, taken="2024-04-02T12:00:00")
    one = share(context, start_date="2024-03-31", end_date="2024-03-31")
    two = share(context, start_date="2024-04-02", end_date="2024-04-02")
    signer = Mock(wraps=context.storage.image_url)
    monkeypatch.setattr(context.storage, "image_url", signer)
    base = public(context, one)
    for suffix in ["", "?purpose=thumbnail", "?live=true"]:
        assert (
            context.client.get(
                f'{base}/media/{other["media_id"]}/url{suffix}'
            ).status_code
            == 404
        )
    assert signer.call_count == 0
    # Client-supplied file identifiers, object paths and download flags cannot choose the signed object.
    result = context.client.get(
        f'{base}/media/{allowed["media_id"]}/url?fid={other["tasks"][0]["file_id"]}&object_key=elsewhere.jpg&download=true'
    )
    assert result.status_code == 200
    assert signer.call_args.args[0].id == allowed["tasks"][0]["file_id"]
    assert signer.call_args.args[1] == "preview"
    assert signer.call_args.kwargs["expires"] <= 60
    other_base = "/api/public/shares/" + two["token"]
    assert (
        context.client.get(f'{other_base}/media/{allowed["media_id"]}/url').status_code
        == 404
    )
    # A share token never authenticates the private original-download route.
    assert (
        context.client.get(
            f'/api/media/{allowed["media_id"]}/files/{allowed["tasks"][0]["file_id"]}/url?purpose=original&token={one["token"]}'
        ).status_code
        == 401
    )
