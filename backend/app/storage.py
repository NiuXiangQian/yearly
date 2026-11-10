from functools import lru_cache
from urllib.parse import quote
import oss2
from fastapi import HTTPException
from .config import settings


class OSSStorage:
    def __init__(self, internal=False):
        cfg = settings()
        if not all([cfg.oss_bucket, cfg.oss_access_key_id, cfg.oss_access_key_secret]):
            raise HTTPException(503, "尚未配置私有 OSS，请管理员完成配置")
        auth = oss2.AuthV4(cfg.oss_access_key_id, cfg.oss_access_key_secret)
        self.bucket = oss2.Bucket(
            auth,
            (
                cfg.oss_internal_endpoint
                if internal and cfg.oss_internal_endpoint
                else cfg.oss_custom_domain or cfg.oss_endpoint
            ),
            cfg.oss_bucket,
            is_cname=bool(cfg.oss_custom_domain)
            and not (internal and cfg.oss_internal_endpoint),
            region=cfg.oss_region,
            connect_timeout=30,
            enable_crc=True,
        )

    def initiate(self, file):
        return self.bucket.init_multipart_upload(
            file.oss_object_key,
            headers={
                "Content-Type": file.mime_type,
                "x-oss-storage-class": "Standard",
                "x-oss-meta-sha256": file.sha256,
                "x-oss-meta-client-crc64": file.crc64,
            },
        ).upload_id

    def parts(self, file, upload_id):
        parts = []
        marker = ""
        while True:
            result = self.bucket.list_parts(
                file.oss_object_key, upload_id, marker=marker
            )
            parts.extend(result.parts)
            if not result.is_truncated:
                return parts
            marker = result.next_marker

    def sign_part(self, file, upload_id, number):
        return self.bucket.sign_url(
            "PUT",
            file.oss_object_key,
            900,
            params={"uploadId": upload_id, "partNumber": str(number)},
        )

    def complete(self, file, upload_id, parts):
        self.bucket.complete_multipart_upload(
            file.oss_object_key,
            upload_id,
            [oss2.models.PartInfo(p.part_number, p.etag) for p in parts],
            headers={"x-oss-forbid-overwrite": "true"},
        )

    def head(self, file):
        result = self.bucket.head_object(file.oss_object_key)
        return {
            "size": result.content_length,
            "crc64": str(result.headers.get("x-oss-hash-crc64ecma", "")),
            "sha256": result.headers.get("x-oss-meta-sha256"),
        }

    def abort(self, file, upload_id):
        self.bucket.abort_multipart_upload(file.oss_object_key, upload_id)

    def download_url(self, file, attachment=False):
        params = {}
        if attachment:
            params["response-content-disposition"] = (
                "attachment; filename*=UTF-8''" + quote(file.original_filename)
            )
        return self.bucket.sign_url("GET", file.oss_object_key, 300, params=params)

    def image_url(self, file, purpose, expires=300):
        if file.mime_type.startswith("video/"):
            process = "video/snapshot,t_0,f_jpg,w_480,h_0,m_fast"
        elif file.mime_type.startswith("image/"):
            size, quality = (480, 70) if purpose == "thumbnail" else (1600, 80)
            process = f"image/resize,m_lfit,w_{size},h_{size},limit_1/format,webp/quality,q_{quality}"
        else:
            raise HTTPException(422, "此格式暂无压缩预览，请主动查看或下载原文件")
        return self.bucket.sign_url(
            "GET", file.oss_object_key, expires, params={"x-oss-process": process}
        )

    def video_url(self, preview, expires=300):
        return self.bucket.sign_url("GET", preview.object_key, expires)

    def display_url(self, preview, purpose, expires=300):
        key = preview.thumbnail_key if purpose == "thumbnail" else preview.image_key
        return self.bucket.sign_url("GET", key, expires)

    def original_status(self, file, headers=None):
        if headers is None:
            headers = self.bucket.head_object(file.oss_object_key).headers
        storage_class = headers.get("x-oss-storage-class", "Standard")
        if storage_class not in {"Archive", "ColdArchive", "DeepColdArchive"}:
            return "ready"
        restore = headers.get("x-oss-restore", "")
        if 'ongoing-request="false"' in restore:
            return "ready"
        return "restoring" if 'ongoing-request="true"' in restore else "archived"

    def restore_original(self, file):
        headers = self.bucket.head_object(file.oss_object_key).headers
        status = self.original_status(file, headers)
        if status != "archived":
            return status
        try:
            self.bucket.restore_object(
                file.oss_object_key,
                input=oss2.models.RestoreConfiguration(
                    days=1,
                    job_parameters=(
                        oss2.models.RestoreJobParameters("Bulk")
                        if headers.get("x-oss-storage-class")
                        in {"ColdArchive", "DeepColdArchive"}
                        else None
                    ),
                ),
            )
        except oss2.exceptions.RestoreAlreadyInProgress:
            pass
        return "restoring"

    def configure_archive(self):
        try:
            rules = self.bucket.get_bucket_lifecycle().rules
        except oss2.exceptions.NoSuchLifecycle:
            rules = []
        tags = oss2.models.TaggingRule()
        tags.add("yearly-preview", "ready-v1")
        rule = oss2.models.LifecycleRule(
            "yearly-originals-deep-archive-v1",
            "originals/",
            tagging=oss2.models.Tagging(tags),
            storage_transitions=[
                oss2.models.StorageTransition(days=1, storage_class="DeepColdArchive")
            ],
        )
        rules = [r for r in rules if r.id != rule.id]
        self.bucket.put_bucket_lifecycle(oss2.models.BucketLifecycle([*rules, rule]))

    def mark_archive_ready(self, file):
        tags = self.bucket.get_object_tagging(file.oss_object_key).tag_set
        tags.add("yearly-preview", "ready-v1")
        self.bucket.put_object_tagging(file.oss_object_key, oss2.models.Tagging(tags))


