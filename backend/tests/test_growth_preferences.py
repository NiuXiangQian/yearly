import json
import pytest
from sqlalchemy import delete
from app.backup import TABLES, restore_manifest
from app.models import UploadTask
from conftest import child, upload
from test_people import person
from test_pets import pet


def test_growth_defaults_and_filter_only_people(context):
    client = context.client
    kid = child(context)
    dad = person(context, birthday="1990-01-01")
    dog = pet(context, birthday="2023-01-01")
    new_kid = person(context, "小禾", "孩子", birthday="2024-01-01")
    assert [p["growth_enabled"] for p in (kid, dad, dog, new_kid)] == [
        True,
        False,
        True,
        True,
    ]
    ids = [kid["id"], dad["id"], dog["id"]]
    mid = upload(context, ids)["media_id"]
    eid = client.post(
        "/api/events",
        json={
            "title": "合影",
            "child_ids": ids,
            "media_ids": [mid],
            "start_at": "2024-03-31T12:00:00",
            "end_at": "2024-04-01T12:00:00",
        },
    ).json()["id"]
    media = client.get(f"/api/media/{mid}").json()
    ages = {p["id"]: p["age"] for p in media["children"]}
    assert ages[dad["id"]] is None
    assert ages[kid["id"]] and ages[dog["id"]]
    event = client.get(f"/api/events/{eid}").json()
    father = next(p for p in event["children"] if p["id"] == dad["id"])
    assert father["age_start"] is None and father["age_end"] is None
    assert client.get(f"/api/children/{dad['id']}/milestones").json() == []
    assert client.get(f"/api/timeline?child_id={dad['id']}").json()["total"] == 2
    assert (
        client.get(
            f"/api/timeline?child_id={dad['id']}&child_id={kid['id']}&match=all"
        ).json()["total"]
        == 2
    )


def test_toggle_growth_preserves_associations(context):
    client = context.client
    dog = pet(context, birthday="2023-01-01", growth_enabled=False)
    mid = upload(context, [dog["id"]])["media_id"]
    assert client.get(f"/api/children/{dog['id']}/milestones").json() == []
    result = client.put(f"/api/children/{dog['id']}", json=dog).json()
    assert result["growth_enabled"] is False
    result = client.put(
        f"/api/children/{dog['id']}", json={**result, "growth_enabled": True}
    ).json()
    assert client.get(f"/api/children/{dog['id']}/milestones").json()
    assert client.get(f"/api/media/{mid}").json()["children"][0]["age"]
    result = client.put(
        f"/api/children/{dog['id']}", json={**result, "growth_enabled": False}
    ).json()
    media = client.get(f"/api/media/{mid}").json()
    assert media["child_ids"] == [dog["id"]] and media["children"][0]["age"] is None
    assert len(context.storage.objects) == 1
    assert person(context, growth_enabled=True)["growth_enabled"] is True


@pytest.mark.parametrize("legacy", [False, True])
def test_growth_setting_backup_current_schema_and_reject_missing_fields(context, legacy):
    kid = child(context)
    dad = person(context, growth_enabled=True)
    dog = pet(context, growth_enabled=False)
    mid = upload(context, [kid["id"], dad["id"], dog["id"]])["media_id"]
    doc = context.client.get("/api/export/manifest").json()
    if legacy:
        for row in doc["tables"]["child"]:
            row.pop("growth_enabled")
    path = context.tmp_path / "growth.json"
    path.write_text(json.dumps(doc))
    if legacy:
        with pytest.raises(ValueError, match="清单字段"):
            restore_manifest(path, 1)
        return
    with context.db() as db:
        db.execute(delete(UploadTask))
        for model in reversed(TABLES):
            db.execute(delete(model))
        db.commit()
    restore_manifest(path, 1)
    profiles = {p["id"]: p for p in context.client.get("/api/children").json()}
    assert profiles[kid["id"]]["growth_enabled"] is True
    assert profiles[dad["id"]]["growth_enabled"] is True
    assert profiles[dog["id"]]["growth_enabled"] is False
    assert set(context.client.get(f"/api/media/{mid}").json()["child_ids"]) == {
        kid["id"],
        dad["id"],
        dog["id"],
    }
