from functools import lru_cache
from urllib.parse import quote
import oss2
from fastapi import HTTPException
from .config import settings


class OSSStorage:
    def __init__(self):
        cfg = settings()
        if not all([cfg.oss_bucket, cfg.oss_access_key_id, cfg.oss_access_key_secret]):
            raise HTTPException(503, "尚未配置私有 OSS，请管理员完成配置")
        auth = oss2.AuthV4(cfg.oss_access_key_id, cfg.oss_access_key_secret)
        self.bucket = oss2.Bucket(
            auth,
            cfg.oss_custom_domain or cfg.oss_endpoint,
            cfg.oss_bucket,
            is_cname=bool(cfg.oss_custom_domain),
            region=cfg.oss_region,
            connect_timeout=30,
            enable_crc=True,
        )

    def initiate(self, file):
        return self.bucket.init_multipart_upload(
            file.oss_object_key,
            headers={
                "Content-Type": file.mime_type,
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


@lru_cache
def get_storage():
    return OSSStorage()


def verify_object(file, info):
    if (
        info["size"] != file.file_size
        or info["crc64"] != file.crc64
        or info["sha256"] != file.sha256
    ):
        raise HTTPException(409, "对象大小或完整性校验失败，请重新选择原文件核对")
