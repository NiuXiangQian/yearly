from types import SimpleNamespace
from unittest.mock import Mock
import subprocess
import imageio_ffmpeg
from sqlalchemy import select

from app.models import Media, MediaFile, VideoPreview
from app.storage import OSSStorage
from app.previews import generate_one, transcode
from conftest import upload, file_payload


def test_default_images_compressed_original_explicit_and_private(context):
    result = upload(context, files=[file_payload(name="photo.heic")])
    url = f"/api/media/{result['media_id']}/files/{result['tasks'][0]['file_id']}/url"
    assert context.client.get(url).json()["url"].endswith("/preview")
    assert (
        context.client.get(url + "?purpose=thumbnail").json()["mime_type"]
        == "image/webp"
    )
    assert (
        context.client.get(url + "?purpose=original")
        .json()["url"]
        .endswith("signed-original")
    )
    assert (
        context.client.get(url + "?download=true")
        .json()["url"]
        .endswith("signed-original")
    )
    assert context.client.get(url + "?purpose=anything").status_code == 422
    context.client.cookies.clear()
    assert context.client.get(url).status_code == 401


def test_pending_video_never_falls_back_to_original(context):
    result = upload(context, files=[file_payload(name="clip.mov")], media_type="video")
    url = f"/api/media/{result['media_id']}/files/{result['tasks'][0]['file_id']}/url"
    assert context.client.get(url).json() == {"url": None, "status": "pending"}
    assert (
        context.client.get(url + "?purpose=thumbnail")
        .json()["url"]
        .endswith("thumbnail")
    )
    with context.db() as db:
        file = db.get(MediaFile, result["tasks"][0]["file_id"])
        row = VideoPreview(sha256=file.sha256, status="failed")
        db.add(row)
        db.commit()
        assert context.client.get(url).json() == {"url": None, "status": "failed"}
        row.status, row.object_key, row.file_size = "ready", "previews/test.mp4", 100
        db.commit()
    data = context.client.get(url).json()
    assert data["url"].endswith("compressed.mp4") and data["file_size"] == 100
    assert (
        context.client.get(url + "?purpose=original")
        .json()["url"]
        .endswith("signed-original")
    )


def test_oss_process_is_signed_and_original_unprocessed():
    storage = OSSStorage.__new__(OSSStorage)
    storage.bucket = Mock()
    file = SimpleNamespace(
        oss_object_key="originals/photo.heic",
        mime_type="image/heic",
        original_filename="photo.heic",
    )
    storage.image_url(file, "thumbnail")
    assert (
        storage.bucket.sign_url.call_args.kwargs["params"]["x-oss-process"]
        == "image/resize,m_lfit,w_480,h_480,limit_1/format,webp/quality,q_70"
    )
    storage.image_url(file, "preview")
    assert (
        "w_1600" in storage.bucket.sign_url.call_args.kwargs["params"]["x-oss-process"]
    )
    file.mime_type = "video/quicktime"
    storage.image_url(file, "thumbnail")
    assert storage.bucket.sign_url.call_args.kwargs["params"][
        "x-oss-process"
    ].startswith("video/snapshot")
    storage.download_url(file)
    assert storage.bucket.sign_url.call_args.kwargs["params"] == {}


