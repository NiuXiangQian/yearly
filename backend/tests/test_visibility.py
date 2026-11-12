from types import SimpleNamespace
import pytest
from sqlalchemy import select
from app.models import Event, EventMedia, Media
from conftest import upload
from test_accounts import act
from test_folders import folder


@pytest.fixture
def content(context):
    act(context, "member")
    client = context.client
    visible = upload(context)["media_id"]
    private = upload(context)["media_id"]
    public_folder = folder(context, "可见文件夹")
    private_folder = folder(context, "私密文件夹")
    day_folder = folder(context, "私密日期文件夹", day="2024-04-01")
    member = upload(context)["media_id"]
    private_member = upload(context)["media_id"]
    inherited_folder = upload(context)["media_id"]
    inherited_day = upload(context, timeline_date="2024-04-01")["media_id"]
    unknown = upload(context, taken=None)["media_id"]
    for fid, mids in [(public_folder["id"], [member, private_member]), (private_folder["id"], [inherited_folder])]:
        assert client.post("/api/folders/move-media", json={"folder_id": fid, "media_ids": mids}).status_code == 200
    event = client.post("/api/events", json={
        "title": "可见日记", "start_at": "2024-03-31T12:00:00",
        "media_ids": [visible, private], "cover_media_id": private,
    }).json()["id"]
    private_event = client.post("/api/events", json={
        "title": "私密日记", "start_at": "2024-03-31T13:00:00", "share_allowed": False,
    }).json()["id"]
    day_event = client.post("/api/events", json={
        "title": "私密日期日记", "start_at": "2024-04-01T13:00:00",
    }).json()["id"]
    # These are the member's own records: ownership must not override visibility.
    for mid in [private, private_member]:
        assert client.put(f"/api/media/{mid}", json={"title": "不可分享的影像", "share_allowed": False}).status_code == 200
    assert client.put(f"/api/folders/{private_folder['id']}", json={"name": private_folder["name"], "share_allowed": False}).status_code == 200
    act(context, "admin")
    assert client.put("/api/timeline/days/2024-04-01/sharing", json={"share_allowed": False}).status_code == 200
    with context.db() as db:
        files = {m.id: m.files[0].id for m in db.scalars(select(Media))}
    return SimpleNamespace(
        visible=[visible, member, unknown], private=[private, private_member, inherited_folder, inherited_day],
        public_folder=public_folder["id"], private_folders=[private_folder["id"], day_folder["id"]],
        event=event, private_events=[private_event, day_event], files=files,
    )


@pytest.mark.parametrize("role", ["member", "viewer"])
def test_non_admin_lists_counts_dates_and_folder_previews(context, content, role):
    act(context, role)
    client = context.client
    media = client.get("/api/media?page_size=100").json()
    assert media["total"] == len(content.visible)
    assert {m["id"] for m in media["items"]} == set(content.visible)
    assert client.get("/api/media?q=不可分享").json()["total"] == 0
    for basis in ["timeline", "capture", "upload"]:
        page = client.get(f"/api/timeline?date_basis={basis}&include_dates=true&page_size=100&media_positions=true").json()
        assert {m["id"] for m in page["items"] if m["kind"] == "media"} == set(content.visible)
        assert page["total"] == len(content.visible) + (basis != "upload")
        if basis != "upload":assert "2024-04-01" not in page["dates"]
    grouped = client.get("/api/timeline?group_folders=true&include_dates=true").json()
    folders = [f for f in grouped["items"] if f["kind"] == "folder"]
    assert [f["id"] for f in folders] == [content.public_folder]
    assert folders[0]["media_count"] == 1
    assert [m["id"] for m in folders[0]["previews"]] == [content.visible[1]]
    assert client.get(f"/api/folders/{content.public_folder}").json()["media_count"] == 1
    listed = client.get("/api/folders?day=2024-03-31").json()
    assert [(f["id"], f["media_count"]) for f in listed] == [(content.public_folder, 1)]
    assert client.get("/api/folders?day=2024-04-01").json() == []
    assert client.get("/api/events").json()["total"] == 1
    event = client.get(f"/api/events/{content.event}").json()
    assert event["media_ids"] == [content.visible[0]]
    assert [m["id"] for m in event["media"]] == [content.visible[0]]
    assert event["cover_media_id"] is None
    stats = client.get("/api/stats").json()
    assert stats["media"] == len(content.visible)
    assert stats["events"] == 1
    assert stats["bytes"] == 16 * len(content.visible)
    # Pagination totals and continuation must use the filtered set.
    first = client.get("/api/timeline?page_size=1").json()
    seen = [(m["kind"], m["id"]) for m in first["items"]]
    while first["next_cursor"]:
        first = client.get("/api/timeline", params={"page_size": 1, "cursor": first["next_cursor"]}).json()
        seen.extend((m["kind"], m["id"]) for m in first["items"])
    assert len(seen) == len(set(seen)) == len(content.visible) + 1


