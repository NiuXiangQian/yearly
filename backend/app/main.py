import base64
import json
import logging
import secrets
from contextlib import asynccontextmanager
from datetime import date, datetime, timedelta
from typing import Literal
import oss2
from fastapi import FastAPI, Depends, HTTPException, Request, Response, Query
from fastapi.encoders import jsonable_encoder
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, Field
from sqlalchemy import select, delete, func, and_, or_, case, literal_column, cast, String
from sqlalchemy.exc import IntegrityError
from argon2.exceptions import VerificationError
from .config import settings
from .db import get_db, now, SessionLocal
from .models import (
    User,
    UserSession,
    LoginGuard,
    Captcha,
    Child,
    Media,
    MediaFile,
    UploadTask,
    TimelineFolder,
    TimelineDay,
    TimelineShare,
    VideoPreview,
    MediaChild,
    Event,
    EventChild,
    EventMedia,
    AuditLog,
)
from .schemas import (
    ChildIn,
    MediaEdit,
    EventIn,
    BatchChildren,
    BatchOrganize,
    MediaReorder,
    LoginIn,
    UserIn,
    UserEdit,
    TimelineCursor,
)
from .security import (
    current_user,
    editor,
    admin,
    make_captcha,
    passwords,
    digest,
    DUMMY_HASH,
)
from .services import (
    require_row,
    child_data,
    media_data,
    event_data,
    set_children,
    apply_time,
    save_event,
    filter_children,
    validate_children,
    timeline_time,
)
from .age import milestones
from .accounts import require_editable
from .storage import get_storage, preview_resource
from .shares import router as share_router
from .uploads import router as upload_router
from .folders import (
    router as folder_router,
    folder_data,
    active_folder,
    reorder_day_entries,
)

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s"
)
logging.getLogger("oss2").setLevel(logging.WARNING)


@asynccontextmanager
async def lifespan(app):
    cfg = settings()
    if len(cfg.session_secret) < 32:
        raise RuntimeError("SESSION_SECRET 至少需要 32 个随机字符")
    if cfg.app_env == "production" and (
        not cfg.cookie_secure or not cfg.allowed_origin.startswith("https://")
    ):
        raise RuntimeError("生产环境需要 HTTPS 和 Secure Cookie")
    yield


app = FastAPI(
    title="yearly",
    version="1.0.0",
    root_path=settings().app_base_path,
    lifespan=lifespan,
    docs_url="/api/docs" if settings().app_env == "test" else None,
    openapi_url="/api/openapi.json" if settings().app_env == "test" else None,
)
app.include_router(upload_router)
app.include_router(folder_router)
app.include_router(share_router)


@app.middleware("http")
async def security_headers(request: Request, call_next):
    # Metadata/API JSON only. Binary original traffic goes directly to OSS.
    if request.method in ("POST", "PUT", "PATCH"):
        length = request.headers.get("content-length")
        if length is None or not length.isdigit() or int(length) > 2 * 1024 * 1024:
            return JSONResponse(
                {"detail": "API 仅接受不超过 2 MiB 的 JSON，请将原件直传 OSS"},
                status_code=413,
            )
    response = await call_next(request)
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["X-Frame-Options"] = "DENY"
    return response


@app.exception_handler(oss2.exceptions.OssError)
def oss_error(request, exc):
    logging.getLogger("yearly").warning(
        "OSS operation failed type=%s status=%s",
        type(exc).__name__,
        getattr(exc, "status", None),
    )
    return JSONResponse({"detail": "OSS 请求失败，请检查配置或稍后重试"}, status_code=502)


@app.exception_handler(IntegrityError)
def conflict(request, exc):
    return JSONResponse({"detail": "记录冲突，请刷新后重试"}, status_code=409)


@app.get("/api/health")
def health(db=Depends(get_db)):
    db.execute(select(1))
    return {"status": "ok", "version": "1.0.0", "environment": settings().app_env}


def rate_guard(db, key, limit):
    guard = db.get(LoginGuard, key)
    if not guard or guard.reset_at <= now():
        if guard:
            db.delete(guard)
            db.flush()
        guard = LoginGuard(key=key, failures=0, reset_at=now() + timedelta(minutes=15))
        db.add(guard)
    if guard.failures >= limit:
        raise HTTPException(429, "尝试过于频繁，请在 15 分钟后重试")
    guard.failures += 1
    db.commit()
    return guard


@app.get("/api/auth/captcha")
def captcha(request: Request, db=Depends(get_db)):
    rate_guard(db, digest("captcha:" + request.client.host), 60)
    key, image = make_captcha(db)
    return {
        "id": key,
        "image": "data:image/png;base64," + base64.b64encode(image).decode(),
        "environment": settings().app_env,
    }


