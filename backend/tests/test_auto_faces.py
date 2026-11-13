import math
from sqlalchemy import select
from app.config import settings
from app.face_engine import MODEL_VERSION
from app.models import MediaFace, MediaFaceIndex, Media, MediaChild
from conftest import child
from test_faces import image_media, face, confirm
from test_accounts import act


def indexed(context, mid, vector, person=None, frame_seconds=None):
    actor = context.client.get("/api/auth/me").json()["id"]
    with context.db() as db:
        if db.get(MediaFaceIndex, mid) is None:
            db.add(MediaFaceIndex(media_id=mid, model=MODEL_VERSION, source_sha256="a" * 64))
        db.flush()
        row = MediaFace(
            media_id=mid,
            **face(vector),
            child_id=person,
            confirmed_by=actor if person else None,
        )
        row.frame_seconds = frame_seconds
        db.add(row)
        db.commit()
        return row.id


def test_each_confirmation_links_other_photos_and_video_frames_with_legacy_bulk_payload(context, monkeypatch):
    monkeypatch.setattr(settings(), "face_auto_link_enabled", True)
    person = child(context, "家人")
    video = image_media(context)
    with context.db() as db:
        db.get(Media, video).media_type = "video"
        db.commit()
    seed = indexed(context, video, [1, 0], frame_seconds=0)
    related = indexed(context, video, [.9, math.sqrt(.19)], frame_seconds=5)
    same_frame = indexed(context, video, [1, 0], frame_seconds=0)
    unrelated = indexed(context, video, [0, 1], frame_seconds=5)
    other_photo = image_media(context)
    other_face = indexed(context, other_photo, [.92, math.sqrt(1-.92**2)])
    response = context.client.put(f"/api/faces/media/{video}/confirm", json={"assignments": [
        dict(face_id=seed, child_id=person["id"], ignored=False),
        *[dict(face_id=fid, child_id=None, ignored=False) for fid in [related, same_frame, unrelated]],
    ]})
    assert response.status_code == 200
    assert response.json()["auto_linked"] == 2
    assert response.json()["auto_reset"] == 0
    with context.db() as db:
        for fid in [related, other_face]:
            row = db.get(MediaFace, fid)
            assert row.child_id == person["id"] and row.confirmed_by is None
            assert row.auto_reference_face_id == seed and not row.auto_link_blocked
        for fid in [same_frame, unrelated]:
            row = db.get(MediaFace, fid)
            assert row.child_id is None and not row.auto_link_blocked
    assert context.client.get(f"/api/media/{other_photo}").json()["child_ids"] == [person["id"]]
    assert confirm(context, video, related).status_code == 200
    assert context.client.post("/api/faces/auto-link").json()["linked_faces"] == 0
    with context.db() as db:
        assert db.get(MediaFace, related).child_id is None and db.get(MediaFace, related).auto_link_blocked


def test_same_photo_does_not_transfer_one_person_to_other_faces(context, monkeypatch):
    monkeypatch.setattr(settings(), "face_auto_link_enabled", True)
    person = child(context)
    photo = image_media(context)
    seed = indexed(context, photo, [1, 0])
    other = indexed(context, photo, [1, 0])
    assert confirm(context, photo, seed, person["id"]).json()["auto_linked"] == 0
    with context.db() as db:
        assert db.get(MediaFace, other).child_id is None


def test_high_match_links_preserve_manual_people_do_not_self_seed_and_can_be_undone(
    context, monkeypatch
):
    monkeypatch.setattr(settings(), "face_auto_link_enabled", True)
    a, other = child(context, "参考人物"), child(context, "手动关联人物")
    seed = image_media(context)
    seed_face = indexed(context, seed, [1, 0], a["id"])
    target = image_media(context, [other["id"]])
    fid = indexed(context, target, [0.9, math.sqrt(0.19)])
    chained = image_media(context)
    indexed(context, chained, [0.8, 0.6])
    response = context.client.post("/api/faces/auto-link")
    assert response.status_code == 200
    assert response.json()["linked_faces"] == 1
    with context.db() as db:
        row = db.get(MediaFace, fid)
        assert row.child_id == a["id"] and row.confirmed_by is None
        assert (
            row.auto_reference_face_id == seed_face
            and float(row.auto_match_score) == 0.9
        )
    assert set(context.client.get(f"/api/media/{target}").json()["child_ids"]) == {
        a["id"],
        other["id"],
    }
    assert context.client.post("/api/faces/auto-link").json()["linked_faces"] == 0
    assert (
        context.client.get(f"/api/faces/media/{chained}").json()["faces"][0]["child_id"]
        is None
    )
    assert confirm(context, target, fid).status_code == 200
    assert context.client.post("/api/faces/auto-link").json()["linked_faces"] == 0
    assert context.client.get(f"/api/media/{target}").json()["child_ids"] == [
        other["id"]
    ]
    with context.db() as db:
        assert db.get(MediaFace, fid).auto_link_blocked


