import shutil
import subprocess
from types import SimpleNamespace

import imageio_ffmpeg

from app import sticker_packs
from app.models import VideoPreview
from conftest import file_payload, upload


def test_sticker_suggestions_keep_only_valid_frames_and_captions(context, monkeypatch):
    first = upload(context)["media_id"]
    second = upload(context)["media_id"]
    monkeypatch.setattr(sticker_packs, "require_enabled", lambda: None)
    image = {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,dGVzdA=="}}
    monkeypatch.setattr(sticker_packs, "preview_candidates", lambda db, storage, media: [(0.75, image)])
    calls = []

    def suggest(db, system, content, schema, *, model):
        calls.append(content)
        return schema(items=[
            sticker_packs.CaptionSuggestion(candidate_id="foreign", captions=["无效"]),
            sticker_packs.CaptionSuggestion(candidate_id="c2", captions=[" 我困啦 ", "我困啦", ""]),
            sticker_packs.CaptionSuggestion(candidate_id="c2", captions=["重复"]),
            sticker_packs.CaptionSuggestion(candidate_id="c1", captions=["嘿嘿", "这是一个明显超过限制的配字"]),
        ])

    monkeypatch.setattr(sticker_packs, "chat", suggest)
    response = context.client.post("/api/sticker-packs/suggestions", json={"media_ids": [first, second]})
    assert response.status_code == 200, response.text
    assert response.json()["items"] == [
        {"media_id": second, "frame_seconds": 0.75, "captions": ["我困啦"]},
        {"media_id": first, "frame_seconds": 0.75, "captions": ["嘿嘿"]},
    ]
    assert len(calls) == 1 and calls[0].count(image) == 2


def test_sticker_source_permissions_are_rechecked_for_export_and_ai(context, monkeypatch):
    mid = upload(context)["media_id"]
    assert context.client.get("/api/sticker-packs/eligibility", params={"media_ids": mid}).json() == {"ok": True}
    response = context.client.put("/api/timeline/days/2024-03-31/sharing", json={"share_allowed": False})
    assert response.status_code == 200, response.text

    def must_not_call():
        raise AssertionError("blocked media must be rejected before AI access")

    monkeypatch.setattr(sticker_packs, "require_enabled", must_not_call)
    assert context.client.get("/api/sticker-packs/eligibility", params={"media_ids": mid}).status_code == 422
    assert context.client.post("/api/sticker-packs/suggestions", json={"media_ids": [mid]}).status_code == 422


def test_video_sticker_sends_sampled_preview_frames(context, tmp_path, monkeypatch):
    clip = tmp_path / "clip.mp4"
    subprocess.run([
        imageio_ffmpeg.get_ffmpeg_exe(), "-v", "error", "-f", "lavfi", "-i",
        "testsrc2=s=160x120:r=25:d=2", str(clip),
    ], check=True, capture_output=True)
    payload = file_payload(clip.read_bytes(), name=clip.name)
    payload["mime_type"] = "video/mp4"
    mid = upload(context, content=clip.read_bytes(), files=[payload], media_type="video")["media_id"]
    with context.db() as db:
        db.add(VideoPreview(sha256=payload["sha256"], status="ready", object_key="compressed-preview"))
        db.commit()

    reads = []

    def download(key, target):
        reads.append(key)
        shutil.copyfile(clip, target)

    context.storage.bucket = SimpleNamespace(get_object_to_file=download)
    monkeypatch.setattr(sticker_packs, "require_enabled", lambda: None)

    def suggest(db, system, content, schema, *, model):
        images = [part for part in content if part["type"] == "image_url"]
        assert len(images) == 5
        assert all(image["image_url"]["url"].startswith("data:image/jpeg;base64,") for image in images)
        return schema(items=[sticker_packs.CaptionSuggestion(candidate_id="c3", captions=["嘿嘿"])])

    monkeypatch.setattr(sticker_packs, "chat", suggest)
    assert context.client.get("/api/sticker-packs/eligibility", params={"media_ids": mid}).json() == {"ok": True}
    response = context.client.post("/api/sticker-packs/suggestions", json={"media_ids": [mid]})
    assert response.status_code == 200, response.text
    assert response.json()["items"] == [{"media_id": mid, "frame_seconds": 0.95, "captions": ["嘿嘿"]}]
    assert reads == ["compressed-preview"]
