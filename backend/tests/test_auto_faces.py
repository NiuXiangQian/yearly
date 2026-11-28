import math
import pytest
from sqlalchemy import select
from app.config import settings
from app.faces import auto_link, process_face_work
from app.organization_history import record_identity
from app.face_engine import MODEL_VERSION
from app.models import MediaFace, MediaFaceIndex, Media, MediaChild
from conftest import child
from test_faces import image_media, face, confirm
from test_accounts import act


def indexed(context, mid, vector, person=None, frame_seconds=None):
    actor = context.client.get("/api/auth/me").json()["id"]
    with context.db() as db:
        if db.get(MediaFaceIndex, mid) is None:
            db.add(MediaFaceIndex(media_id=mid, model=MODEL_VERSION, source_sha256=f"{mid:064x}"))
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


def reference_pair(context, person, vector, first=None):
    seed = first or image_media(context)
    first_id = indexed(context, seed, vector, person)
    indexed(context, image_media(context, taken="2024-02-01T10:30:00"), vector, person)
    return first_id


def drain_matching(context):
    actor = context.client.get("/api/auth/me").json()["id"]
    from app.models import User
    with context.db() as db:
        user = db.get(User, actor)
        for _ in range(30):
            if not process_face_work(db, user):
                return
    pytest.fail("queued matching did not finish")


def test_group_confirmation_is_atomic_and_keeps_rejected_candidates_excluded(context):
    person = child(context)
    seed = image_media(context)
    indexed(context, seed, [1, 0], person["id"])
    first_media, second_media, third_media = [image_media(context) for _ in range(3)]
    first, second, third = [indexed(context, mid, [1, 0]) for mid in (first_media, second_media, third_media)]
    queue = context.client.get("/api/faces/review").json()
    assert {item["review_group_id"] for item in queue["items"] if item["id"] in (first, second, third)} == {third}
    response = context.client.put(f"/api/faces/media/{second_media}/confirm", json={
        "assignments": [dict(face_id=second, rejected_child_id=person["id"])]})
    assert response.status_code == 200 and response.json()["faces"][0]["candidates"] == []
    path = "/api/faces/review/confirm-group"
    assert context.client.put(path, json=dict(face_ids=[first, second], child_id=person["id"])).status_code == 409
    assert context.client.get(f"/api/media/{first_media}").json()["child_ids"] == []
    body = dict(face_ids=[first, third], child_id=person["id"])
    assert context.client.put(path, json=body).json()["confirmed"] == 2
    assert context.client.put(path, json=body).json()["confirmed"] == 2
    assert context.client.get(f"/api/media/{second_media}").json()["child_ids"] == []
    act(context, "member")
    assert context.client.put(path, json=body).status_code == 403


def test_one_confirmation_links_prebound_video_frames_and_unbound_photos(context, monkeypatch):
    monkeypatch.setattr(settings(), "face_auto_link_enabled", True)
    person = child(context, "家人")
    video = image_media(context, [person["id"]])
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
    assert response.json()["matching_queued"]
    assert context.client.get(f"/api/media/{other_photo}").json()["child_ids"] == []
    drain_matching(context)
    with context.db() as db:
        row = db.get(MediaFace, other_face)
        assert row.child_id == person["id"] and row.confirmed_by is None
        assert row.auto_reference_face_id is not None and not row.auto_link_blocked
        sibling = db.get(MediaFace, related)
        assert sibling.child_id == person["id"] and not sibling.ignored and sibling.confirmed_by is None
        assert sibling.auto_reference_face_id == seed
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
    assert confirm(context, photo, seed, person["id"]).json()["matching_queued"]
    drain_matching(context)
    with context.db() as db:
        assert db.get(MediaFace, other).child_id is None


def test_high_match_links_preserve_manual_people_do_not_self_seed_and_can_be_undone(
    context, monkeypatch
):
    monkeypatch.setattr(settings(), "face_auto_link_enabled", True)
    a, other = child(context, "参考人物"), child(context, "手动关联人物")
    seed = image_media(context)
    seed_face = reference_pair(context, a["id"], [1, 0], first=seed)
    target = image_media(context, [other["id"]])
    fid = indexed(context, target, [0.9, math.sqrt(0.19)])
    chained = image_media(context)
    indexed(context, chained, [.59, math.sqrt(1 - .59**2)])
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