@app.post("/api/auth/login")
def login(payload: LoginIn, request: Request, response: Response, db=Depends(get_db)):
    if request.headers.get("origin") != settings().allowed_origin:
        raise HTTPException(403, "请求来源校验失败")
    guard = rate_guard(db, digest("login:" + request.client.host), 10)
    challenge = db.get(Captcha, payload.captcha_id)
    valid = (
        challenge
        and challenge.expires_at > now()
        and secrets.compare_digest(
            challenge.answer_hash, digest(payload.captcha.upper())
        )
    )
    if challenge:
        db.delete(challenge)
        db.commit()
    if not valid:
        raise HTTPException(400, "验证码不正确或已过期")
    user = db.scalar(select(User).where(User.username == payload.username))
    try:
        passwords.verify(user.password_hash if user else DUMMY_HASH, payload.password)
    except VerificationError:
        raise HTTPException(401, "用户名或密码不正确")
    if not user or not user.active:
        raise HTTPException(401, "用户名或密码不正确")
    guard.failures = 0
    token, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
    db.add(
        UserSession(
            id=digest(token),
            user_id=user.id,
            csrf_token=csrf,
            expires_at=now() + timedelta(hours=settings().session_hours),
        )
    )
    db.commit()
    response.set_cookie(
        "yearly_session",
        token,
        httponly=True,
        secure=settings().cookie_secure,
        samesite="strict",
        max_age=settings().session_hours * 3600,
        path=settings().app_base_path + "/",
    )
    return {
        "id": user.id,
        "username": user.username,
        "role": user.role,
        "csrf_token": csrf,
        "environment": settings().app_env,
    }


@app.get("/api/auth/me")
def me(request: Request, user=Depends(current_user)):
    return {
        "id": user.id,
        "username": user.username,
        "role": user.role,
        "csrf_token": request.state.session.csrf_token,
        "environment": settings().app_env,
    }


@app.post("/api/auth/logout")
def logout(
    request: Request, response: Response, db=Depends(get_db), user=Depends(current_user)
):
    db.delete(request.state.session)
    db.commit()
    response.delete_cookie("yearly_session", path=settings().app_base_path + "/")
    return {"ok": True}


class PasswordIn(BaseModel):
    old_password: str = Field(max_length=256)
    new_password: str = Field(min_length=12, max_length=256)


@app.post("/api/auth/password")
def change_password(data: PasswordIn, db=Depends(get_db), user=Depends(current_user)):
    try:
        passwords.verify(user.password_hash, data.old_password)
    except VerificationError:
        raise HTTPException(400, "当前密码不正确")
    user.password_hash = passwords.hash(data.new_password)
    db.execute(delete(UserSession).where(UserSession.user_id == user.id))
    db.commit()
    return {"ok": True}


@app.get("/api/uploaders")
def uploaders(db=Depends(get_db), user=Depends(current_user)):
    has_media = (
        select(Media.id)
        .where(
            Media.owner_id == User.id,
            Media.purpose == "memory",
            Media.status.in_(["active", "deleted"]),
        )
        .exists()
    )
    return [
        {"id": row.id, "username": row.username}
        for row in db.scalars(
            select(User).where(has_media).order_by(User.username, User.id)
        )
    ]


@app.get("/api/users")
def users(db=Depends(get_db), user=Depends(admin)):
    return [
        {
            "id": u.id,
            "username": u.username,
            "role": u.role,
            "active": u.active,
            "created_at": u.created_at,
            "updated_at": u.updated_at,
            "updated_by": u.updated_by,
        }
        for u in db.scalars(select(User))
    ]


@app.post("/api/users")
def create_user(data: UserIn, db=Depends(get_db), user=Depends(admin)):
    row = User(
        username=data.username,
        password_hash=passwords.hash(data.password),
        role=data.role,
    )
    db.add(row)
    db.commit()
    return {"id": row.id}


@app.put("/api/users/{uid}")
def update_user(uid: int, data: UserEdit, db=Depends(get_db), user=Depends(admin)):
    row = require_row(db, User, uid)
    if uid == user.id and (not data.active or data.role != "admin"):
        raise HTTPException(422, "当前管理员不能停用自己或降低自己的权限")
    credentials_changed = (
        data.password is not None
        or row.role != data.role
        or row.username != data.username
        or not data.active
    )
    if row.role != data.role:
        for share in db.scalars(
            select(TimelineShare).where(
                TimelineShare.created_by == uid, TimelineShare.revoked.is_(False)
            )
        ):
            share.revoked = True
    row.username = data.username
    row.role = data.role
    row.active = data.active
    if data.password is not None:
        row.password_hash = passwords.hash(data.password)
    if credentials_changed:
        db.execute(delete(UserSession).where(UserSession.user_id == uid))
    db.commit()
    return {"ok": True, "reauthenticate": credentials_changed and uid == user.id}


@app.get("/api/audit-logs")
def audit_logs(
    resource_type: Literal[
        "media",
        "timeline_folder",
        "child",
        "timeline_event",
        "timeline_day",
        "timeline_share",
        "sys_user",
    ]
    | None = None,
    resource_id: str | None = Query(default=None, max_length=80),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=20, ge=1, le=100),
    db=Depends(get_db),
    user=Depends(current_user),
):
    query = select(AuditLog)
    if user.role != "admin":
        owned = []
        for model, owner in (
            (Media, Media.owner_id),
            (TimelineFolder, TimelineFolder.owner_id),
            (Child, Child.owner_id),
            (Event, Event.created_by),
            (TimelineShare, TimelineShare.created_by),
        ):
            owned.append(
                and_(
                    AuditLog.resource_type == model.__tablename__,
                    AuditLog.resource_id.in_(
                        select(
                            cast(model.id, String).collate("utf8mb4_unicode_ci")
                        ).where(owner == user.id)
                    ),
                )
            )
        query = query.where(
            or_(
                AuditLog.actor_id == user.id,
                *owned,
                and_(
                    AuditLog.resource_type == "sys_user",
                    AuditLog.resource_id == str(user.id),
                ),
            )
        )
    if resource_type:
        query = query.where(AuditLog.resource_type == resource_type)
    if resource_id:
        query = query.where(AuditLog.resource_id == resource_id)
    total = db.scalar(select(func.count()).select_from(query.subquery()))
    rows = db.scalars(
        query.order_by(AuditLog.id.desc())
        .offset((page - 1) * page_size)
        .limit(page_size)
    )
    return {
        "items": [
            {c.name: getattr(row, c.name) for c in AuditLog.__table__.columns}
            for row in rows
        ],
        "total": total,
    }