@pytest.mark.parametrize("role", ["member", "viewer"])
def test_non_admin_direct_metadata_previews_originals_and_history(context, content, role):
    act(context, role)
    client = context.client
    for mid in content.private:
        for path in [
            f"/api/media/{mid}",
            *[f"/api/media/{mid}/files/{content.files[mid]}/url?purpose={purpose}" for purpose in ["thumbnail", "preview", "original"]],
        ]:
            assert client.get(path).status_code == 404, path
        assert client.post(f"/api/media/{mid}/files/{content.files[mid]}/restore", json={}).status_code == 404
        assert client.get(f"/api/audit-logs?resource_type=media&resource_id={mid}").json()["items"] == []
    for fid in content.private_folders:
        assert client.get(f"/api/folders/{fid}").status_code == 404
        assert client.get(f"/api/media?folder_id={fid}").status_code == 404
    for eid in content.private_events:
        assert client.get(f"/api/events/{eid}").status_code == 404
    assert client.get(f"/api/timeline?anchor_media_id={content.private[0]}").status_code == 404
    assert client.get(f"/api/media/{content.visible[0]}").status_code == 200


def test_admin_retains_access_and_non_admin_cannot_unhide_or_reassociate(context, content):
    client = context.client
    assert client.get("/api/media").json()["total"] == 7
    assert client.get("/api/events").json()["total"] == 3
    for mid in content.private:
        assert client.get(f"/api/media/{mid}").status_code == 200
        assert client.get(f"/api/media/{mid}/files/{content.files[mid]}/url?purpose=original").status_code == 200
    for fid in content.private_folders:
        assert client.get(f"/api/folders/{fid}").status_code == 200
    event = client.get(f"/api/events/{content.event}").json()
    assert event["cover_media_id"] == content.private[0]
    assert event["media_ids"] == [content.visible[0], content.private[0]]
    act(context, "member")
    mid = content.private[0]
    assert client.put(f"/api/media/{mid}", json={"share_allowed": True}).status_code == 404
    assert client.delete(f"/api/media/{mid}").status_code == 404
    assert client.post("/api/folders/move-media", json={"media_ids": [mid]}).status_code == 404
    assert client.post("/api/media/batch-organize", json={"media_ids": [mid], "batch_name": "rescue"}).status_code == 404
    assert client.put(f"/api/folders/{content.private_folders[0]}", json={"name": "rescue", "share_allowed": True}).status_code == 404
    assert client.post("/api/events", json={"title": "rescue", "media_ids": [mid]}).status_code == 422
    assert client.put(f"/api/events/{content.event}", json={"title": "改标题", "media_ids": [content.visible[0]]}).status_code == 200
    with context.db() as db:
        assert set(db.scalars(select(EventMedia.media_id).where(EventMedia.event_id == content.event))) == {content.visible[0], mid}
        assert db.get(Media, mid).share_allowed is False
        assert db.get(Event, content.event).cover_media_id == mid
    act(context, "admin")
    assert client.put(f"/api/media/{mid}", json={"share_allowed": True}).status_code == 200
    act(context, "member")
    assert client.get(f"/api/media/{mid}").status_code == 200