def test_close_runner_up_and_low_matches_stay_pending(
    context, monkeypatch
):
    monkeypatch.setattr(settings(), "face_auto_link_enabled", True)
    a, b = child(context, "甲"), child(context, "乙")
    seed = image_media(context)
    reference_pair(context, a["id"], [1, 0], first=seed)
    second = image_media(context)
    reference_pair(context, b["id"], [0.99, math.sqrt(1 - 0.99**2)], first=second)
    target = image_media(context)
    fid = indexed(context, target, [1, 0])
    low = image_media(context)
    low_face = indexed(context, low, [0, 1])
    assert context.client.post("/api/faces/auto-link").json()["linked_faces"] == 0
    with context.db() as db:
        assert db.get(MediaFace, fid).child_id is None
        assert db.get(MediaFace, low_face).child_id is None
    act(context, "member")
    assert context.client.post("/api/faces/auto-link").status_code == 403


def test_disabled_is_noop_and_manual_review_promotes_automatic_face_to_reference(
    context, monkeypatch
):
    a = child(context)
    seed = image_media(context)
    reference_pair(context, a["id"], [1, 0], first=seed)
    target = image_media(context)
    fid = indexed(context, target, [0.9, math.sqrt(0.19)])
    chained = image_media(context)
    indexed(context, chained, [.59, math.sqrt(1 - .59**2)])
    assert context.client.post("/api/faces/auto-link").json()["linked_faces"] == 0
    monkeypatch.setattr(settings(), "face_auto_link_enabled", True)
    assert context.client.post("/api/faces/auto-link").json()["linked_faces"] == 1
    reviewed = confirm(context, target, fid, a["id"])
    assert reviewed.status_code == 200
    assert reviewed.json()["matching_queued"]
    drain_matching(context)
    with context.db() as db:
        row = db.get(MediaFace, fid)
        assert row.confirmed_by is not None and row.auto_match_score is None


def test_correcting_or_clearing_a_reference_reconciles_automatic_links(context, monkeypatch):
    monkeypatch.setattr(settings(), "face_auto_link_enabled", True)
    a, b = child(context, "甲"), child(context, "乙")
    seed = image_media(context)
    seed_face = reference_pair(context, a["id"], [1, 0], first=seed)
    target = image_media(context)
    fid = indexed(context, target, [.9, math.sqrt(.19)])
    assert context.client.post("/api/faces/auto-link").json()["linked_faces"] == 1
    corrected = confirm(context, seed, seed_face, b["id"])
    assert corrected.status_code == 200 and corrected.json()["matching_queued"]
    drain_matching(context)
    assert context.client.get(f"/api/media/{target}").json()["child_ids"] == []
    assert context.client.delete(f"/api/faces/media/{seed}").status_code == 200
    drain_matching(context)
    assert context.client.get(f"/api/media/{target}").json()["child_ids"] == []
    with context.db() as db:
        row = db.get(MediaFace, fid)
        assert row.child_id is None and row.auto_match_score is None and not row.auto_link_blocked


def test_stronger_new_reference_reassigns_existing_automatic_link(context, monkeypatch):
    monkeypatch.setattr(settings(), "face_auto_link_enabled", True)
    a, b = child(context, "甲"), child(context, "乙")
    reference_pair(context, a["id"], [.9, math.sqrt(.19)])
    target = image_media(context); indexed(context, target, [1, 0])
    assert context.client.post("/api/faces/auto-link").json()["linked_faces"] == 1
    reference_pair(context, b["id"], [1, 0])
    with context.db() as db:
        assert auto_link(db, None, pending_only=True)["linked_faces"] == 0
        db.commit()
    assert context.client.get(f"/api/media/{target}").json()["child_ids"] == [a["id"]]
    summary = context.client.post("/api/faces/auto-link").json()
    assert summary["linked_faces"] == 1 and summary["reset_faces"] == 0
    assert context.client.get(f"/api/media/{target}").json()["child_ids"] == [b["id"]]


