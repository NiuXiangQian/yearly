"""Person scope is enforced on every public entry point and card resource."""
from datetime import timedelta

import pytest

from app.db import now
from app.models import TimelineShare
from conftest import child, upload
from test_folders import folder
from test_shares import share


def test_person_share_filters_folders_events_and_direct_media_access(context):
    person, other = child(context, "小禾"), child(context, "小满")
    parent, unrelated = folder(context), folder(context, "其他人的相册")
    chosen = upload(context, [person["id"]], folder_id=parent["id"])["media_id"]
    sibling = upload(context, [other["id"]], folder_id=parent["id"])["media_id"]
    upload(context, [other["id"]], folder_id=unrelated["id"])
    event = context.client.post("/api/events", json={"title": "小禾的记录", "start_at": "2024-03-31T12:00:00", "child_ids": [person["id"]]}).json()
    context.client.post("/api/events", json={"title": "其他记录", "start_at": "2024-03-31T13:00:00", "child_ids": [other["id"]]})
    data = share(context, profile_id=person["id"])
    assert data["card_title"] == "小禾的时光"
    copied = context.client.post(f'/api/shares/{data["id"]}/copy', json={"hours": 1}).json()
    assert copied["profile_id"] == person["id"]
    base = "/api/public/shares/" + data["token"]
    context.client.cookies.clear()
    items = context.client.get(base).json()["days"][0]["items"]
    assert {(item["kind"], item["id"]) for item in items} == {("folder", parent["id"]), ("event", event["id"])}
    assert next(item for item in items if item["kind"] == "folder")["media_count"] == 1
    assert [item["id"] for item in context.client.get(f'{base}/folders/{parent["id"]}').json()["items"]] == [chosen]
    assert context.client.get(f'{base}/folders/{unrelated["id"]}').status_code == 404
    assert context.client.get(f"{base}/media/{sibling}/url").status_code == 404
    assert context.client.get(f"{base}/media/{chosen}/url").status_code == 200


def test_person_selection_intersects_explicit_media_and_validates_profile(context):
    person, other = child(context, "小禾"), child(context, "小满")
    chosen = upload(context, [person["id"]])["media_id"]
    excluded = upload(context, [other["id"]])["media_id"]
    result = context.client.post("/api/shares", json={"media_ids": [chosen, excluded], "profile_id": person["id"]}).json()
    body = context.client.get("/api/public/shares/" + result["token"]).json()
    assert [item["id"] for item in body["days"][0]["items"]] == [chosen]
    assert context.client.post("/api/shares", json={"media_ids": [chosen], "profile_id": 999999999}).status_code == 422


@pytest.mark.parametrize("unavailable", ["revoked", "expired"])
def test_person_metadata_and_avatar_follow_link_expiry_and_escape_titles(context, unavailable):
    avatar = upload(context)["media_id"]
    person = child(context, '小禾 <script>')
    updated = context.client.put(f'/api/children/{person["id"]}', json={
        "name": person["name"], "birthday": person["birthday"], "avatar_media_id": avatar,
    })
    assert updated.status_code == 200, updated.text
    data = share(context, profile_id=person["id"], title='相册 " <测试>')
    base = "/api/public/shares/" + data["token"]
    page = context.client.get(base + "/page")
    assert page.status_code == 200
    assert "小禾 &lt;script&gt; · 相册 &quot; &lt;测试&gt;" in page.text
    assert f'{base}/avatar' in page.text
    assert '/share-entry.js' in page.text
    assert '<script>' not in page.text
    assert context.client.get(base + "/avatar", follow_redirects=False).status_code == 302
    assert context.client.get(base + "/avatar?redirect=false").json()["url"] == "https://private.invalid/thumbnail"
    assert context.storage.last_expiry <= 60
    with context.db() as db:
        record = db.get(TimelineShare, data["id"])
        if unavailable == "revoked":
            record.revoked = True
        else:
            record.expires_at = now() - timedelta(seconds=1)
        db.commit()
    assert context.client.get(base + "/page").status_code == 404
    assert context.client.get(base + "/avatar", follow_redirects=False).status_code == 404