@lru_cache
def get_storage():
    return OSSStorage()


def preview_resource(db, storage, file, purpose, expires=300):
    from .models import DisplayPreview, VideoPreview, MediaFile
    from sqlalchemy import select

    if purpose == "preview" and file.mime_type.startswith("video/"):
        preview = db.get(VideoPreview, file.sha256)
        if not preview or preview.status != "ready":
            return {"url": None, "status": preview.status if preview else "pending"}
        return {
            "url": storage.video_url(preview, expires=expires),
            "status": "ready",
            "mime_type": "video/mp4",
            "file_size": preview.file_size,
        }
    sha256 = file.sha256
    if file.file_role == "preview":
        sha256 = (
            db.scalar(
                select(MediaFile.sha256)
                .where(
                    MediaFile.media_id == file.media_id,
                    MediaFile.file_role == "original",
                )
                .order_by(MediaFile.id)
                .limit(1)
            )
            or sha256
        )
    preview = db.get(DisplayPreview, sha256)
    if preview and preview.status == "ready":
        return {
            "url": storage.display_url(preview, purpose, expires=expires),
            "status": "ready",
            "mime_type": "image/webp",
            "file_size": (
                preview.thumbnail_size if purpose == "thumbnail" else preview.image_size
            ),
        }
    # Historical, still-warm originals remain browsable while the worker backfills derivatives.
    return {
        "url": storage.image_url(file, purpose, expires=expires),
        "status": "ready",
        "mime_type": (
            "image/jpeg" if file.mime_type.startswith("video/") else "image/webp"
        ),
    }


def verify_object(file, info):
    if (
        info["size"] != file.file_size
        or info["crc64"] != file.crc64
        or info["sha256"] != file.sha256
    ):
        raise HTTPException(409, "对象大小或完整性校验失败，请重新选择原文件核对")