@pytest.mark.parametrize('score,expected', [(.59996, False), (.60, True), (.60001, True), (.61, True)])
def test_face_candidate_and_auto_confirmation_use_the_same_unrounded_threshold(context, monkeypatch, score, expected):
    monkeypatch.setattr(settings(), 'face_auto_link_enabled', True)
    person = child(context)
    reference_pair(context, person['id'], [1, 0])
    target = image_media(context); fid = indexed(context, target, [score, math.sqrt(1-score**2)])
    candidates = context.client.get(f'/api/faces/media/{target}').json()['faces'][0]['candidates']
    assert bool(candidates) is expected
    result = context.client.post('/api/faces/auto-link').json()
    assert result['minimum_similarity'] == .60 and result['minimum_similarity_exclusive'] is False
    assert result['minimum_margin'] == .08 and result['linked_faces'] == int(expected)
    with context.db() as db:
        row = db.get(MediaFace, fid)
        assert row.child_id == (person['id'] if expected else None)
        assert row.confirmed_by is None


def test_hidden_close_runner_up_still_prevents_automatic_confirmation(context, monkeypatch):
    monkeypatch.setattr(settings(), 'face_auto_link_enabled', True)
    first, runner_up = child(context, '甲'), child(context, '乙')
    for person, score in [(first, .62), (runner_up, .57)]:
        indexed(context, image_media(context), [score, math.sqrt(1 - score**2)], person['id'])
    target = image_media(context)
    indexed(context, target, [1, 0])
    candidates = context.client.get(f'/api/faces/media/{target}').json()['faces'][0]['candidates']
    assert [candidate['child_id'] for candidate in candidates] == [first['id']]
    assert context.client.post('/api/faces/auto-link').json()['linked_faces'] == 0


def test_qualifying_reference_is_preferred_to_nearby_reference_below_cutoff(context):
    person = child(context)
    close_date = image_media(context, taken='2024-05-01T10:30:00')
    earlier_date = image_media(context, taken='2023-05-01T10:30:00')
    indexed(context, close_date, [.59, math.sqrt(1 - .59**2)], person['id'])
    indexed(context, earlier_date, [.60, .8], person['id'])
    target = image_media(context, taken='2024-05-02T10:30:00')
    indexed(context, target, [1, 0])
    candidates = context.client.get(f'/api/faces/media/{target}').json()['faces'][0]['candidates']
    assert candidates[0]['reference_media_id'] == earlier_date and candidates[0]['similarity'] == .60


def test_exactly_tied_people_require_manual_review(context, monkeypatch):
    monkeypatch.setattr(settings(), 'face_auto_link_enabled', True)
    for name in ['甲', '乙']:
        person = child(context, name)
        indexed(context, image_media(context), [1, 0], person['id'])
    target = image_media(context); fid = indexed(context, target, [1, 0])
    assert context.client.post('/api/faces/auto-link').json()['linked_faces'] == 0
    with context.db() as db:
        assert db.get(MediaFace, fid).child_id is None