@app.delete("/api/users/{uid}")
def disable_user(uid: int, db=Depends(get_db), user=Depends(admin)):
    if uid == user.id:
        raise HTTPException(422, "无法停用当前账户")
    require_row(db, User, uid).active = False
    db.execute(delete(UserSession).where(UserSession.user_id == uid))
    db.commit()
    return {"ok": True}


@app.get("/api/children")
def children(db=Depends(get_db), user=Depends(current_user)):
    return [
        child_data(c)
        for c in db.scalars(
            select(Child)
            .where(Child.status != "deleted")
            .order_by(Child.sort_order, Child.id)
        )
    ]


@app.post("/api/children")
def create_child(data: ChildIn, db=Depends(get_db), user=Depends(editor)):
    if data.avatar_media_id:
        require_avatar_image(db, data.avatar_media_id)
    values = data.model_dump()
    if "growth_enabled" not in data.model_fields_set:
        values["growth_enabled"] = (
            data.profile_type in {"child", "pet"} or data.relationship == "孩子"
        )
    child = Child(**values, owner_id=user.id)
    db.add(child)
    db.commit()
    return child_data(child)


@app.put("/api/children/{cid}")
def update_child(cid: int, data: ChildIn, db=Depends(get_db), user=Depends(editor)):
    child = require_editable(user, require_row(db, Child, cid))
    if child.status == "deleted":
        raise HTTPException(404, "档案已删除")
    if data.avatar_media_id and data.avatar_media_id != child.avatar_media_id:
        require_avatar_image(db, data.avatar_media_id)
    for key, value in data.model_dump().items():
        # Older clients omit these fields; preserve the existing profile type and details.
        if (
            key
            in {"profile_type", "relationship", "species", "breed", "growth_enabled"}
            and key not in data.model_fields_set
        ):
            continue
        setattr(child, key, value)
    db.commit()
    return child_data(child)


@app.delete("/api/children/{cid}")
def delete_child(cid: int, confirm_name: str, db=Depends(get_db), user=Depends(admin)):
    child = require_row(db, Child, cid)
    if confirm_name != child.name:
        raise HTTPException(422, "请输入名字确认删除")
    child.status = "deleted"
    for media in db.scalars(select(Media).join(MediaChild).where(MediaChild.child_id == cid)):
        set_children(db, media.id, [c.id for c in media.children if c.id != cid and c.status != "deleted"], MediaChild)
    for event in db.scalars(select(Event).join(EventChild).where(EventChild.child_id == cid)):
        set_children(db, event.id, [c.id for c in event.children if c.id != cid and c.status != "deleted"], EventChild)
    db.commit()
    return {"ok": True}


@app.get("/api/children/{cid}/milestones")
def child_milestones(cid: int, db=Depends(get_db), user=Depends(current_user)):
    child = require_row(db, Child, cid)
    return milestones(child.birthday, date.today()) if child.growth_enabled else []


def require_active_media(db, mid):
    media = require_row(db, Media, mid)
    if media.status != "active":
        raise HTTPException(404, "媒体不可用")
    return media


def require_avatar_image(db, mid):
    media = require_active_media(db, mid)
    if media.media_type != "photo":
        raise HTTPException(422, "头像需要选择静态照片")
    return media


@app.get("/api/media")
def media_list(
    folder_id: int | None = Query(default=None, ge=1),
    owner_id: int | None = Query(default=None, ge=1),
    child_id: list[int] = Query(default=[]),
    match: Literal["any", "all"] = "any",
    start: datetime | None = None,
    end: datetime | None = None,
    q: str = Query(default="", max_length=200),
    media_type: Literal["photo", "video", "live_photo"] | None = None,
    status: Literal["active", "deleted"] = "active",
    page: int = Query(default=1, ge=1, le=1000000),
    page_size: int = Query(default=40, ge=1, le=100),
    db=Depends(get_db),
    user=Depends(current_user),
):
    query = filter_children(
        select(Media).where(Media.status == status, Media.purpose == "memory"),
        MediaChild,
        Media,
        child_id,
        match,
    )
    if owner_id is not None:
        query = query.where(Media.owner_id == owner_id)
    if folder_id is not None:
        active_folder(db, folder_id)
        query = query.where(Media.folder_id == folder_id)
    if start:
        query = query.where(timeline_time() >= start)
    if end:
        query = query.where(timeline_time() < end)
    if media_type:
        query = query.where(Media.media_type == media_type)
    if q:
        query = query.where(
            or_(
                Media.title.contains(q, autoescape=True),
                Media.batch_name.contains(q, autoescape=True),
                Media.remark.contains(q, autoescape=True),
                Media.location_name.contains(q, autoescape=True),
            )
        )
    total = db.scalar(select(func.count()).select_from(query.subquery()))
    rows = db.scalars(
        query.order_by(
            func.date(timeline_time()).desc(),
            Media.sort_order.desc(),
            Media.taken_at_local.desc(),
            Media.id.desc(),
        )
        .offset((page - 1) * page_size)
        .limit(page_size)
    )
    return {
        "items": [media_data(m, child_id) for m in rows],
        "total": total,
        "page": page,
        "page_size": page_size,
    }