def test_close_competitors_low_matches_ignored_and_same_photo_remain_pending(
    context, monkeypatch
):
    monkeypatch.setattr(settings(), "face_auto_link_enabled", True)
    a, b = child(context, "甲"), child(context, "乙")
    seed = image_media(context)
    indexed(context, seed, [1, 0], a["id"])
    second = image_media(context)
    indexed(context, second, [0.99, math.sqrt(1 - 0.99**2)], b["id"])
    target = image_media(context)
    fid = indexed(context, target, [1, 0])
    low = image_media(context)
    indexed(context, low, [0, 1])
    assert context.client.post("/api/faces/auto-link").json()["linked_faces"] == 0
    act(context, "member")
    assert context.client.post("/api/faces/auto-link").status_code == 403


def test_disabled_is_noop_and_manual_review_promotes_automatic_face_to_reference(
    context, monkeypatch
):
    a = child(context)
    seed = image_media(context)
    indexed(context, seed, [1, 0], a["id"])
    target = image_media(context)
    fid = indexed(context, target, [0.9, math.sqrt(0.19)])
    chained = image_media(context)
    indexed(context, chained, [0.8, 0.6])
    assert context.client.post("/api/faces/auto-link").json()["linked_faces"] == 0
    monkeypatch.setattr(settings(), "face_auto_link_enabled", True)
    assert context.client.post("/api/faces/auto-link").json()["linked_faces"] == 1
    reviewed = confirm(context, target, fid, a["id"])
    assert reviewed.status_code == 200
    assert reviewed.json()["auto_linked"] == 1
    with context.db() as db:
        row = db.get(MediaFace, fid)
        assert row.confirmed_by is not None and row.auto_match_score is None


def test_correcting_or_clearing_a_reference_reconciles_automatic_links(context, monkeypatch):
    monkeypatch.setattr(settings(), "face_auto_link_enabled", True)
    a, b = child(context, "甲"), child(context, "乙")
    seed = image_media(context)
    seed_face = indexed(context, seed, [1, 0], a["id"])
    target = image_media(context)
    fid = indexed(context, target, [.9, math.sqrt(.19)])
    assert context.client.post("/api/faces/auto-link").json()["linked_faces"] == 1
    corrected = confirm(context, seed, seed_face, b["id"])
    assert corrected.status_code == 200 and corrected.json()["auto_linked"] == 1
    assert context.client.get(f"/api/media/{target}").json()["child_ids"] == [b["id"]]
    assert context.client.delete(f"/api/faces/media/{seed}").status_code == 200
    assert context.client.get(f"/api/media/{target}").json()["child_ids"] == []
    with context.db() as db:
        row = db.get(MediaFace, fid)
        assert row.child_id is None and row.auto_match_score is None and not row.auto_link_blocked


def test_new_competing_reference_reverts_existing_ambiguous_automatic_link(context, monkeypatch):
    monkeypatch.setattr(settings(), "face_auto_link_enabled", True)
    a, b = child(context, "甲"), child(context, "乙")
    seed = image_media(context); indexed(context, seed, [1, 0], a["id"])
    target = image_media(context); indexed(context, target, [1, 0])
    assert context.client.post("/api/faces/auto-link").json()["linked_faces"] == 1
    second = image_media(context); indexed(context, second, [.99, math.sqrt(1-.99**2)], b["id"])
    summary = context.client.post("/api/faces/auto-link").json()
    assert summary["reset_faces"] == 1
    assert context.client.get(f"/api/media/{target}").json()["child_ids"] == []