def test_excluded_person_is_not_matched_and_existing_face_and_media_links_survive(context, monkeypatch):
    monkeypatch.setattr(settings(), 'face_auto_link_enabled', True)
    excluded, other = child(context, '默认绑定人物'), child(context, '其他家人')
    reference_pair(context, excluded['id'], [1, 0])
    previous = image_media(context); old_face = indexed(context, previous, [1, 0])
    assert context.client.post('/api/faces/auto-link').json()['linked_faces'] == 1
    reference_pair(context, other['id'], [.9, math.sqrt(.19)])
    target = image_media(context, [excluded['id']]); new_face = indexed(context, target, [.8, .6])
    excluded_target = image_media(context, [excluded['id']]); excluded_face = indexed(context, excluded_target, [1, 0])
    options = context.client.get('/api/organization/settings').json()
    options['face_excluded_child_ids'] = [excluded['id']]
    options['person_rules'][str(excluded['id'])] = 'automatic'
    assert context.client.put('/api/organization/settings', json=options).status_code == 200
    candidates = context.client.get(f'/api/faces/media/{target}').json()['faces'][0]['candidates']
    assert [c['child_id'] for c in candidates] == [other['id']]
    assert context.client.get(f'/api/faces/media/{excluded_target}').json()['faces'][0]['candidates'] == []
    summary = context.client.post('/api/faces/auto-link').json()
    assert summary['linked_faces'] == 1 and summary['reset_faces'] == 0
    with context.db() as db:
        assert db.get(MediaFace, old_face).child_id == excluded['id']
        assert db.get(MediaFace, old_face).auto_match_score is not None
        assert db.get(MediaFace, new_face).child_id == other['id']
        assert db.get(MediaFace, excluded_face).child_id is None
    assert context.client.get(f'/api/media/{previous}').json()['child_ids'] == [excluded['id']]
    assert set(context.client.get(f'/api/media/{target}').json()['child_ids']) == {excluded['id'], other['id']}


@pytest.mark.parametrize('score,linked', [(.55, False), (.95, True)])
def test_match_confirms_face_without_duplicate_album_bindings(context, monkeypatch, score, linked):
    monkeypatch.setattr(settings(), 'face_auto_link_enabled', True)
    person = child(context)
    indexed(context, image_media(context), [1, 0], person['id'])
    target = image_media(context, [person['id']])
    fid = indexed(context, target, [score, math.sqrt(1-score**2)])
    before = context.client.get(f'/api/media/{target}').json()['child_ids']
    candidates = context.client.get(f'/api/faces/media/{target}').json()['faces'][0]['candidates']
    assert [candidate['child_id'] for candidate in candidates] == ([person['id']] if linked else [])
    assert context.client.post('/api/faces/auto-link').json()['linked_faces'] == int(linked)
    with context.db() as db:
        row = db.get(MediaFace, fid)
        assert not row.ignored and row.confirmed_by is None
        assert row.child_id == (person['id'] if linked else None)
    assert context.client.get(f'/api/media/{target}').json()['child_ids'] == before
    assert context.client.get('/api/faces/review').json()['pending_faces'] == int(not linked)
    assert context.client.post('/api/faces/auto-link').json()['linked_faces'] == 0


@pytest.mark.parametrize('both_bound', [False, True])
def test_tied_suggestions_remain_available_for_review(context, monkeypatch, both_bound):
    monkeypatch.setattr(settings(), 'face_auto_link_enabled', True)
    a, b = child(context, '甲'), child(context, '乙')
    for person in [a, b]:indexed(context, image_media(context), [1, 0], person['id'])
    target = image_media(context, [a['id'], b['id']] if both_bound else [a['id']])
    fid = indexed(context, target, [1, 0])
    context.client.post('/api/faces/auto-link')
    with context.db() as db:
        row = db.get(MediaFace, fid)
        assert not row.ignored and row.child_id is None


def previously_ignored(context, face_id, person_id):
    with context.db() as db:
        face = db.get(MediaFace, face_id)
        face.ignored = True
        record_identity(db, face.media_id, "face", str(face_id),
            dict(child_id=None, ignored=False), dict(child_id=None, ignored=True), automatic=True,
            evidence=dict(already_bound_child_ids=[person_id]))
        db.commit()


def test_reopening_an_automatically_ignored_face_keeps_the_manual_choice(context, monkeypatch):
    monkeypatch.setattr(settings(), 'face_auto_link_enabled', True)
    person = child(context)
    indexed(context, image_media(context), [1, 0], person['id'])
    target = image_media(context, [person['id']]); fid = indexed(context, target, [1, 0])
    previously_ignored(context, fid, person["id"])
    assert confirm(context, target, fid).status_code == 200
    context.client.post('/api/faces/auto-link')
    with context.db() as db:
        row = db.get(MediaFace, fid)
        assert not row.ignored and row.child_id is None and row.auto_link_blocked


