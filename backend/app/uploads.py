import json
import hashlib
import math
from datetime import timedelta
from pathlib import PurePath
from uuid import UUID, uuid4
import oss2
from fastapi import APIRouter, Depends, HTTPException, Query, Header, Response
from sqlalchemy import select
from .db import get_db, now
from .models import Media, MediaFile, MediaMetadata, UploadTask, User
from .schemas import UploadIn
from .security import editor
from .accounts import require_editable, can_edit
from .services import require_row, set_children, apply_time, validate_children
from .models import MediaChild
from .storage import get_storage, verify_object
from .config import settings

router = APIRouter(prefix="/api/uploads", tags=["uploads"])
EXTENSIONS = {
    "jpg",
    "jpeg",
    "png",
    "heic",
    "heif",
    "webp",
    "dng",
    "cr2",
    "cr3",
    "nef",
    "arw",
    "orf",
    "rw2",
    "raf",
    "mp4",
    "mov",
}
VIDEO = {"mp4", "mov"}


def task_data(task, file):
    return {
        "id": task.id,
        "media_id": task.media_id,
        "file_id": file.id,
        "filename": file.original_filename,
        "sha256": file.sha256,
        "file_size": file.file_size,
        "file_role": file.file_role,
        "status": task.status,
        "part_size": task.part_size,
        "expires_at": task.expires_at,
    }


def owned_task(db, tid, user):
    task = require_row(db, UploadTask, tid)
    if task.owner_id != user.id and user.role != "admin":
        raise HTTPException(403, "只能管理自己的上传任务")
    if task.expires_at < now() and task.status != "complete":
        raise HTTPException(410, "上传任务已过期")
    return task, require_row(db, MediaFile, task.file_id)


