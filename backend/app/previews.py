"""Sequential, regenerable video derivatives. Originals are never overwritten."""

import logging
import subprocess
import tempfile
import time
from pathlib import Path

import imageio_ffmpeg
from sqlalchemy import select, text, or_

from .backup import hash_file
from .db import SessionLocal, engine
from .models import Media, MediaFile, VideoPreview

log = logging.getLogger(__name__)


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
            Media.status == "active",
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
                    for row in db.scalars(
                        select(VideoPreview).where(VideoPreview.status == "failed")
                    ):
                        row.status = "processing"
                    db.commit()
                while True:
                    lock.execute(text("SELECT 1"))
                    if not generate_one(db, storage):
                        if not watch:
                            break
                        db.rollback()
                        time.sleep(15)
        finally:
            lock.execute(
                text("SELECT RELEASE_LOCK(CONCAT(DATABASE(), '-video-preview'))")
            )