def test_explicit_video_confirmation_can_use_excluded_person_locally_with_other_human_references(context, monkeypatch):
    monkeypatch.setattr(settings(), "face_auto_link_enabled", True)
    person = child(context)
    person_id = person["id"]
    prefs = context.client.get("/api/organization/settings").json()
    prefs["face_excluded_child_ids"] = [person_id]
    assert context.client.put("/api/organization/settings", json=prefs).status_code == 200

    video = image_media(context, [person_id])
    with context.db() as db:
        db.get(Media, video).media_type = "video"
        db.commit()
    seed = indexed(context, video, [.58, math.sqrt(1-.58**2), 0], frame_seconds=12)
    sibling = indexed(context, video, [1, 0, 0], frame_seconds=24)
    old_duplicate = indexed(context, video, [1, 0, 0], frame_seconds=30)
    manually_ignored = indexed(context, video, [1, 0, 0], frame_seconds=36)
    other_photo = image_media(context)
    other_face = indexed(context, other_photo, [.67, 0, math.sqrt(1-.67**2)])
    outside = [.67, 0, math.sqrt(1-.67**2)]
    reference_pair(context, person_id, outside)
    previously_ignored(context, old_duplicate, person_id)
    assert confirm(context, video, manually_ignored, ignored=True).status_code == 200

    assert confirm(context, video, seed, person_id).json()["matching_queued"]
    drain_matching(context)
    with context.db() as db:
        for face_id in (sibling, old_duplicate):
            row = db.get(MediaFace, face_id)
            assert row.child_id == person_id and row.auto_reference_face_id == seed
            assert row.confirmed_by is None and not row.ignored
        assert db.get(MediaFace, manually_ignored).ignored
        assert db.get(MediaFace, other_face).child_id is None

    assert confirm(context, video, seed).status_code == 200
    drain_matching(context)
    with context.db() as db:
        assert db.get(MediaFace, sibling).child_id is None
        assert db.get(MediaFace, old_duplicate).child_id is None


def test_a_default_binding_without_face_references_does_not_ignore_unknown_faces(context, monkeypatch):
    monkeypatch.setattr(settings(), 'face_auto_link_enabled', True)
    person = child(context)
    target = image_media(context, [person['id']]); fid = indexed(context, target, [1, 0])
    context.client.post('/api/faces/auto-link')
    with context.db() as db:assert not db.get(MediaFace, fid).ignored


def test_a_stronger_unbound_person_is_still_matched(context, monkeypatch):
    monkeypatch.setattr(settings(), 'face_auto_link_enabled', True)
    a, b = child(context, '已绑定'), child(context, '尚未绑定')
    indexed(context, image_media(context), [.8, .6], a['id'])
    reference_pair(context, b['id'], [1, 0])
    target = image_media(context, [a['id']]); fid = indexed(context, target, [1, 0])
    assert context.client.post('/api/faces/auto-link').json()['linked_faces'] == 1
    with context.db() as db:
        row = db.get(MediaFace, fid)
        assert row.child_id == b['id'] and not row.ignored
    assert set(context.client.get(f'/api/media/{target}').json()['child_ids']) == {a['id'], b['id']}


def test_explicit_album_add_survives_correction_of_its_face_source(context):
    person = child(context)
    mid = image_media(context)
    fid = indexed(context, mid, [1, 0])
    assert confirm(context, mid, fid, person["id"]).status_code == 200
    response = context.client.post("/api/media/batch-children", json={
        "media_ids": [mid], "child_ids": [person["id"]], "mode": "add"})
    assert response.status_code == 200
    assert confirm(context, mid, fid).json()["child_ids"] == [person["id"]]


def test_two_faces_in_a_photo_cannot_claim_the_same_person_automatically(context, monkeypatch):
    monkeypatch.setattr(settings(), "face_auto_link_enabled", True)
    person = child(context)
    reference_pair(context, person["id"], [1, 0])
    mid = image_media(context)
    ids = [indexed(context, mid, [1, 0]), indexed(context, mid, [.95, math.sqrt(1-.95**2)])]
    assert context.client.post("/api/faces/auto-link").json()["linked_faces"] == 0
    with context.db() as db:
        assert all(db.get(MediaFace, fid).child_id is None for fid in ids)