@app.get("/api/media/{mid}")
def media_detail(mid: int, db=Depends(get_db), user=Depends(current_user)):
    return media_data(require_active_media(db, mid), detail=True)


@app.put("/api/media/{mid}")
def edit_media(mid: int, data: MediaEdit, db=Depends(get_db), user=Depends(editor)):
    media = require_editable(user, require_active_media(db, mid))
    previous_day = media.timeline_date or (
        media.taken_at_local.date() if media.taken_at_local else None
    )
    set_children(db, mid, data.child_ids, MediaChild)
    excluded = {"child_ids"} | (
        {"batch_name", "timeline_date", "share_allowed"} - data.model_fields_set
    )
    for key, value in data.model_dump(exclude=excluded).items():
        setattr(media, key, value)
    apply_time(media)
    current_day = media.timeline_date or (
        media.taken_at_local.date() if media.taken_at_local else None
    )
    if current_day != previous_day:
        media.sort_order = 0
        media.folder_id = None
    db.commit()
    db.expire_all()
    return media_data(db.get(Media, mid), detail=True)


@app.post("/api/media/batch-children")
def batch_children(data: BatchChildren, db=Depends(get_db), user=Depends(editor)):
    child_ids = validate_children(db, data.child_ids)
    for mid in set(data.media_ids):
        media = require_editable(user, require_active_media(db, mid))
        current = {c.id for c in media.children if c.status != "deleted"}
        ids = (
            child_ids
            if data.mode == "replace"
            else current | child_ids
            if data.mode == "add"
            else current - child_ids
        )
        set_children(db, mid, ids, MediaChild)
    db.commit()
    return {"ok": True}


@app.post("/api/media/batch-organize")
def organize_media(data: BatchOrganize, db=Depends(get_db), user=Depends(editor)):
    changes = data.model_dump(exclude={"media_ids"}, exclude_unset=True)
    if not changes:
        raise HTTPException(422, "请选择批次名称或归档日期")
    rows = [require_editable(user, require_active_media(db, mid)) for mid in set(data.media_ids)]
    for media in rows:
        if "batch_name" in changes:
            media.batch_name = (data.batch_name or "").strip()
        if "timeline_date" in changes:
            media.timeline_date = data.timeline_date
            media.sort_order = 0
            if media.folder_id:
                folder = db.get(TimelineFolder, media.folder_id)
                current_day = media.timeline_date or (
                    media.taken_at_local.date() if media.taken_at_local else None
                )
                if current_day != folder.timeline_date:
                    media.folder_id = None
    db.commit()
    return {"ok": True, "count": len(rows)}


class TimelineEntryRef(BaseModel):
    kind: Literal["media", "folder"]
    id: int = Field(ge=1)


class TimelineReorder(BaseModel):
    items: list[TimelineEntryRef] = Field(min_length=1, max_length=1000)
    target: TimelineEntryRef
    placement: Literal["before", "after"] = "before"


@app.post("/api/timeline/reorder")
def reorder_timeline(data: TimelineReorder, db=Depends(get_db), user=Depends(editor)):
    ordered = reorder_day_entries(
        db,
        [(item.kind, item.id) for item in data.items],
        (data.target.kind, data.target.id),
        data.placement,
        user,
    )
    db.commit()
    return {"items": [{"kind": kind, "id": id} for kind, id in ordered]}


class ResetMediaOrder(BaseModel):
    day: date | None
    folder_id: int | None = Field(default=None, ge=1)


@app.post("/api/media/reset-order")
def reset_media_order(data: ResetMediaOrder, db=Depends(get_db), user=Depends(editor)):
    if data.folder_id:
        folder = active_folder(db, data.folder_id)
        if folder.timeline_date != data.day:
            raise HTTPException(422, "文件夹与日期不一致")
    day_column = func.date(timeline_time())
    query = select(Media).where(
        Media.status == "active", Media.purpose == "memory",
        day_column == data.day if data.day else day_column.is_(None),
    )
    if data.folder_id:
        require_editable(user, folder)
        query = query.where(Media.folder_id == data.folder_id)
    rows = list(db.scalars(query))
    folders = list(db.scalars(select(TimelineFolder).where(
        TimelineFolder.status == "active", TimelineFolder.timeline_date == data.day,
    ))) if not data.folder_id and data.day else []
    for row in [*rows, *folders]:
        require_editable(user, row)
    for row in [*rows, *folders]:
        row.sort_order = 0
    db.commit()
    return {"ok": True, "count": len(rows)}