@router.post("")
def create_upload(
    data: UploadIn,
    idempotency_key: str | None = Header(default=None, max_length=36),
    db=Depends(get_db),
    user=Depends(editor),
    storage=Depends(get_storage),
):
    cfg = settings()
    # All upload creators share a short DB-only critical section. A per-owner lock
    # cannot prevent two family members reserving the same originals concurrently.
    # Use an existing stable row; no MySQL-8 feature or schema migration is needed.
    db.scalar(select(User.id).order_by(User.id).limit(1).with_for_update())
    # Opt-in for durable native clients. Existing browser requests keep their behavior.
    # The shared creation lock also serializes first-use receipts without a JSON unique index.
    # The receipt lives in existing metadata; no schema or OSS key changes are needed.
    receipt = None
    if idempotency_key is not None:
        try:
            key = str(UUID(idempotency_key))
        except ValueError:
            raise HTTPException(422, "Idempotency-Key 必须为 UUID")
        fingerprint = hashlib.sha256(
            json.dumps(
                data.model_dump(mode="json"),
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=False,
            ).encode()
        ).hexdigest()
        previous = db.scalar(
            select(MediaMetadata)
            .join(Media, Media.id == MediaMetadata.media_id)
            .where(
                Media.owner_id == user.id,
                MediaMetadata.raw_metadata["_upload_receipt"]["key"].as_string()
                == key,
            )
            .with_for_update()
        )
        if previous:
            if previous.raw_metadata["_upload_receipt"]["fingerprint"] != fingerprint:
                raise HTTPException(409, "同一上传请求不能更换文件或归档信息")
            media = db.scalar(select(Media).where(Media.id == previous.media_id).with_for_update())
            if media.status not in ("uploading", "active"):
                raise HTTPException(409, "原上传媒体已不可用")
            tasks = db.scalars(
                select(UploadTask)
                .where(UploadTask.media_id == media.id)
                .order_by(UploadTask.file_id)
                .with_for_update()
            ).all()
            if any(t.status != "complete" and t.expires_at < now() for t in tasks):
                raise HTTPException(410, "上传任务已过期")
            return {
                "media_id": media.id,
                "timeline_day": media.timeline_date
                or (media.taken_at_local.date() if media.taken_at_local else None),
                "tasks": [task_data(t, db.scalar(select(MediaFile).where(
                    MediaFile.id == t.file_id
                ).with_for_update())) for t in tasks],
            }
        receipt = {"key": key, "fingerprint": fingerprint}
    # This internal namespace cannot be supplied by clients, even without the header.
    data.metadata.pop("_upload_receipt", None)
    if data.folder_id:
        from .folders import active_folder

        folder = require_editable(user, active_folder(db, data.folder_id, user))
        if data.timeline_date and data.timeline_date != folder.timeline_date:
            raise HTTPException(422, "文件夹与归档日期不一致")
        data.timeline_date = folder.timeline_date
    validate_children(db, data.child_ids)
    if len(json.dumps(data.metadata, ensure_ascii=False)) > 1024 * 1024:
        raise HTTPException(413, "元数据超过 1 MiB 限制")
    for f in data.files:
        ext = PurePath(f.original_filename).suffix.lower().lstrip(".")
        if ext not in EXTENSIONS or f.file_size > cfg.max_file_size:
            raise HTTPException(422, "格式不受支持或文件超过大小限制")
        if f.file_role == "live_video" and ext != "mov":
            raise HTTPException(422, "Live Photo 动态原件需为 MOV")
        if f.file_role == "original" and (
            (data.media_type == "video") != (ext in VIDEO)
        ):
            raise HTTPException(422, "媒体类型与文件格式不一致")
        if f.file_role == "preview" and ext not in {
            "jpg",
            "jpeg",
            "png",
            "webp",
            "mp4",
        }:
            raise HTTPException(422, "兼容预览格式不受支持")
    # Match the complete original resource set, including both Live Photo resources.
    # Preview files and filenames do not change the identity of an original.
    original = next(f for f in data.files if f.file_role == "original")
    signature = sorted(
        (f.file_role, f.sha256, f.file_size)
        for f in data.files
        if f.file_role != "preview"
    )
    candidates = db.scalars(
        select(Media)
        .join(MediaFile, MediaFile.media_id == Media.id)
        .where(
            Media.status.in_(["active", "uploading"]),
            Media.purpose == data.purpose,
            Media.media_type == data.media_type,
            MediaFile.file_role == "original",
            MediaFile.sha256 == original.sha256,
        )
        .order_by(Media.id)
        .with_for_update()
    ).unique()
    for existing in candidates:
        # Locking reads see commits made while waiting for the creation lock even
        # under MySQL REPEATABLE READ; lazy relationships would use an old snapshot.
        existing_files = db.scalars(select(MediaFile).where(
            MediaFile.media_id == existing.id
        ).with_for_update()).all()
        if (
            sorted(
                (f.file_role, f.sha256, f.file_size)
                for f in existing_files
                if f.file_role != "preview"
            )
            != signature
        ):
            continue
        if existing.status == "uploading":
            tasks = db.scalars(select(UploadTask).where(
                UploadTask.media_id == existing.id,
                UploadTask.status != "complete",
                UploadTask.expires_at >= now(),
            ).with_for_update()).all()
            if tasks:
                raise HTTPException(409, "相同原件已有未完成上传，请继续原任务，不能重复创建")
            continue
        if any(f.upload_status != "complete" for f in existing_files if f.file_role != "preview"):
            continue
        if not can_edit(user, existing):
            return {
                "media_id": existing.id,
                "timeline_day": existing.timeline_date or (existing.taken_at_local.date() if existing.taken_at_local else None),
                "tasks": [], "duplicate": True,
                "notice": "相同原件已存在且已锁定，已跳过重复上传",
            }
        existing_child_ids = db.scalars(select(MediaChild.child_id).where(
            MediaChild.media_id == existing.id
        ).with_for_update()).all()
        child_ids = sorted(set(existing_child_ids) | set(data.child_ids))
        set_children(db, existing.id, child_ids, MediaChild)
        db.commit()
        notice = "已存在，已跳过重复上传；保留已有日期和信息"
        if any(f.file_role == "preview" for f in data.files):
            notice += "；此次附带的预览未重新保存"
        return {
            "media_id": existing.id,
            "timeline_day": existing.timeline_date
            or (existing.taken_at_local.date() if existing.taken_at_local else None),
            "tasks": [],
            "duplicate": True,
            "notice": notice,
        }
    fields = data.model_dump(exclude={"files", "metadata", "child_ids", "time_source"})
    media = Media(**fields, owner_id=user.id, original_time_source=data.time_source)
    apply_time(media)
    db.add(media)
    db.flush()
    set_children(db, media.id, data.child_ids, MediaChild)
    db.add(
        MediaMetadata(
            media_id=media.id,
            raw_metadata={
                **data.metadata,
                **({"_upload_receipt": receipt} if receipt else {}),
            },
            parser_name="ImageIO + AVFoundation"
            if data.metadata.get("source") == "ios_photokit"
            else "exifr + bounded ISO-BMFF",
            parser_version="1",
            parse_status=data.metadata.get("parse_status", "partial"),
            parse_error=data.metadata.get("parse_error"),
        )
    )
    tasks = []
    for f in data.files:
        ext = PurePath(f.original_filename).suffix.lower()
        mime = {
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "png": "image/png",
            "webp": "image/webp",
            "heic": "image/heic",
            "heif": "image/heif",
            "mov": "video/quicktime",
            "mp4": "video/mp4",
        }.get(ext.lstrip("."), "application/octet-stream")
        file = MediaFile(
            **{**f.model_dump(), "mime_type": mime},
            media_id=media.id,
            oss_bucket=cfg.oss_bucket,
            oss_object_key=f"{'avatars' if data.purpose == 'avatar' else 'previews' if f.file_role == 'preview' else 'originals'}/{now():%Y/%m}/{uuid4().hex}{ext}",
        )
        db.add(file)
        db.flush()
        task = UploadTask(
            id=str(uuid4()),
            owner_id=user.id,
            media_id=media.id,
            file_id=file.id,
            part_size=max(cfg.upload_part_size, math.ceil(f.file_size / 9999)),
            expires_at=now() + timedelta(days=7),
        )
        db.add(task)
        db.flush()
        tasks.append(task_data(task, file))
    # Initiation is lazy, so a partially failed create never leaves untracked OSS uploads.
    db.commit()
    return {
        "media_id": media.id,
        "timeline_day": media.timeline_date
        or (media.taken_at_local.date() if media.taken_at_local else None),
        "tasks": tasks,
    }


