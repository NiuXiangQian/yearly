import base64
import io

import pytest
from PIL import Image
from sqlalchemy import select

from app import faces
from app.config import settings
from app.face_engine import MODEL_VERSION
from app.models import DisplayPreview, Media, MediaFace, MediaFile, VideoPreview
from conftest import child, upload, file_payload
from test_accounts import act


def face(vector=None):
    output = io.BytesIO()
    Image.new("RGB", (40, 40), "#abcabc").save(output, "JPEG")
    return dict(box=[0.1, 0.1, 0.2, 0.3], embedding=vector or [1.0] + [0.0]*127,
                thumbnail=base64.b64encode(output.getvalue()).decode(), frame_seconds=None)


@pytest.fixture
def detector(monkeypatch):
    monkeypatch.setattr(settings(), "face_matching_enabled", True)
    monkeypatch.setattr(faces, "availability", lambda: dict(enabled=True, ready=True, message="", model=MODEL_VERSION))
    calls = []
    class Detector:
        def detect(self, raw, frame_seconds=None):
            calls.append(raw)
            return [face()]
    monkeypatch.setattr(faces, "FaceEngine", Detector)
    return calls


def image_media(context, people=()):
    mid = upload(context, list(people))["media_id"]
    with context.db() as db:
        file = db.scalar(select(MediaFile).where(MediaFile.media_id == mid))
        db.add(DisplayPreview(sha256=file.sha256, status="ready", image_key=f"previews/{mid}.webp"))
        db.commit()
    class Bucket:
        def get_object(self, key):
            assert key.startswith("previews/") and key.endswith(".webp")
            return io.BytesIO(b"compressed-preview")
    context.storage.bucket = Bucket()
    return mid


def analyze(context, mid):
    response = context.client.post(f"/api/faces/media/{mid}/analyze")
    assert response.status_code == 200, response.text
    return response.json()


def confirm(context, mid, fid, cid=None, ignored=False):
    return context.client.put(f"/api/faces/media/{mid}/confirm", json={"assignments": [dict(face_id=fid, child_id=cid, ignored=ignored)]})


@pytest.mark.parametrize("role", ["member", "viewer"])
def test_faces_are_admin_only_before_analysis(context, detector, role):
    mid = image_media(context)
    act(context, role)
    for method, path, body in [("GET", "", None), ("POST", "/analyze", {}), ("PUT", "/confirm", {"assignments": []}), ("DELETE", "", None)]:
        response = context.client.request(method, f"/api/faces/media/{mid}{path}", json=body)
        assert response.status_code == 403
    assert detector == []


def test_detection_cache_empty_and_legacy_contract(context, detector, monkeypatch):
    mid = image_media(context)
    legacy = context.client.get(f"/api/media/{mid}").json()
    before = context.client.get(f"/api/faces/media/{mid}").json()
    assert not before["analyzed"] and before["faces"] == []
    one = analyze(context, mid)
    assert len(one["faces"]) == 1
    assert "embedding" not in str(one) and "source_sha256" not in str(one)
    assert analyze(context, mid) == one
    assert detector == [b"compressed-preview"]
    assert context.client.get(f"/api/media/{mid}").json() == legacy
    context.client.delete(f"/api/faces/media/{mid}")
    monkeypatch.setattr(faces, "FaceEngine", lambda: type("Empty", (), {"detect": lambda self, raw: []})())
    assert analyze(context, mid)["faces"] == []
    monkeypatch.setattr(faces, "FaceEngine", lambda: pytest.fail("empty analysis must be cached"))
    assert analyze(context, mid)["analyzed"]


