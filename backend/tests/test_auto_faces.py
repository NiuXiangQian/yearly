import math
import pytest
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


def test_confirmation_ignores_bound_video_frames_and_links_unbound_photos_with_legacy_payload(context, monkeypatch):
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
    assert response.json()["auto_linked"] == 1
    assert response.json()["auto_reset"] == 0
    with context.db() as db:
        row = db.get(MediaFace, other_face)
        assert row.child_id == person["id"] and row.confirmed_by is None
        assert row.auto_reference_face_id == seed and not row.auto_link_blocked
        duplicate = db.get(MediaFace, related)
        assert duplicate.ignored and duplicate.child_id is None and duplicate.confirmed_by is None
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
    indexed(context, chained, [0.6, 0.8])
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


def test_highest_candidate_wins_even_without_old_margin_and_low_matches_stay_pending(
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
    low_face = indexed(context, low, [0, 1])
    assert context.client.post("/api/faces/auto-link").json()["linked_faces"] == 1
    with context.db() as db:
        assert db.get(MediaFace, fid).child_id == a["id"]
        assert db.get(MediaFace, low_face).child_id is None
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
    indexed(context, chained, [0.6, 0.8])
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


def test_stronger_new_reference_reassigns_existing_automatic_link(context, monkeypatch):
    monkeypatch.setattr(settings(), "face_auto_link_enabled", True)
    a, b = child(context, "甲"), child(context, "乙")
    seed = image_media(context); indexed(context, seed, [.9, math.sqrt(.19)], a["id"])
    target = image_media(context); indexed(context, target, [1, 0])
    assert context.client.post("/api/faces/auto-link").json()["linked_faces"] == 1
    second = image_media(context); indexed(context, second, [1, 0], b["id"])
    summary = context.client.post("/api/faces/auto-link").json()
    assert summary["linked_faces"] == 1 and summary["reset_faces"] == 0
    assert context.client.get(f"/api/media/{target}").json()["child_ids"] == [b["id"]]


@pytest.mark.parametrize('score,expected', [(.69999, False), (.7, False), (.700001, True), (.71, True)])
def test_auto_confirmation_threshold_is_strict_and_uses_unrounded_similarity(context, monkeypatch, score, expected):
    monkeypatch.setattr(settings(), 'face_auto_link_enabled', True)
    person = child(context)
    seed = image_media(context); indexed(context, seed, [1, 0], person['id'])
    target = image_media(context); fid = indexed(context, target, [score, math.sqrt(1-score**2)])
    result = context.client.post('/api/faces/auto-link').json()
    assert result['minimum_similarity'] == .7 and result['minimum_similarity_exclusive'] is True
    assert result['minimum_margin'] == 0 and result['linked_faces'] == int(expected)
    with context.db() as db:
        row = db.get(MediaFace, fid)
        assert row.child_id == (person['id'] if expected else None)
        assert row.confirmed_by is None


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
    seed = image_media(context); indexed(context, seed, [1, 0], excluded['id'])
    previous = image_media(context); old_face = indexed(context, previous, [1, 0])
    assert context.client.post('/api/faces/auto-link').json()['linked_faces'] == 1
    indexed(context, image_media(context), [.9, math.sqrt(.19)], other['id'])
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


@pytest.mark.parametrize('score', [.55, .95])
def test_already_bound_suggestions_are_ignored_without_training_or_changing_bindings(context, monkeypatch, score):
    monkeypatch.setattr(settings(), 'face_auto_link_enabled', True)
    person = child(context)
    indexed(context, image_media(context), [1, 0], person['id'])
    target = image_media(context, [person['id']])
    fid = indexed(context, target, [score, math.sqrt(1-score**2)])
    before = context.client.get(f'/api/media/{target}').json()['child_ids']
    assert context.client.get(f'/api/faces/media/{target}').json()['faces'][0]['candidates'] == []
    assert context.client.post('/api/faces/auto-link').json()['linked_faces'] == 0
    with context.db() as db:
        row = db.get(MediaFace, fid)
        assert row.ignored and row.child_id is None and row.confirmed_by is None
        assert row.auto_match_score is None
    assert context.client.get(f'/api/media/{target}').json()['child_ids'] == before
    assert context.client.get('/api/faces/review').json()['pending_faces'] == 0
    assert context.client.get('/api/organization/reviews?kind=face').json()['pending'] == 0
    record = context.client.get('/api/organization/reviews?kind=face&scope=all').json()['items'][0]
    assert record['status'] == 'automatic' and record['current']['ignored'] is True
    assert record['evidence']['already_bound_child_ids'] == [person['id']]
    assert context.client.post('/api/faces/auto-link').json()['linked_faces'] == 0


@pytest.mark.parametrize('both_bound', [False, True])
def test_tied_suggestions_are_only_ignored_when_all_top_candidates_are_bound(context, monkeypatch, both_bound):
    monkeypatch.setattr(settings(), 'face_auto_link_enabled', True)
    a, b = child(context, '甲'), child(context, '乙')
    for person in [a, b]:indexed(context, image_media(context), [1, 0], person['id'])
    target = image_media(context, [a['id'], b['id']] if both_bound else [a['id']])
    fid = indexed(context, target, [1, 0])
    context.client.post('/api/faces/auto-link')
    with context.db() as db:
        row = db.get(MediaFace, fid)
        assert row.ignored is both_bound and row.child_id is None


def test_reopening_an_automatically_ignored_face_keeps_the_manual_choice(context, monkeypatch):
    monkeypatch.setattr(settings(), 'face_auto_link_enabled', True)
    person = child(context)
    indexed(context, image_media(context), [1, 0], person['id'])
    target = image_media(context, [person['id']]); fid = indexed(context, target, [1, 0])
    context.client.post('/api/faces/auto-link')
    assert confirm(context, target, fid).status_code == 200
    context.client.post('/api/faces/auto-link')
    with context.db() as db:
        row = db.get(MediaFace, fid)
        assert not row.ignored and row.child_id is None and row.auto_link_blocked


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
    indexed(context, image_media(context), [1, 0], b['id'])
    target = image_media(context, [a['id']]); fid = indexed(context, target, [1, 0])
    assert context.client.post('/api/faces/auto-link').json()['linked_faces'] == 1
    with context.db() as db:
        row = db.get(MediaFace, fid)
        assert row.child_id == b['id'] and not row.ignored
    assert set(context.client.get(f'/api/media/{target}').json()['child_ids']) == {a['id'], b['id']}