@app.post("/api/media/reorder")
def reorder_media(data: MediaReorder, db=Depends(get_db), user=Depends(editor)):
    target = require_active_media(db, data.target_id)
    if not target.folder_id:
        ordered = reorder_day_entries(
            db,
            [("media", mid) for mid in data.media_ids],
            ("media", data.target_id),
            data.placement,
            user,
        )
        db.commit()
        return {"media_ids": [id for kind, id in ordered if kind == "media"]}
    day = target.timeline_date or (
        target.taken_at_local.date() if target.taken_at_local else None
    )
    day_column = func.date(timeline_time())
    rows = list(
        db.scalars(
            select(Media)
            .where(
                Media.status == "active",
                day_column == day if day else day_column.is_(None),
                Media.folder_id == target.folder_id
                if target.folder_id
                else Media.folder_id.is_(None),
            )
            .order_by(
                Media.sort_order.desc(), Media.taken_at_local.desc(), Media.id.desc()
            )
            .with_for_update()
        )
    )
    for row in rows:
        require_editable(user, row)
    moving_ids = set(data.media_ids)
    if data.target_id in moving_ids or not moving_ids.issubset({m.id for m in rows}):
        raise HTTPException(422, "只能调整同一天的影像，放置位置不能是已选影像")
    by_id = {m.id: m for m in rows}
    moving = [by_id[mid] for mid in dict.fromkeys(data.media_ids)]
    remaining = [m for m in rows if m.id not in moving_ids]
    index = next(i for i, m in enumerate(remaining) if m.id == data.target_id)
    if data.placement == "after":
        index += 1
    ordered = remaining[:index] + moving + remaining[index:]
    for index, media in enumerate(ordered):
        media.sort_order = len(ordered) - index
    db.commit()
    return {"media_ids": [m.id for m in ordered]}


@app.delete("/api/media/{mid}")
def trash_media(mid: int, db=Depends(get_db), user=Depends(editor)):
    require_editable(user, require_active_media(db, mid)).status = "deleted"
    db.commit()
    return {"ok": True}


@app.post("/api/media/{mid}/restore")
def restore_media(mid: int, db=Depends(get_db), user=Depends(editor)):
    row = require_editable(user, require_row(db, Media, mid))
    if row.status != "deleted":
        raise HTTPException(422, "媒体不在回收站")
    row.status = "active"
    db.commit()
    return {"ok": True}


@app.get("/api/media/{mid}/files/{fid}/url")
def file_url(
    mid: int,
    fid: int,
    download: bool = False,
    purpose: Literal["thumbnail", "preview", "original"] = "preview",
    db=Depends(get_db),
    user=Depends(current_user),
    storage=Depends(get_storage),
):
    media = require_active_media(db, mid)
    file = next(
        (f for f in media.files if f.id == fid and f.upload_status == "complete"), None
    )
    if not file:
        raise HTTPException(404, "原件不存在")
    if download or purpose == "original":
        status = storage.original_status(file)
        if status != "ready":
            return {"url": None, "status": status, "message": "原件已深度归档，解冻通常需要48小时，完成后可下载1天。"}
        return {
            "url": storage.download_url(file, download),
            "expires_in": 300,
            "mime_type": file.mime_type,
            "file_size": file.file_size,
            "status": "ready",
        }
    resource = preview_resource(db, storage, file, purpose)
    if resource["url"]:
        resource["expires_in"] = 300
    return resource


@app.post("/api/media/{mid}/files/{fid}/restore")
def restore_original(
    mid: int, fid: int, db=Depends(get_db), user=Depends(current_user),
    storage=Depends(get_storage),
):
    media = require_active_media(db, mid)
    file = next((f for f in media.files if f.id == fid and f.upload_status == "complete"), None)
    if not file:
        raise HTTPException(404, "原件不存在")
    return {"status": storage.restore_original(file),
            "message": "解冻通常需要48小时，完成后可下载1天。"}


@app.get("/api/events")
def events(
    owner_id: int | None = Query(default=None, ge=1),
    child_id: list[int] = Query(default=[]),
    match: Literal["any", "all"] = "any",
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=30, ge=1, le=100),
    db=Depends(get_db),
    user=Depends(current_user),
):
    query = filter_children(
        select(Event).where(Event.status == "active"),
        EventChild,
        Event,
        child_id,
        match,
    )
    if owner_id is not None:
        query = query.where(Event.created_by == owner_id)
    total = db.scalar(select(func.count()).select_from(query.subquery()))
    rows = db.scalars(
        query.order_by(Event.start_at.desc(), Event.id.desc())
        .offset((page - 1) * page_size)
        .limit(page_size)
    )
    return {"items": [event_data(e, child_id) for e in rows], "total": total}


@app.post("/api/events")
def create_event(data: EventIn, db=Depends(get_db), user=Depends(editor)):
    return save_event(db, Event(created_by=user.id), data)


@app.get("/api/events/{eid}")
def get_event(eid: int, db=Depends(get_db), user=Depends(current_user)):
    event = require_row(db, Event, eid)
    if event.status != "active":
        raise HTTPException(404, "事件已删除")
    data = event_data(event)
    data["media"] = [
        media_data(m)
        for link in event.media_links
        if (m := db.get(Media, link.media_id)) and m.status == "active"
    ]
    return data


@app.put("/api/events/{eid}")
def edit_event(eid: int, data: EventIn, db=Depends(get_db), user=Depends(editor)):
    event = require_editable(user, require_row(db, Event, eid))
    if event.status != "active":
        raise HTTPException(404, "事件已删除")
    return save_event(db, event, data)


@app.delete("/api/events/{eid}")
def delete_event(eid: int, db=Depends(get_db), user=Depends(editor)):
    require_editable(user, require_row(db, Event, eid)).status = "deleted"
    db.commit()
    return {"ok": True}


