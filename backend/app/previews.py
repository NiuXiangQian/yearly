"""Persistent browsing derivatives and preview-gated original archival."""

import logging
import subprocess
import tempfile
import time
from pathlib import Path

import imageio_ffmpeg
import oss2
from PIL import Image, ImageOps
from pillow_heif import register_heif_opener
from sqlalchemy import select, text, or_

from .backup import hash_file
from .db import SessionLocal, engine, now
from .models import Media, MediaFile, VideoPreview, DisplayPreview
from .config import settings

log = logging.getLogger(__name__)
register_heif_opener()


def transcode(source: Path, output: Path):
    ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    info = subprocess.run(
        [ffmpeg, "-hide_banner", "-i", str(source)], capture_output=True, text=True
    ).stderr
    filters = [
        "scale=w='if(gte(iw,ih),min(1280,iw),min(720,iw))':"
        "h='if(gte(iw,ih),min(720,ih),min(1280,ih))':"
        "force_original_aspect_ratio=decrease:force_divisible_by=2",
    ]
    # iPhone HLG/PQ recordings need tone mapping for a portable SDR preview.
    if "arib-std-b67" in info or "smpte2084" in info:
        filters += [
            "zscale=t=linear:npl=100",
            "format=gbrpf32le",
            "zscale=p=bt709",
            "tonemap=tonemap=hable:desat=0",
            "zscale=t=bt709:m=bt709:r=tv",
        ]
    filters += ["fps=30", "format=yuv420p", "setsar=1"]
    result = subprocess.run(
        [
            ffmpeg,
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            # Bound decoder and filter memory as well as encoder threads. On
            # 4K HDR clips, automatic threading exceeds the 512 MiB worker limit.
            "-threads",
            "1",
            "-filter_threads",
            "1",
            "-i",
            str(source),
            "-map",
            "0:v:0",
            "-map",
            "0:a:0?",
            "-map_metadata",
            "-1",
            "-vf",
            ",".join(filters),
            "-c:v",
            "libx264",
            "-preset",
            "fast",
            "-crf",
            "28",
            "-maxrate",
            "2200k",
            "-bufsize",
            "4400k",
            "-threads",
            "2",
            "-c:a",
            "aac",
            "-b:a",
            "96k",
            "-ac",
            "2",
            "-movflags",
            "+faststart",
            str(output),
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode:
        raise RuntimeError("视频编码失败，请检查源文件编码和 FFmpeg 支持")


def generate_one(db, storage):
    file = db.scalar(
        select(MediaFile)
        .join(Media, Media.id == MediaFile.media_id)
        .outerjoin(VideoPreview, VideoPreview.sha256 == MediaFile.sha256)
        .where(
            Media.status.in_(["active", "deleted"]),
            MediaFile.upload_status == "complete",
            MediaFile.mime_type.like("video/%"),
            or_(VideoPreview.sha256.is_(None), VideoPreview.status == "processing"),
        )
        .order_by(MediaFile.file_size, MediaFile.id)
        .limit(1)
    )
    if not file:
        return False
    preview = db.get(VideoPreview, file.sha256)
    if not preview:
        preview = VideoPreview(sha256=file.sha256)
        db.add(preview)
    db.commit()
    try:
        with tempfile.TemporaryDirectory(prefix="yearly-preview-") as directory:
            source, output = Path(directory) / "source", Path(directory) / "preview.mp4"
            storage.bucket.get_object_to_file(file.oss_object_key, str(source))
            if (
                source.stat().st_size != file.file_size
                or hash_file(source) != file.sha256
            ):
                raise ValueError("原件完整性校验失败")
            transcode(source, output)
            key = f"previews/video-v1/{file.sha256}.mp4"
            storage.bucket.put_object_from_file(
                key,
                str(output),
                headers={
                    "Content-Type": "video/mp4",
                    "Cache-Control": "private, max-age=300",
                    "x-oss-storage-class": "Standard",
                },
            )
            preview.object_key = key
            preview.file_size = output.stat().st_size
            preview.status, preview.error = "ready", ""
        log.info(
            "Video preview ready: file=%s original=%s preview=%s",
            file.id,
            file.file_size,
            preview.file_size,
        )
    except Exception as exc:
        # Persist the failure and continue with other files; never expose SDK signed URLs.
        preview.status = "failed"
        preview.error = type(exc).__name__
        log.error("Video preview failed: file=%s type=%s", file.id, type(exc).__name__)
    db.commit()
    return True


def generate_display_one(db, storage):
    file = db.scalar(
        select(MediaFile)
        .join(Media, Media.id == MediaFile.media_id)
        .outerjoin(DisplayPreview, DisplayPreview.sha256 == MediaFile.sha256)
        .outerjoin(VideoPreview, VideoPreview.sha256 == MediaFile.sha256)
        .where(
            Media.status.in_(["active", "deleted"]),
            MediaFile.upload_status == "complete",
            MediaFile.file_role.in_(["original", "live_video"]),
            or_(
                MediaFile.mime_type.like("image/%"),
                (MediaFile.mime_type.like("video/%"))
                & (VideoPreview.status == "ready"),
            ),
            or_(DisplayPreview.sha256.is_(None), DisplayPreview.status == "processing"),
        )
        .order_by(MediaFile.file_size, MediaFile.id)
        .limit(1)
    )
    if not file:
        return False
    preview = db.get(DisplayPreview, file.sha256)
    if not preview:
        preview = DisplayPreview(sha256=file.sha256)
        db.add(preview)
    db.commit()
    image_source = file
    if file.file_role == "original" and file.mime_type.startswith("image/"):
        image_source = (
            db.scalar(
                select(MediaFile)
                .where(
                    MediaFile.media_id == file.media_id,
                    MediaFile.file_role == "preview",
                    MediaFile.upload_status == "complete",
                    MediaFile.mime_type.like("image/%"),
                )
                .order_by(MediaFile.id)
                .limit(1)
            )
            or file
        )
    try:
        with tempfile.TemporaryDirectory(prefix="yearly-display-") as directory:
            directory = Path(directory)
            thumbnail, image = directory / "thumbnail.webp", directory / "preview.webp"
            outputs = [("thumbnail", thumbnail)]
            if file.mime_type.startswith("video/"):
                video = db.get(VideoPreview, file.sha256)
                source = directory / "preview.mp4"
                storage.bucket.get_object_to_file(video.object_key, str(source))
                subprocess.run(
                    [
                        imageio_ffmpeg.get_ffmpeg_exe(),
                        "-loglevel",
                        "error",
                        "-y",
                        "-i",
                        str(source),
                        "-frames:v",
                        "1",
                        "-vf",
                        "scale=480:480:force_original_aspect_ratio=decrease",
                        "-c:v",
                        "libwebp",
                        "-quality",
                        "70",
                        "-threads",
                        "1",
                        str(thumbnail),
                    ],
                    check=True,
                    capture_output=True,
                )
            else:
                outputs.append(("image", image))
                try:
                    for field, target in outputs:
                        size, quality = (
                            (480, 70) if field == "thumbnail" else (1600, 80)
                        )
                        storage.bucket.get_object_to_file(
                            image_source.oss_object_key,
                            str(target),
                            process=f"image/resize,m_lfit,w_{size},h_{size},limit_1/format,webp/quality,q_{quality}",
                        )
                except oss2.exceptions.ServerError as exc:
                    if exc.code != "ImageTooLarge":
                        raise
                    # OSS rejects oversized input images. Decode the verified original locally.
                    source = directory / "original"
                    storage.bucket.get_object_to_file(
                        image_source.oss_object_key, str(source)
                    )
                    if (
                        source.stat().st_size != image_source.file_size
                        or hash_file(source) != image_source.sha256
                    ):
                        raise ValueError("原件完整性校验失败")
                    with Image.open(source) as original:
                        original.draft("RGB", (1600, 1600))
                        oriented = ImageOps.exif_transpose(original)
                        for field, target in reversed(outputs):
                            size, quality = (
                                (480, 70) if field == "thumbnail" else (1600, 80)
                            )
                            resized = oriented.copy()
                            resized.thumbnail((size, size), Image.Resampling.LANCZOS)
                            if resized.mode not in {"RGB", "RGBA"}:
                                resized = resized.convert("RGB")
                            resized.save(
                                target,
                                "WEBP",
                                quality=quality,
                                icc_profile=oriented.info.get("icc_profile", b""),
                            )
                            resized.close()
                        oriented.close()
            for field, target in outputs:
                with Image.open(target) as result:
                    if result.format != "WEBP":
                        raise ValueError("预览输出格式错误")
                    result.verify()
                key = f"previews/display-v1/{file.sha256}/{target.name}"
                storage.bucket.put_object_from_file(
                    key,
                    str(target),
                    headers={
                        "Content-Type": "image/webp",
                        "Cache-Control": "private, max-age=300",
                        "x-oss-storage-class": "Standard",
                    },
                )
                size = target.stat().st_size
                if storage.bucket.head_object(key).content_length != size:
                    raise ValueError("预览上传大小校验失败")
                setattr(preview, field + "_key", key)
                setattr(preview, field + "_size", size)
            preview.status, preview.error = "ready", ""
        log.info("Display preview ready: file=%s", file.id)
    except Exception as exc:
        preview.status, preview.error = "failed", type(exc).__name__
        log.error(
            "Display preview failed: file=%s type=%s", file.id, type(exc).__name__
        )
    db.commit()
    return True


def tag_archive_one(db, storage):
    file = db.scalar(
        select(MediaFile)
        .join(DisplayPreview, DisplayPreview.sha256 == MediaFile.sha256)
        .outerjoin(VideoPreview, VideoPreview.sha256 == MediaFile.sha256)
        .where(
            MediaFile.upload_status == "complete",
            MediaFile.archive_tagged_at.is_(None),
            MediaFile.oss_object_key.startswith("originals/"),
            DisplayPreview.status == "ready",
            or_(MediaFile.mime_type.like("image/%"), VideoPreview.status == "ready"),
        )
        .order_by(MediaFile.id)
        .limit(1)
    )
    if not file:
        return False
    storage.mark_archive_ready(file)
    file.archive_tagged_at = now()
    db.commit()
    log.info("Original archive eligible: file=%s", file.id)
    return True


def generate_previews(storage, watch=False, retry_failed=False):
    # One worker per database, including when local and server workers overlap.
    with engine.connect() as lock:
        if not lock.scalar(
            text("SELECT GET_LOCK(CONCAT(DATABASE(), '-video-preview'), 0)")
        ):
            raise RuntimeError("此数据库已有视频预览任务正在运行")
        try:
            with SessionLocal() as db:
                if retry_failed:
                    for model in (VideoPreview, DisplayPreview):
                        for row in db.scalars(
                            select(model).where(model.status == "failed")
                        ):
                            row.status = "processing"
                    db.commit()
                while True:
                    lock.execute(text("SELECT 1"))
                    video_work = generate_one(db, storage)
                    display_work = generate_display_one(db, storage)
                    archive_work = settings().oss_archive_originals and tag_archive_one(
                        db, storage
                    )
                    if not (video_work or display_work or archive_work):
                        if not watch:
                            break
                        db.rollback()
                        time.sleep(15)
        finally:
            lock.execute(
                text("SELECT RELEASE_LOCK(CONCAT(DATABASE(), '-video-preview'))")
            )