@router.get("")
def list_uploads(response: Response, db=Depends(get_db), user=Depends(editor)):
    # Native clients check this before their first create; older servers must not
    # silently ignore Idempotency-Key and create duplicates after a lost response.
    response.headers["X-Yearly-Upload-Protocol"] = "idempotent-v1"
    tasks = db.scalars(
        select(UploadTask)
        .where(
            UploadTask.owner_id == user.id,
            UploadTask.status.in_(["pending", "uploading"]),
            UploadTask.expires_at > now(),
        )
        .order_by(UploadTask.created_at.desc())
    )
    return [task_data(t, db.get(MediaFile, t.file_id)) for t in tasks]


@router.get("/{tid}")
def upload_status(
    tid: str, db=Depends(get_db), user=Depends(editor), storage=Depends(get_storage)
):
    task, file = owned_task(db, tid, user)
    parts = (
        storage.parts(file, task.oss_upload_id)
        if task.oss_upload_id and task.status == "uploading"
        else []
    )
    return {
        **task_data(task, file),
        "parts": [{"number": p.part_number, "size": p.size} for p in parts],
    }


@router.post("/{tid}/sign")
def sign_part(
    tid: str,
    number: int = Query(ge=1, le=10000),
    db=Depends(get_db),
    user=Depends(editor),
    storage=Depends(get_storage),
):
    task, file = owned_task(db, tid, user)
    if task.status not in ("pending", "uploading"):
        raise HTTPException(409, "任务当前不可上传")
    if number > math.ceil(file.file_size / task.part_size):
        raise HTTPException(422, "分片序号超过文件大小")
    # Lock the task while creating its single multipart upload ID.
    task = db.scalar(
        select(UploadTask)
        .where(UploadTask.id == tid)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if not task.oss_upload_id:
        task.oss_upload_id = storage.initiate(file)
        task.status = "uploading"
        db.commit()
    return {
        "url": storage.sign_part(file, task.oss_upload_id, number),
        "expires_in": 900,
    }


@router.post("/{tid}/complete")
def complete_upload(
    tid: str, db=Depends(get_db), user=Depends(editor), storage=Depends(get_storage)
):
    task, file = owned_task(db, tid, user)
    db.scalar(select(Media).where(Media.id == task.media_id).with_for_update())
    task = db.scalar(
        select(UploadTask)
        .where(UploadTask.id == tid)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if task.status == "complete":
        return {"status": "complete", "media_id": task.media_id}
    if task.status != "uploading":
        raise HTTPException(409, "请先上传文件分片")
    # HEAD also recovers a completion whose OSS response or following DB commit was interrupted.
    try:
        info = storage.head(file)
    except oss2.exceptions.NoSuchKey:
        parts = storage.parts(file, task.oss_upload_id)
        count = math.ceil(file.file_size / task.part_size)
        if [p.part_number for p in parts] != list(range(1, count + 1)):
            raise HTTPException(409, "分片不完整")
        for p in parts:
            expected = min(
                task.part_size, file.file_size - (p.part_number - 1) * task.part_size
            )
            if p.size != expected:
                raise HTTPException(409, "分片大小不正确")
        storage.complete(file, task.oss_upload_id, parts)
        info = storage.head(file)
    verify_object(file, info)
    file.upload_status = "complete"
    task.status = "complete"
    task.updated_at = now()
    db.flush()
    remaining = db.scalar(
        select(UploadTask.id)
        .where(UploadTask.media_id == task.media_id, UploadTask.status != "complete")
        .limit(1)
        .with_for_update()
    )
    media = db.get(Media, task.media_id)
    if not remaining and media.status == "uploading":
        media.status = "active"
    db.commit()
    return {"status": "complete", "media_id": task.media_id}