def test_only_explicit_confirmations_seed_matching(context, detector):
    person = child(context)
    seed = image_media(context, [person["id"]])
    seed_face = analyze(context, seed)["faces"][0]
    other = image_media(context)
    other_face = analyze(context, other)["faces"][0]
    assert other_face["candidates"] == []  # A photo-level person tag is not a face identity.
    assert confirm(context, seed, seed_face["id"], person["id"]).status_code == 200
    logs = context.client.get(f"/api/audit-logs?resource_type=media&resource_id={seed}").json()["items"]
    changes = next(row["changes"]["faces"] for row in logs if "faces" in row["changes"])
    assert set(changes) == {"before", "after"}  # Released native clients decode change objects.
    assert changes["after"][0]["child_id"] == person["id"]
    assert "embedding" not in str(changes) and "thumbnail" not in str(changes)
    fresh = context.client.get(f"/api/faces/media/{other}").json()
    candidate = fresh["faces"][0]["candidates"][0]
    assert candidate["child_id"] == person["id"] and candidate["similarity"] == 1.0
    assert candidate["reference_media_id"] == seed
    assert fresh["child_ids"] == []
    assert context.client.get(f"/api/media/{other}").json()["child_ids"] == []
    assert confirm(context, other, other_face["id"], person["id"]).json()["child_ids"] == [person["id"]]


def test_correct_ignore_clear_and_manual_links_are_preserved(context, detector):
    first, second, manual = child(context), child(context, "妹妹"), child(context, "奶奶")
    mid = image_media(context, [manual["id"]])
    fid = analyze(context, mid)["faces"][0]["id"]
    assert set(confirm(context, mid, fid, first["id"]).json()["child_ids"]) == {first["id"], manual["id"]}
    corrected = confirm(context, mid, fid, second["id"]).json()
    assert set(corrected["child_ids"]) == {second["id"], manual["id"]}
    assert confirm(context, mid, fid, ignored=True).json()["child_ids"] == [manual["id"]]
    assert confirm(context, mid, fid, manual["id"]).status_code == 200
    cleared = context.client.delete(f"/api/faces/media/{mid}").json()
    assert cleared["child_ids"] == [manual["id"]] and not cleared["analyzed"]
    with context.db() as db:
        assert db.get(MediaFace, fid) is None


def test_group_photo_confirms_people_individually_without_replacing_other_faces(context, detector, monkeypatch):
    people = [child(context, name) for name in ["爸爸", "妈妈", "孩子"]]
    pet = context.client.post("/api/children", json={"name": "多多", "profile_type": "pet", "species": "狗"}).json()
    mid = image_media(context, [pet["id"]])
    vectors = [[float(n == index) for n in range(128)] for index in range(3)]
    monkeypatch.setattr(faces, "FaceEngine", lambda: type("Group", (), {"detect": lambda self, raw: [face(vector) for vector in vectors]})())
    detected = analyze(context, mid)["faces"]
    assert len(detected) == 3
    linked = {pet["id"]}
    for item, person in zip(detected, people, strict=True):
        linked.add(person["id"])
        saved = confirm(context, mid, item["id"], person["id"])
        assert saved.status_code == 200
        assert set(saved.json()["child_ids"]) == linked
    assert set(context.client.get(f"/api/media/{mid}").json()["child_ids"]) == linked
    grandmother = child(context, "奶奶")
    corrected = confirm(context, mid, detected[0]["id"], grandmother["id"]).json()
    assert set(corrected["child_ids"]) == {pet["id"], grandmother["id"], people[1]["id"], people[2]["id"]}


def test_reject_wrong_media_unknown_people_pets_and_invalid_choices(context, detector):
    person = child(context)
    mid, other = image_media(context), image_media(context)
    fid = analyze(context, mid)["faces"][0]["id"]
    analyze(context, other)
    pet = context.client.post("/api/children", json={"name": "小猫", "profile_type": "pet"}).json()
    assert confirm(context, other, fid, person["id"]).status_code == 422
    assert confirm(context, mid, fid, 999999).status_code == 422
    assert confirm(context, mid, fid, pet["id"]).status_code == 422
    assert confirm(context, mid, fid, person["id"], True).status_code == 422
    response = context.client.put(f"/api/faces/media/{mid}/confirm", json={"assignments": [{"face_id": fid}, {"face_id": fid}]})
    assert response.status_code == 422
    assert context.client.get(f"/api/faces/media/{mid}").json()["child_ids"] == []