@app.post("/api/events/{eid}/restore")
def restore_event(eid: int, db=Depends(get_db), user=Depends(editor)):
    require_editable(user, require_row(db, Event, eid)).status = "active"
    db.commit()
    return {"ok": True}


@app.get("/api/stats")
def stats(db=Depends(get_db), user=Depends(current_user)):
    return {
        "media": db.scalar(
            select(func.count(Media.id)).where(
                Media.status == "active", Media.purpose == "memory"
            )
        ),
        "children": db.scalar(
            select(func.count(Child.id)).where(
                Child.status == "active",
                or_(
                    Child.profile_type == "child",
                    (Child.profile_type == "person") & (Child.relationship == "孩子"),
                ),
            )
        ),
        "people": db.scalar(
            select(func.count(Child.id)).where(
                Child.status == "active", Child.profile_type.in_(["child", "person"])
            )
        ),
        "pets": db.scalar(
            select(func.count(Child.id)).where(
                Child.status == "active", Child.profile_type == "pet"
            )
        ),
        "events": db.scalar(
            select(func.count(Event.id)).where(Event.status == "active")
        ),
        "bytes": db.scalar(
            select(func.coalesce(func.sum(MediaFile.file_size), 0)).where(
                MediaFile.upload_status == "complete"
            )
        ),
    }


@app.get("/api/settings")
def system_settings(user=Depends(admin)):
    cfg = settings()
    return {
        "storage_configured": bool(
            cfg.oss_bucket and cfg.oss_access_key_id and cfg.oss_access_key_secret
        ),
        "bucket": cfg.oss_bucket,
        "region": cfg.oss_region,
        "custom_domain": cfg.oss_custom_domain,
        "max_file_size": cfg.max_file_size,
        "part_size": cfg.upload_part_size,
        "registration": False,
        "preview_policy": "原件独立保存，可选上传兼容预览，不执行服务端转码",
        "yearly_permissions": "管理员拥有全部管理权限，普通账户只能编辑自己添加的内容，历史访客只读",
    }


@app.get("/api/export/manifest")
def export_manifest(user=Depends(admin)):
    from .backup import manifest_stream

    return StreamingResponse(
        manifest_stream(),
        media_type="application/json",
        headers={"Content-Disposition": 'attachment; filename="yearly-manifest.json"'},
    )


@app.get("/api/export/files.csv")
def export_csv(user=Depends(admin)):
    from .backup import csv_stream

    return StreamingResponse(
        csv_stream(),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": 'attachment; filename="yearly-files.csv"'},
    )


def timeline_ordering(source, order):
    return [
        (source.c.sort_day, order == "asc", True),
        (source.c.sort_order, False, False),
        (source.c.sort_group, False, False),
        (source.c.sort_at, order == "asc", True),
        (source.c.id, False, False),
        (source.c.kind, False, False),
    ]


def timeline_boundary(ordering, position, *, before, inclusive=False):
    # Old cursors only contain sort_at; derive their day for compatibility.
    day = position.sort_day or (position.sort_at.date() if position.sort_at else None)
    values = (day, position.sort_order, position.sort_group, position.sort_at, position.id, position.kind)
    prefix, alternatives = [], []
    for (column, ascending, nullable), value in zip(ordering, values):
        if value is not None:
            comparison = column > value if ascending != before else column < value
            if nullable and not before:
                comparison = or_(comparison, column.is_(None))
            alternatives.append(and_(*prefix, comparison))
            prefix.append(column == value)
        else:
            if before:
                alternatives.append(and_(*prefix, column.is_not(None)))
            prefix.append(column.is_(None))
    if inclusive:
        alternatives.append(and_(*prefix))
    return or_(*alternatives)


def timeline_media_positions(db, media_query, rows, order):
    if not rows:
        return {}
    first = TimelineCursor(**dict(rows[0]), order=order)
    media = media_query.subquery()
    day = media.c.sort_day
    prior_on_first_day = and_(
        day == first.sort_day,
        timeline_boundary(timeline_ordering(media, order), first, before=True),
    )
    # Count within the current filters, including days outside the loaded cursor window.
    groups = db.execute(
        select(day, func.count(), func.count(case((prior_on_first_day, 1))))
        .group_by(day)
        .order_by(day.is_(None), day.asc() if order == "asc" else day.desc())
    ).all()
    counts = {value: count for value, count, _ in groups}
    previous_in_day = {value: earlier for value, _, earlier in groups}
    index = 0
    for value, count, earlier in groups:
        if value == first.sort_day:
            index += earlier
            break
        index += count
    total = sum(counts.values())
    positions = {}
    for row in rows:
        value = row["sort_day"]
        index += 1
        previous_in_day[value] += 1
        positions[row["id"]] = {
            "index": index,
            "total": total,
            "day_index": previous_in_day[value],
            "day_total": counts[value],
        }
    return positions


