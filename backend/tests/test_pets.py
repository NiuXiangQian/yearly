"""Pets share original media and journals with children without duplicating either."""
import json

import pytest
from sqlalchemy import delete

from app.backup import TABLES, restore_manifest
from app.models import UploadTask
from conftest import child, upload


def pet(context, **fields):
    response = context.client.post(
        "/api/children",
        json={
            "name": "团子",
            "profile_type": "pet",
            "species": "猫",
            "breed": "英短",
            **fields,
        },
    )
    assert response.status_code == 200, response.text
    return response.json()


def test_pet_optional_birthday_validation_and_edit(context):
    client = context.client
    a = child(context)
    p = pet(context)
    assert a["profile_type"] == "child"
    assert p["birthday"] is None
    assert client.get(f"/api/children/{p['id']}/milestones").json() == []
    assert client.post("/api/children", json={"name": "宝宝"}).status_code == 422
    assert (
        client.post(
            "/api/children", json={"name": "团子", "profile_type": "other"}
        ).status_code
        == 422
    )
    assert (
        client.post(
            "/api/children",
            json={"name": "团子", "profile_type": "pet", "birthday": "2999-01-01"},
        ).status_code
        == 422
    )
    updated = client.put(
        f"/api/children/{p['id']}", json={**p, "birthday": "2023-03-01"}
    ).json()
    assert updated["birthday"] == "2023-03-01"
    assert (
        client.get(f"/api/children/{p['id']}/milestones").json()[0]["date"]
        == "2023-03-01"
    )
    renamed = client.put(
        f"/api/children/{p['id']}", json={**updated, "name": "团团", "birthday": "2023-03-01"}
    ).json()
    assert (renamed["profile_type"], renamed["species"], renamed["breed"]) == (
        "pet",
        "猫",
        "英短",
    )
    stats = client.get("/api/stats").json()
    assert stats["children"] == 1 and stats["pets"] == 1


def test_overlapping_pet_and_child_timelines_and_delete(context):
    client = context.client
    a, p = child(context), pet(context)
    ids = [a["id"], p["id"]]
    mid = upload(context, ids)["media_id"]
    eid = client.post(
        "/api/events",
        json={
            "title": "一起晒太阳",
            "child_ids": ids,
            "media_ids": [mid],
            "start_at": "2024-03-31T10:30:00",
        },
    ).json()["id"]
    for suffix in [
        f"child_id={a['id']}",
        f"child_id={p['id']}",
        f"child_id={a['id']}&child_id={p['id']}&match=any",
        f"child_id={a['id']}&child_id={p['id']}&match=all",
    ]:
        result = client.get("/api/timeline?" + suffix).json()
        assert result["total"] == 2
        assert {(item["kind"], item["id"]) for item in result["items"]} == {
            ("media", mid),
            ("event", eid),
        }
    media = client.get(f"/api/media/{mid}").json()
    assert next(c for c in media["children"] if c["id"] == p["id"])["age"] is None
    event = client.get(f"/api/events/{eid}").json()
    assert next(c for c in event["children"] if c["id"] == p["id"])["age_start"] is None
    assert len(context.storage.objects) == 1
    assert (
        client.delete(
            f"/api/children/{p['id']}", params={"confirm_name": p["name"]}
        ).status_code
        == 200
    )
    assert client.get(f"/api/media/{mid}").json()["child_ids"] == [a["id"]]
    assert client.get(f"/api/events/{eid}").json()["child_ids"] == [a["id"]]
    assert client.get(f"/api/timeline?child_id={a['id']}").json()["total"] == 2
    assert len(context.storage.objects) == 1


def test_pet_batch_link_avatar_and_archive(context):
    client = context.client
    a, p = child(context), pet(context, birthday="2023-03-01")
    mid = upload(context, [a["id"]])["media_id"]
    response = client.post(
        "/api/media/batch-children",
        json={"media_ids": [mid], "child_ids": [p["id"]], "mode": "add"},
    )
    assert response.status_code == 200
    updated = client.put(
        f"/api/children/{p['id']}",
        json={**p, "avatar_media_id": mid, "status": "archived"},
    )
    assert updated.status_code == 200
    assert updated.json()["avatar_media_id"] == mid
    assert client.get("/api/stats").json()["pets"] == 0
    assert client.get(f"/api/timeline?child_id={p['id']}").json()["total"] == 1
    row = client.get(f"/api/media?child_id={p['id']}").json()["items"][0]
    assert row["children"][0]["age"] == "1 岁"


@pytest.mark.parametrize("legacy", [False, True])
def test_profile_backup_current_schema_and_reject_missing_fields(context, legacy):
    a = child(context)
    p = pet(context) if not legacy else None
    ids = [a["id"]] + ([p["id"]] if p else [])
    mid = upload(context, ids)["media_id"]
    document = context.client.get("/api/export/manifest").json()
    if legacy:
        for row in document["tables"]["child"]:
            for key in ("profile_type", "relationship", "species", "breed"):
                row.pop(key)
    target = context.tmp_path / "profiles.json"
    target.write_text(json.dumps(document))
    if legacy:
        with pytest.raises(ValueError, match="清单字段"):
            restore_manifest(target, 1)
        return
    with context.db() as db:
        db.execute(delete(UploadTask))
        for model in reversed(TABLES):
            db.execute(delete(model))
        db.commit()
    restore_manifest(target, 1)
    profiles = {row["id"]: row for row in context.client.get("/api/children").json()}
    assert profiles[a["id"]]["profile_type"] == "child"
    if p:
        assert profiles[p["id"]]["profile_type"] == "pet"
        assert profiles[p["id"]]["species"] == "猫"
        assert profiles[p["id"]]["breed"] == "英短"
        assert profiles[p["id"]]["birthday"] is None
    assert set(context.client.get(f"/api/media/{mid}").json()["child_ids"]) == set(ids)


def test_pet_profiles_keep_role_and_public_sharing_boundaries(context):
    from test_shares import share, public

    client = context.client
    a, p = child(context), pet(context)
    mid = upload(context, [a["id"], p["id"]])["media_id"]
    link = share(context)
    client.cookies.set("yearly_session", "viewer")
    client.headers["X-CSRF-Token"] = "csrf-viewer"
    assert (
        client.post(
            "/api/children", json={"name": "小狗", "profile_type": "pet"}
        ).status_code
        == 403
    )
    assert client.put(f"/api/children/{p['id']}", json=p).status_code == 403
    client.cookies.set("yearly_session", "member")
    client.headers["X-CSRF-Token"] = "csrf-member"
    assert (
        client.delete(
            f"/api/children/{p['id']}", params={"confirm_name": p["name"]}
        ).status_code
        == 403
    )
    base = public(context, link)
    response = client.get(base)
    assert response.status_code == 200
    entry = response.json()["days"][0]["items"][0]
    assert entry["id"] == mid
    assert set(entry) == {"kind", "id", "title", "media_type"}
    assert p["name"] not in response.text and p["breed"] not in response.text
    assert client.get("/api/children").status_code == 401
    assert client.get(f"/api/media/{mid}").status_code == 401
