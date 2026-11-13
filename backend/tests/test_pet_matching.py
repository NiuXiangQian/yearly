import io
from types import SimpleNamespace
import pytest
from PIL import Image
from sqlalchemy import select
from app import pets
from app.models import MediaSearchIndex, MediaPetIndex, Media, MediaFace
from conftest import child
from test_faces import image_media
from conftest import upload, file_payload
from app.models import MediaFile, VideoPreview
from test_accounts import act


@pytest.fixture
def dog_detector(context, monkeypatch):
    output = io.BytesIO()
    Image.new("RGB", (160, 160), "#bd925f").save(output, "JPEG")
    raw = output.getvalue()
    calls = []

    def detect(db, system, content, schema):
        calls.append(content)
        return schema(
            dogs=[
                dict(
                    frame=0,
                    box=[0.1, 0.1, 0.9, 0.9],
                    appearance="棕白色长毛、竖耳、短腿的狗",
                )
            ]
        )

    monkeypatch.setattr(pets, "chat", detect)
    monkeypatch.setattr(pets, "embed", lambda db, text: [1] + [0] * 511)
    monkeypatch.setattr(pets, "require_enabled", lambda: None)

    def photo(people=()):
        mid = image_media(context, people)
        context.storage.bucket = SimpleNamespace(get_object=lambda key: io.BytesIO(raw))
        with context.db() as db:
            db.add(
                MediaSearchIndex(
                    media_id=mid,
                    status="ready",
                    description="一只棕白色的狗。",
                    embedding=[1] + [0] * 511,
                )
            )
            db.commit()
        return mid

    return photo, calls


def profile(context):
    response = context.client.post(
        "/api/children", json=dict(name="示例狗狗", profile_type="pet", species="狗")
    )
    assert response.status_code == 200
    return response.json()


def test_short_video_samples_later_frames_and_uses_only_the_compressed_preview(context, dog_detector, monkeypatch):
    from pathlib import Path
    output=io.BytesIO();Image.new("RGB",(160,120),"#a88a60").save(output,"JPEG");raw=output.getvalue()
    mid=upload(context,media_type="video",files=[dict(file_payload(name="dog.mp4"), mime_type="video/mp4")])["media_id"]
    with context.db() as db:
        file=db.scalar(select(MediaFile).where(MediaFile.media_id==mid))
        db.get(Media,mid).duration_ms=6600
        db.add(VideoPreview(sha256=file.sha256,status="ready",object_key="compressed-dog.mp4"));db.commit()
    def download(key,path):
        assert key=="compressed-dog.mp4"
        Path(path).write_bytes(b"mock compressed video")
    context.storage.bucket=SimpleNamespace(get_object_to_file=download)
    def frames(args,**kwargs):
        assert args[args.index("-frames:v")+1]=="3"
        for n in range(1,4):Path(args[-1].replace("%02d",f"{n:02d}")).write_bytes(raw)
    monkeypatch.setattr(pets.subprocess,"run",frames)
    monkeypatch.setattr(pets,"chat",lambda db,system,content,schema:schema(dogs=[dict(frame=2,box=[.1,.1,.9,.9],appearance="棕白色竖耳狗")]))
    result=context.client.post(f"/api/pets/media/{mid}/analyze")
    assert result.status_code==200,result.text
    assert result.json()["dogs"][0]["frame_seconds"]==4.4


def test_dogs_need_explicit_reference_pet_confirmation_links_and_preserves_legacy_data(
    context, dog_detector
):
    photo, calls = dog_detector
    p = profile(context)
    person = child(context)
    seed = photo([p["id"]])
    other = photo([person["id"]])
    before = context.client.get(f"/api/media/{other}").json()
    for mid in [seed, other]:
        response = context.client.post(f"/api/pets/media/{mid}/analyze")
        assert response.status_code == 200, response.text
        assert response.json()["dogs"][0]["candidates"] == []
    assert context.client.get(f"/api/media/{other}").json() == before
    context.client.post(f"/api/pets/media/{seed}/analyze")
    assert len(calls) == 2
    confirmed = context.client.put(
        f"/api/pets/media/{seed}/confirm", json=dict(index=0, child_id=p["id"])
    )
    assert confirmed.status_code == 200
    queue = context.client.get("/api/pets/review").json()
    candidate = next(g for g in queue["items"] if g["media"]["id"] == other)["dogs"][0]
    assert candidate["candidates"][0]["child_id"] == p["id"]
    filtered = context.client.get("/api/pets/review", params={"media_id": other}).json()
    assert [g["media"]["id"] for g in filtered["items"]] == [other]
    assert "embedding" not in str(queue) and "confirmed_by" not in str(queue)
    assert context.client.get(f"/api/memory-interviews/{seed}").json()[
        "confirmed_pets"
    ] == [p["name"]]
    saved = context.client.put(
        f"/api/pets/media/{other}/confirm", json=dict(index=0, child_id=p["id"])
    )
    assert saved.status_code == 200
    assert set(saved.json()["media"]["child_ids"]) == {p["id"], person["id"]}
    assert context.client.delete(f"/api/pets/media/{other}").status_code == 200
    assert context.client.get(f"/api/media/{other}").json()["child_ids"] == [
        person["id"]
    ]
    context.client.delete(f"/api/pets/media/{seed}")
    assert context.client.get(f"/api/media/{seed}").json()["child_ids"] == [p["id"]]
    with context.db() as db:
        assert list(db.scalars(select(MediaFace))) == []