@app.get("/api/timeline")
def timeline(
    group_folders: bool = False,
    owner_id: int | None = Query(default=None, ge=1),
    child_id: list[int] = Query(default=[]),
    match: Literal["any", "all"] = "any",
    start: datetime | None = None,
    end: datetime | None = None,
    q: str = Query(default="", max_length=200),
    media_type: Literal["photo", "video", "live_photo"] | None = None,
    status: Literal["active", "deleted"] = "active",
    page: int = Query(default=1, ge=1, le=1000000),
    page_size: int = Query(default=40, ge=1, le=100),
    cursor: str | None = Query(default=None, max_length=512),
    date_basis: Literal["timeline", "capture", "upload"] = "timeline",
    anchor_media_id: int | None = Query(default=None, ge=1),
    anchor_day: date | None = None,
    include_dates: bool = False,
    timezone_offset_minutes: int = Query(default=0, ge=-840, le=840),
    before: bool = False,
    order: Literal["asc", "desc"] = "desc",
    media_positions: bool = False,
    db=Depends(get_db),
    user=Depends(current_user),
):
    from sqlalchemy import literal, union_all

    upload_order = date_basis == "upload"
    if anchor_media_id is not None and (date_basis != "timeline" or group_folders):
        raise HTTPException(422, "只能在归档时间线定位影像")
    if anchor_day is not None and anchor_media_id is not None:
        raise HTTPException(422, "请选择日期或影像中的一种定位方式")
    if before and anchor_media_id is None and anchor_day is None:
        raise HTTPException(422, "加载较新的记录需要归档位置")
    sort_time = Media.taken_at_local
    sort_day = func.date(timeline_time())
    sort_position = Media.sort_order
    if upload_order:
        # The last verified resource completes the logical media. Restored records
        # may have no upload tasks, so fall back to their original creation time.
        completed_at = (
            select(func.max(UploadTask.updated_at))
            .where(UploadTask.media_id == Media.id, UploadTask.status == "complete")
            .correlate(Media)
            .scalar_subquery()
        )
        sort_time = func.coalesce(completed_at, Media.created_at)
        sort_day = func.date(func.timestampadd(literal_column("MINUTE"), timezone_offset_minutes, sort_time))
        sort_position = literal(0)
    media_query = filter_children(
        select(
            literal("media").label("kind"),
            Media.id.label("id"),
            sort_time.label("sort_at"),
            sort_day.label("sort_day"),
            sort_position.label("sort_order"),
            literal(0).label("sort_group"),
        ).where(Media.status == status, Media.purpose == "memory"),
        MediaChild,
        Media,
        child_id,
        match,
    )
    event_query = filter_children(
        select(
            literal("event").label("kind"),
            Event.id.label("id"),
            Event.start_at.label("sort_at"),
            func.date(Event.start_at).label("sort_day"),
            literal(0).label("sort_order"),
            literal(0).label("sort_group"),
        ).where(Event.status == status),
        EventChild,
        Event,
        child_id,
        match,
    )
    if owner_id is not None:
        media_query = media_query.where(Media.owner_id == owner_id)
        event_query = event_query.where(Event.created_by == owner_id)
    filter_time = sort_time if date_basis != "timeline" else timeline_time()
    if start:
        media_query = media_query.where(filter_time >= start)
        event_query = event_query.where(Event.start_at >= start)
    if end:
        media_query = media_query.where(filter_time < end)
        event_query = event_query.where(Event.start_at < end)
    if q:
        media_query = media_query.where(
            or_(
                Media.title.contains(q, autoescape=True),
                Media.batch_name.contains(q, autoescape=True),
                Media.remark.contains(q, autoescape=True),
                Media.location_name.contains(q, autoescape=True),
            )
        )
        event_query = event_query.where(
            or_(
                Event.title.contains(q, autoescape=True),
                Event.content.contains(q, autoescape=True),
            )
        )
    if media_type:
        media_query = media_query.where(Media.media_type == media_type)
        event_query = event_query.where(literal(False))
    queries = [media_query] if upload_order else [media_query, event_query]
    if group_folders and status == "active" and date_basis == "timeline":
        # Reuse the already-filtered media query so folders respect child, search and type filters.
        matching = select(Media.folder_id).where(
            Media.id.in_(media_query.with_only_columns(Media.id))
        )
        folder_query = select(
            literal("folder").label("kind"),
            TimelineFolder.id.label("id"),
            literal(None).label("sort_at"),
            TimelineFolder.timeline_date.label("sort_day"),
            TimelineFolder.sort_order.label("sort_order"),
            literal(1).label("sort_group"),
        ).where(TimelineFolder.status == "active")
        if start:
            folder_query = folder_query.where(
                TimelineFolder.timeline_date >= start.date()
            )
        if end:
            folder_query = folder_query.where(TimelineFolder.timeline_date < end.date())
        if child_id or q or media_type or owner_id is not None:
            visible = TimelineFolder.id.in_(matching)
            if not q and not media_type and owner_id is None:
                visible = or_(
                    visible,
                    ~select(Media.id)
                    .where(
                        Media.folder_id == TimelineFolder.id, Media.status == "active"
                    )
                    .exists(),
                )
            folder_query = folder_query.where(visible)
        queries = [
            media_query.where(Media.folder_id.is_(None)),
            event_query,
            folder_query,
        ]
    mixed = (media_query if upload_order else union_all(*queries)).subquery()
    total = db.scalar(select(func.count()).select_from(mixed))
    ordering = timeline_ordering(mixed, order)
    sort_clauses = []
    for column, ascending, nullable in ordering:
        if nullable:
            null_rank = column.is_(None)
            sort_clauses.append(null_rank.desc() if before else null_rank.asc())
        sort_clauses.append(column.asc() if ascending != before else column.desc())
    query = select(mixed).order_by(*sort_clauses)
    if cursor and cursor.startswith("upload.") != upload_order:
        raise HTTPException(422, "切换时间线视图后请重新加载")
    position = None
    if cursor:
        try:
            position = TimelineCursor.model_validate_json(
                base64.urlsafe_b64decode(cursor.removeprefix("upload."))
            )
        except ValueError:
            raise HTTPException(422, "分页游标无效")
        if position.order != order:
            raise HTTPException(422, "切换时间顺序后请重新加载")
    elif anchor_media_id is not None:
        anchor = db.execute(
            select(mixed).where(mixed.c.kind == "media", mixed.c.id == anchor_media_id)
        ).mappings().one_or_none()
        if anchor is None:
            raise HTTPException(404, "归档位置已不可用")
        position = TimelineCursor(**dict(anchor), order=order)
    if position is not None:
        query = query.where(timeline_boundary(
            ordering, position, before=before, inclusive=not cursor and not before
        ))
    elif anchor_day is not None:
        day = mixed.c.sort_day
        boundary = day > anchor_day if (order == "asc") != before else day < anchor_day
        if not before:
            boundary = or_(boundary, day == anchor_day, day.is_(None))
        query = query.where(boundary)
    else:
        query = query.offset((page - 1) * page_size)
    rows = db.execute(query.limit(page_size + 1)).mappings().all()
    has_more = len(rows) > page_size
    rows = rows[:page_size]
    if before:
        rows.reverse()
    next_cursor = None
    previous_cursor = None
    if has_more:
        position = TimelineCursor(**dict(rows[0] if before else rows[-1]), order=order)
        continuation = base64.urlsafe_b64encode(
            position.model_dump_json().encode()
        ).decode()
        if before:
            previous_cursor = "upload." + continuation if upload_order else continuation
        else:
            next_cursor = "upload." + continuation if upload_order else continuation
    media_ids = [r["id"] for r in rows if r["kind"] == "media"]
    event_ids = [r["id"] for r in rows if r["kind"] == "event"]
    folder_ids = [r["id"] for r in rows if r["kind"] == "folder"]
    folder_map = {
        f.id: f
        for f in db.scalars(
            select(TimelineFolder).where(TimelineFolder.id.in_(folder_ids))
        )
    }
    folder_counts = dict(
        db.execute(
            select(Media.folder_id, func.count())
            .where(
                Media.folder_id.in_(folder_ids),
                Media.status == "active",
                *([Media.owner_id == owner_id] if owner_id is not None else []),
            )
            .group_by(Media.folder_id)
        ).all()
    )
    # Fetch at most four matching thumbnails per visible folder in one MySQL 5.7 query.
    folder_previews = {fid: [] for fid in folder_ids}
    if folder_ids:
        preview_queries = []
        for fid in folder_ids:
            limited = (
                media_query.with_only_columns(Media.id)
                .where(Media.folder_id == fid)
                .order_by(
                    Media.sort_order.desc(),
                    Media.taken_at_local.desc(),
                    Media.id.desc(),
                )
                .limit(4)
                .subquery()
            )
            preview_queries.append(select(limited.c.id))
        preview_ids = union_all(*preview_queries).subquery()
        for media in db.scalars(
            select(Media)
            .join(preview_ids, Media.id == preview_ids.c.id)
            .order_by(
                Media.sort_order.desc(), Media.taken_at_local.desc(), Media.id.desc()
            )
        ).unique():
            folder_previews[media.folder_id].append(media_data(media, child_id))
    media_map = {
        m.id: m for m in db.scalars(select(Media).where(Media.id.in_(media_ids)))
    }
    positions = timeline_media_positions(
        db, media_query, [row for row in rows if row["kind"] == "media"], order
    ) if media_positions and not group_folders else {}
    event_map = {
        e.id: e for e in db.scalars(select(Event).where(Event.id.in_(event_ids)))
    }
    items = []
    for row in rows:
        if row["kind"] == "media":
            item = {**media_data(media_map[row["id"]], child_id), "kind": "media"}
            if row["id"] in positions:
                item["media_position"] = positions[row["id"]]
            if upload_order:
                item["uploaded_at"] = row["sort_at"]
            items.append(item)
        elif row["kind"] == "folder":
            items.append(
                {
                    **folder_data(
                        folder_map[row["id"]], folder_counts.get(row["id"], 0)
                    ),
                    "previews": folder_previews[row["id"]],
                }
            )
        else:
            event = event_map[row["id"]]
            items.append(
                {
                    **event_data(event, child_id),
                    "kind": "event",
                    "taken_at_local": event.start_at,
                    "timeline_day": event.start_at.date() if event.start_at else None,
                }
            )
    return {
        "items": items,
        "total": total,
        "page": page,
        "page_size": page_size,
        "next_cursor": next_cursor,
        **({"dates": db.scalars(
            select(mixed.c.sort_day).where(mixed.c.sort_day.is_not(None))
            .distinct().order_by(mixed.c.sort_day)
        ).all()} if include_dates else {}),
        **({"previous_cursor": previous_cursor} if before else {}),
        "day_sharing": {
            row.timeline_date.isoformat(): row.share_allowed
            for row in db.scalars(
                select(TimelineDay).where(
                    TimelineDay.timeline_date.in_(
                        [item["timeline_day"] for item in items if item["timeline_day"]]
                    )
                )
            )
        },
    }