def test_match_threshold_distinct_people_and_fresh_source_visibility(context, detector):
    person = child(context)
    seed = image_media(context)
    fid = analyze(context, seed)["faces"][0]["id"]
    confirm(context, seed, fid, person["id"])
    other = image_media(context)
    other_fid = analyze(context, other)["faces"][0]["id"]
    with context.db() as db:
        db.get(MediaFace, other_fid).embedding = [0.0, 1.0] + [0.0]*126
        db.commit()
    assert context.client.get(f"/api/faces/media/{other}").json()["faces"][0]["candidates"] == []
    with context.db() as db:
        db.get(MediaFace, other_fid).embedding = face()["embedding"]
        db.get(Media, seed).status = "deleted"
        db.commit()
    assert context.client.get(f"/api/faces/media/{other}").json()["faces"][0]["candidates"] == []
    assert context.client.get(f"/api/faces/media/{seed}").status_code == 404


def test_profile_deletion_removes_training_identity(context, detector):
    person = child(context)
    mid = image_media(context)
    fid = analyze(context, mid)["faces"][0]["id"]
    confirm(context, mid, fid, person["id"])
    assert context.client.delete(f"/api/children/{person['id']}", params={"confirm_name": person["name"]}).status_code == 200
    state = context.client.get(f"/api/faces/media/{mid}").json()
    assert state["faces"][0]["child_id"] is None and state["child_ids"] == []
    assert confirm(context, mid, fid).status_code == 200


def test_disabled_missing_preview_and_old_search_still_work(context, detector, monkeypatch):
    mid = upload(context)["media_id"]
    assert context.client.post(f"/api/faces/media/{mid}/analyze").status_code == 409
    monkeypatch.setattr(faces, "availability", lambda: dict(enabled=False, ready=False, message="人脸匹配尚未启用", model=MODEL_VERSION))
    assert context.client.post(f"/api/faces/media/{mid}/analyze").status_code == 503
    assert not context.client.get(f"/api/faces/media/{mid}").json()["enabled"]
    assert context.client.get("/api/timeline").status_code == 200
    assert context.client.get(f"/api/media/{mid}").status_code == 200


@pytest.mark.parametrize("multiple", [False, True])
def test_video_samples_compressed_preview_with_timestamps(context, detector, monkeypatch, multiple):
    import subprocess
    import imageio_ffmpeg
    from pathlib import Path
    source = context.tmp_path / "compressed.mp4"
    subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(), "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                    "color=c=blue:s=320x240:d=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", str(source)], check=True)
    mid = upload(context, files=[file_payload(name="clip.mov")], media_type="video")["media_id"]
    with context.db() as db:
        file = db.scalar(select(MediaFile).where(MediaFile.media_id == mid))
        db.get(Media, mid).duration_ms = 1000
        db.add(VideoPreview(sha256=file.sha256, status="ready", object_key="previews/compressed.mp4"))
        db.commit()
    class Bucket:
        def get_object_to_file(self, key, path):
            assert key == "previews/compressed.mp4"
            Path(path).write_bytes(source.read_bytes())
    context.storage.bucket = Bucket()
    timestamps = []
    class Detector:
        def detect(self, raw, frame_seconds=None):
            assert Image.open(io.BytesIO(raw)).size == (1280, 960)
            timestamps.append(frame_seconds)
            detected = [dict(face(), frame_seconds=frame_seconds, _quality=frame_seconds + 0.1)]
            if multiple and frame_seconds == 0.5:
                detected.append(dict(face([0.0, 1.0] + [0.0]*126), frame_seconds=frame_seconds, _quality=0.5))
            return detected
    monkeypatch.setattr(faces, "FaceEngine", Detector)
    state = analyze(context, mid)
    assert state["faces"][0]["frame_seconds"] == 0.5 and timestamps == [0, 0.5]
    assert len(state["faces"]) == (2 if multiple else 1)
    assert "_quality" not in str(state)