def test_preferred_reference_keeps_confirmations_and_legacy_requests(context, dog_detector):
    photo, _ = dog_detector
    pet = profile(context)
    old, front, target = [photo() for _ in range(3)]
    for mid in [old, front, target]:
        assert context.client.post(f"/api/pets/media/{mid}/analyze").status_code == 200
    body = dict(index=0, child_id=pet["id"])
    path = f"/api/pets/media/{front}/reference"
    assert context.client.put(path, json=body).status_code == 409
    for mid in [old, front]:
        assert context.client.put(f"/api/pets/media/{mid}/confirm", json=body).status_code == 200
    assert context.client.put(path, json=body).json() == dict(media_id=front, **body)
    assert context.client.put(path, json=body).status_code == 200
    candidate = context.client.get("/api/pets/review", params={"media_id": target}).json()["items"][0]["dogs"][0]["candidates"][0]
    assert candidate["reference_media_id"] == front
    # An installed client resubmitting the old confirmation body retains the preference.
    assert context.client.put(f"/api/pets/media/{front}/confirm", json=body).status_code == 200
    with context.db() as db:
        for mid in [old, front]:
            dog = db.get(MediaPetIndex, mid).detections[0]
            assert dog["child_id"] == pet["id"] and dog["confirmed_by"]
        assert db.get(MediaPetIndex, front).detections[0]["reference_preferred"]
    assert context.client.put(f"/api/pets/media/{front}/confirm", json=dict(index=0)).status_code == 200
    candidate = context.client.get("/api/pets/review", params={"media_id": target}).json()["items"][0]["dogs"][0]["candidates"][0]
    assert candidate["reference_media_id"] == old
    with context.db() as db:
        assert not db.get(MediaPetIndex, front).detections[0].get("reference_preferred")


def test_empty_detection_is_cached_and_failed_analysis_is_not_persisted(
    context, dog_detector, monkeypatch
):
    photo, calls = dog_detector
    mid = photo()
    monkeypatch.setattr(
        pets, "chat", lambda db, system, content, schema: schema(dogs=[])
    )
    assert context.client.post(f"/api/pets/media/{mid}/analyze").json()["dogs"] == []
    monkeypatch.setattr(
        pets, "chat", lambda *args: pytest.fail("empty result must be cached")
    )
    assert context.client.post(f"/api/pets/media/{mid}/analyze").status_code == 200
    assert context.client.get("/api/pets/review").json()["unanalysed_media"] == 0
    other = photo()
    from fastapi import HTTPException

    def fail(*args):
        raise HTTPException(502, "模拟服务故障")

    monkeypatch.setattr(pets, "chat", fail)
    assert context.client.post(f"/api/pets/media/{other}/analyze").status_code == 502
    with context.db() as db:
        assert db.get(MediaPetIndex, other) is None


@pytest.mark.parametrize("role", ["member", "viewer"])
def test_pet_endpoints_are_admin_only(context, dog_detector, role):
    photo, calls = dog_detector
    mid = photo()
    act(context, role)
    for method, path, body in [
        ("GET", "/review", None),
        ("POST", "/analyze-next", {}),
        ("POST", f"/media/{mid}/analyze", {}),
        ("PUT", f"/media/{mid}/confirm", dict(index=0)),
        ("PUT", f"/media/{mid}/reference", dict(index=0)),
        ("DELETE", f"/media/{mid}", None),
    ]:
        assert (
            context.client.request(method, "/api/pets" + path, json=body).status_code
            == 403
        )
    assert calls == []


def test_reference_correction_trash_profile_deletion_and_wrong_species(
    context, dog_detector
):
    photo, _ = dog_detector
    p = profile(context)
    person = child(context)
    seed = photo()
    other = photo()
    for mid in [seed, other]:
        assert context.client.post(f"/api/pets/media/{mid}/analyze").status_code == 200
    assert (
        context.client.put(
            f"/api/pets/media/{seed}/confirm", json=dict(index=0, child_id=person["id"])
        ).status_code
        == 422
    )
    assert (
        context.client.put(
            f"/api/pets/media/{seed}/confirm", json=dict(index=99, child_id=p["id"])
        ).status_code
        == 404
    )
    context.client.put(
        f"/api/pets/media/{seed}/confirm", json=dict(index=0, child_id=p["id"])
    )
    with context.db() as db:
        db.get(Media, seed).status = "trash"
        db.commit()
    assert (
        context.client.get("/api/pets/review").json()["items"][0]["dogs"][0][
            "candidates"
        ]
        == []
    )
    with context.db() as db:
        db.get(Media, seed).status = "active"
        db.commit()
    assert (
        context.client.delete(
            f"/api/children/{p['id']}", params={"confirm_name": p["name"]}
        ).status_code
        == 200
    )
    with context.db() as db:
        assert db.get(MediaPetIndex, seed).detections[0]["child_id"] is None