def test_worker_deduplicates_and_preserves_originals(context, monkeypatch):
    content = b"video-original"
    result = upload(
        context,
        content=content,
        files=[file_payload(content, "clip.mov")],
        media_type="video",
    )
    # Historical duplicate rows can predate upload deduplication.
    with context.db() as db:
        file = db.get(MediaFile, result["tasks"][0]["file_id"])
        duplicate = Media(owner_id=1, media_type="video", status="active")
        db.add(duplicate)
        db.flush()
        values = {
            c.name: getattr(file, c.name)
            for c in MediaFile.__table__.columns
            if c.name != "id"
        }
        values.update(
            media_id=duplicate.id, oss_object_key=file.oss_object_key + "-legacy"
        )
        db.add(MediaFile(**values))
        db.commit()
        context.storage.objects[values["oss_object_key"]] = content
    originals = dict(context.storage.objects)
    bucket = Mock()

    def download(key, destination):
        from pathlib import Path

        Path(destination).write_bytes(originals[key])

    bucket.get_object_to_file.side_effect = download
    context.storage.bucket = bucket
    monkeypatch.setattr(
        "app.previews.transcode", lambda source, target: target.write_bytes(b"mp4")
    )
    with context.db() as db:
        assert generate_one(db, context.storage)
        assert not generate_one(db, context.storage)
        preview = db.scalar(select(VideoPreview))
        assert preview.status == "ready" and preview.file_size == 3
        assert preview.object_key.startswith("previews/video-v1/")
    bucket.get_object_to_file.assert_called_once()
    bucket.put_object_from_file.assert_called_once()
    assert context.storage.objects == originals


def test_failed_transcode_keeps_original_and_marks_failure(context, monkeypatch):
    content = b"video-original"
    upload(
        context,
        content=content,
        files=[file_payload(content, "clip.mov")],
        media_type="video",
    )
    context.storage.bucket = Mock()

    def download(key, destination):
        from pathlib import Path

        Path(destination).write_bytes(b"corrupted")

    context.storage.bucket.get_object_to_file.side_effect = download
    encoder = Mock()
    monkeypatch.setattr("app.previews.transcode", encoder)
    with context.db() as db:
        assert generate_one(db, context.storage)
        assert db.scalar(select(VideoPreview)).status == "failed"
        assert not generate_one(db, context.storage)
    encoder.assert_not_called()
    context.storage.bucket.put_object_from_file.assert_not_called()


def test_real_ffmpeg_outputs_small_portrait_h264_and_faststart(tmp_path):
    source, target = tmp_path / "source.mp4", tmp_path / "preview.mp4"
    exe = imageio_ffmpeg.get_ffmpeg_exe()
    subprocess.run(
        [
            exe,
            "-loglevel",
            "error",
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=1080x1920:rate=30",
            "-t",
            "1",
            "-c:v",
            "libx264",
            "-threads",
            "2",
            "-crf",
            "10",
            str(source),
        ],
        check=True,
    )
    transcode(source, target)
    info = subprocess.run(
        [exe, "-hide_banner", "-i", str(target)], capture_output=True, text=True
    ).stderr
    assert "720x1280" in info and "h264" in info and "yuv420p" in info
    assert target.stat().st_size < source.stat().st_size
    data = target.read_bytes()
    assert data.index(b"moov") < data.index(b"mdat")


def test_real_ffmpeg_converts_4k_hevc_hlg_to_sdr(tmp_path):
    source, target = tmp_path / "hdr.mp4", tmp_path / "preview.mp4"
    exe = imageio_ffmpeg.get_ffmpeg_exe()
    subprocess.run(
        [
            exe,
            "-loglevel", "error",
            "-filter_threads", "1",
            "-f", "lavfi",
            "-i", "testsrc2=size=3840x2160:rate=30",
            "-t", "0.4",
            "-pix_fmt", "yuv420p10le",
            "-c:v", "libx265",
            "-preset", "ultrafast",
            "-x265-params",
            "pools=1:frame-threads=1:log-level=error:"
            "colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc",
            "-color_primaries", "bt2020",
            "-color_trc", "arib-std-b67",
            "-colorspace", "bt2020nc",
            str(source),
        ],
        check=True,
    )
    source_info = subprocess.run(
        [exe, "-hide_banner", "-i", str(source)], capture_output=True, text=True
    ).stderr
    assert "arib-std-b67" in source_info and "yuv420p10le" in source_info
    transcode(source, target)
    info = subprocess.run(
        [exe, "-hide_banner", "-i", str(target)], capture_output=True, text=True
    ).stderr
    assert "1280x720" in info and "h264" in info and "yuv420p" in info
    assert "bt709" in info and "arib-std-b67" not in info
    data = target.read_bytes()
    assert data.index(b"moov") < data.index(b"mdat")
