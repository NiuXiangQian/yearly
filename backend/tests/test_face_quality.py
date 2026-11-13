import base64
import io

import pytest
from PIL import Image
from sqlalchemy import select

from app import faces
from app.face_quality import pixel_quality, landmark_quality, source_quality, _assess
from app.models import MediaFace, MediaChild
from conftest import child
from test_auto_faces import indexed
from test_faces import image_media


def detailed_crop():
    np = pytest.importorskip("numpy")
    return np.random.default_rng(42).integers(40, 220, size=(112, 112, 3), dtype=np.uint8)


def landmarks():
    return [[32, 38], [80, 38], [56, 61], [37, 84], [75, 84]]


def test_blur_small_low_contrast_and_partial_crops_are_rejected():
    cv = pytest.importorskip("cv2")
    crop = detailed_crop()
    assert pixel_quality(crop) is None
    assert pixel_quality(cv.GaussianBlur(crop, (21, 21), 6)) == "blurred"
    assert pixel_quality(crop * 0 + 120) == "blurred"
    assert pixel_quality(crop[:50]) == "too_small"
    assert pixel_quality(crop[:, 45:]) == "incomplete_face"
    assert landmark_quality(landmarks(), 112, 112) is None
    missing_eye = landmarks(); missing_eye[0] = [-2, 38]
    assert landmark_quality(missing_eye, 112, 112) == "incomplete_face"
    missing_mouth = landmarks(); missing_mouth[4] = [75, 112]
    assert landmark_quality(missing_mouth, 112, 112) == "incomplete_face"


def test_source_clipping_is_rejected_before_further_processing():
    np = pytest.importorskip("numpy")
    crop = detailed_crop()
    points = (np.asarray(landmarks()) + [20, 20]).flatten().tolist()
    detection = [20, 20, 112, 112, *points, .99]
    assert source_quality(crop, detection, 160, 160) is None
    assert source_quality(crop, detection, 132, 160) == "incomplete_face"
    detection[0] = -1
    assert source_quality(crop, detection, 160, 160) == "incomplete_face"


def encoded(crop):
    output = io.BytesIO()
    Image.fromarray(crop).save(output, "JPEG")
    return base64.b64encode(output.getvalue()).decode()


def test_cached_crop_requires_visible_landmarks_and_unavailable_is_not_rejection(monkeypatch):
    np = pytest.importorskip("numpy")
    pytest.importorskip("cv2")
    from app import face_quality as quality
    class Detector:
        def setInputSize(self, size): pass
        def detect(self, pixels):
            return 1, np.asarray([[28, 28, 112, 112,
                                  *(np.asarray(landmarks()) + 28).flatten(), .99]])
    monkeypatch.setattr(quality, "_detector", lambda path: Detector())
    thumbnail = encoded(detailed_crop())
    box = (.1, .1, .3, .3)
    _assess.cache_clear()
    assert _assess(thumbnail, box, "test") == (True, "accepted")
    assert _assess(thumbnail, (0, .1, .3, .3), "test")[1] == "incomplete_face"
    class Missing(Detector):
        def detect(self, pixels): return 0, None
    monkeypatch.setattr(quality, "_detector", lambda path: Missing())
    _assess.cache_clear()
    assert _assess(thumbnail, box, "test")[1] == "incomplete_face"
    def unavailable(path): raise RuntimeError("model unavailable")
    monkeypatch.setattr(quality, "_detector", unavailable)
    _assess.cache_clear()
    assert _assess(thumbnail, box, "test")[0] is None
    _assess.cache_clear()


def test_cleanup_preserves_confirmations_bindings_and_unknown_or_reopened_rows(context, monkeypatch):
    person = child(context, "已有档案")
    mid = image_media(context, [person["id"]])
    pending = indexed(context, mid, [1, 0])
    confirmed = indexed(context, mid, [1, 0], person["id"])
    reopened = indexed(context, mid, [1, 0])
    with context.db() as db:
        db.get(MediaFace, reopened).auto_link_blocked = True
        db.commit()
        links = list(db.execute(select(MediaChild.media_id, MediaChild.child_id)))
        monkeypatch.setattr(faces, "assess_crop", lambda thumbnail, box: (None, "assessment_unavailable"))
        assert faces.ignore_low_quality_faces(db, None) == 0
        monkeypatch.setattr(faces, "assess_crop", lambda thumbnail, box: (False, "blurred"))
        assert faces.ignore_low_quality_faces(db, None) == 1
        db.commit()
        assert db.get(MediaFace, pending).ignored
        assert db.get(MediaFace, pending).confirmed_by is None
        assert db.get(MediaFace, confirmed).child_id == person["id"]
        assert not db.get(MediaFace, confirmed).ignored
        assert not db.get(MediaFace, reopened).ignored
        assert links == list(db.execute(select(MediaChild.media_id, MediaChild.child_id)))
        assert faces.ignore_low_quality_faces(db, None) == 0
    response = context.client.get("/api/faces/review")
    assert response.status_code == 200
    assert pending not in {item["id"] for item in response.json()["items"]}


def test_quality_gate_preserves_existing_automatic_history(context, monkeypatch):
    from app.config import settings
    monkeypatch.setattr(settings(), "face_auto_link_enabled", True)
    person = child(context, "合成测试档案")
    reference = indexed(context, image_media(context), [1, 0], person["id"])
    mid = image_media(context, [person["id"]])
    assigned = indexed(context, mid, [1, 0])
    with context.db() as db:
        row = db.get(MediaFace, assigned)
        row.child_id = person["id"]
        row.auto_match_score = .9
        row.auto_reference_face_id = reference
        # Distinguish the synthetic target crop from the synthetic reference crop.
        row.thumbnail = "target-fixture"
        db.commit()
        monkeypatch.setattr(faces, "assess_crop", lambda thumbnail, box:
                            (True, "accepted") if thumbnail == "target-fixture" else (False, "blurred"))
        assert faces.auto_link(db, None) == dict(linked_faces=0, reset_faces=0, media_count=0)
        db.commit()
        assert db.get(MediaFace, assigned).child_id == person["id"]
        assert db.get(MediaFace, reference).confirmed_by is not None
        assert list(db.scalars(select(MediaChild.child_id).where(MediaChild.media_id == mid))) == [person["id"]]