def test_refresh_preserves_reviewed_faces_and_ids_and_adds_missed_people(context, detector, monkeypatch):
    person = child(context)
    mid = image_media(context)
    original = analyze(context, mid)["faces"][0]
    confirm(context, mid, original["id"], person["id"])
    legacy = context.client.get(f"/api/media/{mid}").json()
    missed = face([0.0, 1.0] + [0.0]*126)
    monkeypatch.setattr(faces, "FaceEngine", lambda: type("Group", (), {"detect": lambda self, raw: [face(), missed]})())
    refreshed = context.client.post(f"/api/faces/media/{mid}/analyze", json={"refresh": True})
    assert refreshed.status_code == 200, refreshed.text
    items = refreshed.json()["faces"]
    assert len(items) == 2 and items[0]["id"] == original["id"]
    assert items[0]["child_id"] == person["id"] and items[0]["thumbnail"] == original["thumbnail"]
    assert items[1]["child_id"] is None
    assert context.client.get(f"/api/media/{mid}").json() == legacy
    # Repeated refreshes do not multiply results or invalidate an old client's face ID.
    assert len(context.client.post(f"/api/faces/media/{mid}/analyze", json={"refresh": True}).json()["faces"]) == 2
    assert confirm(context, mid, original["id"], person["id"]).status_code == 200


def test_refresh_updates_unreviewed_crop_but_keeps_ignored_and_withdrawn_choices(context, detector, monkeypatch):
    mid = image_media(context)
    original = analyze(context, mid)["faces"][0]
    better = dict(face(), thumbnail=base64.b64encode(b"better-crop").decode())
    monkeypatch.setattr(faces, "FaceEngine", lambda: type("Better", (), {"detect": lambda self, raw: [better]})())
    updated = context.client.post(f"/api/faces/media/{mid}/analyze", json={"refresh": True}).json()["faces"]
    assert len(updated) == 1 and updated[0]["id"] == original["id"]
    assert updated[0]["thumbnail"].endswith(better["thumbnail"])
    confirm(context, mid, original["id"], ignored=True)
    monkeypatch.setattr(faces, "FaceEngine", lambda: type("Older", (), {"detect": lambda self, raw: [face()]})())
    kept = context.client.post(f"/api/faces/media/{mid}/analyze", json={"refresh": True}).json()["faces"]
    assert kept == [dict(updated[0], ignored=True)]
    person = child(context)
    confirm(context, mid, original["id"], person["id"])
    confirm(context, mid, original["id"])
    context.client.post(f"/api/faces/media/{mid}/analyze", json={"refresh": True})
    with context.db() as db:
        row = db.get(MediaFace, original["id"])
        assert row.child_id is None and row.auto_link_blocked
        assert row.thumbnail == better["thumbnail"]


def test_refresh_empty_or_failed_detection_does_not_erase_existing_faces(context, detector, monkeypatch):
    from fastapi import HTTPException
    mid = image_media(context)
    original = analyze(context, mid)
    monkeypatch.setattr(faces, "FaceEngine", lambda: type("Empty", (), {"detect": lambda self, raw: []})())
    empty = context.client.post(f"/api/faces/media/{mid}/analyze", json={"refresh": True})
    assert empty.status_code == 200 and empty.json() == original
    class Unavailable:
        def detect(self, raw):
            raise HTTPException(503, "人脸模型暂不可用")
    monkeypatch.setattr(faces, "FaceEngine", Unavailable)
    failed = context.client.post(f"/api/faces/media/{mid}/analyze", json={"refresh": True})
    assert failed.status_code == 503
    assert context.client.get(f"/api/faces/media/{mid}").json() == original
