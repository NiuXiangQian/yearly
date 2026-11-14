import json

from sqlalchemy import delete
from app.backup import TABLES, restore_manifest
from app.models import UploadTask
from conftest import child, upload
from test_pets import pet


def person(context, name="林先生", relationship="爸爸", **fields):
    response = context.client.post(
        "/api/children",
        json={
            "name": name,
            "profile_type": "person",
            "relationship": relationship,
            **fields,
        },
    )
    assert response.status_code == 200, response.text
    return response.json()


def test_people_relationships_optional_birthdays_and_edit(context):
    client = context.client
    dad = person(context)
    mom = person(context, "林女士", "妈妈", birthday="1990-08-01")
    person(context, "林爷爷", "爷爷")
    person(context, "林奶奶", "奶奶")
    person(context, "小姨", "家里的摄影师")
    child(context)
    person(context, "小禾", "孩子")
    p = pet(context)
    assert dad["birthday"] is None
    assert client.get(f"/api/children/{dad['id']}/milestones").json() == []
    updated = client.put(
        f"/api/children/{mom['id']}", json={**mom, "name": "妈妈", "birthday": "1990-08-01"}
    ).json()
    assert updated["profile_type"] == "person" and updated["relationship"] == "妈妈"
    stats = client.get("/api/stats").json()
    assert (stats["people"], stats["children"], stats["pets"]) == (7, 2, 1)
    assert p["species"] == "猫"
    assert (
        client.post(
            "/api/children",
            json={"name": "父亲", "profile_type": "person", "relationship": "x" * 81},
        ).status_code
        == 422
    )
    assert (
        client.post(
            "/api/children",
            json={"name": "父亲", "profile_type": "person", "birthday": "2999-01-01"},
        ).status_code
        == 422
    )


def test_file_cast_people_and_pets_in_upload_edit_batch_and_journal(context):
    client = context.client
    a, dad, mom, p = (
        child(context),
        person(context),
        person(context, "林女士", "妈妈"),
        pet(context),
    )
    mid = upload(context, [a["id"], dad["id"], p["id"]])["media_id"]
    cast = [a["id"], dad["id"], mom["id"], p["id"]]
    assert client.put(f"/api/media/{mid}", json={"child_ids": cast}).status_code == 200
    eid = client.post(
        "/api/events",
        json={
            "title": "全家合影",
            "child_ids": cast,
            "media_ids": [mid],
            "start_at": "2024-03-31T10:30:00",
        },
    ).json()["id"]
    for ids, match in [
        ([dad["id"]], "any"),
        ([p["id"]], "any"),
        (cast, "any"),
        (cast, "all"),
    ]:
        result = client.get(
            "/api/timeline", params=[("child_id", i) for i in ids] + [("match", match)]
        ).json()
        assert result["total"] == 2
        assert {(i["kind"], i["id"]) for i in result["items"]} == {
            ("media", mid),
            ("event", eid),
        }
    assert (
        client.post(
            "/api/media/batch-children",
            json={"media_ids": [mid], "child_ids": [mom["id"]], "mode": "remove"},
        ).status_code
        == 200
    )
    assert set(client.get(f"/api/media/{mid}").json()["child_ids"]) == set(cast) - {
        mom["id"]
    }
    assert (
        client.post(
            "/api/media/batch-children",
            json={"media_ids": [mid], "child_ids": [mom["id"]], "mode": "add"},
        ).status_code
        == 200
    )
    assert len(context.storage.objects) == 1
    assert (
        client.delete(
            f"/api/children/{dad['id']}", params={"confirm_name": dad["name"]}
        ).status_code
        == 200
    )
    assert set(client.get(f"/api/media/{mid}").json()["child_ids"]) == set(cast) - {
        dad["id"]
    }
    assert set(client.get(f"/api/events/{eid}").json()["child_ids"]) == set(cast) - {
        dad["id"]
    }
    assert len(context.storage.objects) == 1


def test_person_relationship_and_pet_category_backup_roundtrip(context):
    a, dad, p = child(context), person(context), pet(context)
    mid = upload(context, [a["id"], dad["id"], p["id"]])["media_id"]
    document = context.client.get("/api/export/manifest").json()
    target = context.tmp_path / "people.json"
    target.write_text(json.dumps(document))
    with context.db() as db:
        db.execute(delete(UploadTask))
        for model in reversed(TABLES):
            db.execute(delete(model))
        db.commit()
    restore_manifest(target, 1)
    restored = {p["id"]: p for p in context.client.get("/api/children").json()}
    assert restored[dad["id"]]["relationship"] == "爸爸"
    assert restored[dad["id"]]["birthday"] is None
    assert restored[dad["id"]]["profile_type"] == "person"
    assert restored[p["id"]]["species"] == "猫"
    assert set(context.client.get(f"/api/media/{mid}").json()["child_ids"]) == {
        a["id"],
        dad["id"],
        p["id"],
    }


def test_person_profile_does_not_become_public_in_shared_media(context):
    from test_shares import share, public

    dad = person(context)
    mid = upload(context, [dad["id"]])["media_id"]
    response = context.client.get(public(context, share(context)))
    assert response.status_code == 200
    assert response.json()["days"][0]["items"][0]["id"] == mid
    assert dad["name"] not in response.text
    assert "relationship" not in response.text and "children" not in response.text
    assert context.client.get("/api/children").status_code == 401
