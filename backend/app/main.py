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
from sqlalchemy import select, delete, func, or_
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
    MediaChild,
    Event,
    EventChild,
    EventMedia,
)
from .schemas import ChildIn, MediaEdit, EventIn, BatchChildren, LoginIn, UserIn
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
)
from .age import milestones
from .storage import get_storage
from .uploads import router as upload_router

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
    lifespan=lifespan,
    docs_url="/api/docs" if settings().app_env == "test" else None,
    openapi_url="/api/openapi.json" if settings().app_env == "test" else None,
)
app.include_router(upload_router)


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
    return JSONResponse(
        {"detail": "OSS 请求失败，请检查配置或稍后重试"}, status_code=502
    )


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
        path="/",
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
    response.delete_cookie("yearly_session", path="/")
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


@app.get("/api/users")
def users(db=Depends(get_db), user=Depends(admin)):
    return [
        {"id": u.id, "username": u.username, "role": u.role, "active": u.active}
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
        require_active_media(db, data.avatar_media_id)
    child = Child(**data.model_dump())
    db.add(child)
    db.commit()
    return child_data(child)


@app.put("/api/children/{cid}")
def update_child(cid: int, data: ChildIn, db=Depends(get_db), user=Depends(editor)):
    child = require_row(db, Child, cid)
    if child.status == "deleted":
        raise HTTPException(404, "孩子档案已删除")
    if data.avatar_media_id and data.avatar_media_id != child.avatar_media_id:
        require_active_media(db, data.avatar_media_id)
    for key, value in data.model_dump().items():
        setattr(child, key, value)
    db.commit()
    return child_data(child)


@app.delete("/api/children/{cid}")
def delete_child(cid: int, confirm_name: str, db=Depends(get_db), user=Depends(admin)):
    child = require_row(db, Child, cid)
    if confirm_name != child.name:
        raise HTTPException(422, "请输入孩子名字确认删除")
    child.status = "deleted"
    db.execute(delete(MediaChild).where(MediaChild.child_id == cid))
    db.execute(delete(EventChild).where(EventChild.child_id == cid))
    db.commit()
    return {"ok": True}


@app.get("/api/children/{cid}/milestones")
def child_milestones(cid: int, db=Depends(get_db), user=Depends(current_user)):
    child = require_row(db, Child, cid)
    return milestones(child.birthday, date.today())


def require_active_media(db, mid):
    media = require_row(db, Media, mid)
    if media.status != "active":
        raise HTTPException(404, "媒体不可用")
    return media


@app.get("/api/media")
def media_list(
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
        select(Media).where(Media.status == status), MediaChild, Media, child_id, match
    )
    if start:
        query = query.where(Media.taken_at_local >= start)
    if end:
        query = query.where(Media.taken_at_local < end)
    if media_type:
        query = query.where(Media.media_type == media_type)
    if q:
        query = query.where(
            or_(
                Media.title.contains(q, autoescape=True),
                Media.remark.contains(q, autoescape=True),
                Media.location_name.contains(q, autoescape=True),
            )
        )
    total = db.scalar(select(func.count()).select_from(query.subquery()))
    rows = db.scalars(
        query.order_by(Media.taken_at_local.desc(), Media.id.desc())
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
    media = require_active_media(db, mid)
    set_children(db, mid, data.child_ids, MediaChild)
    for key, value in data.model_dump(exclude={"child_ids"}).items():
        setattr(media, key, value)
    apply_time(media)
    db.commit()
    db.expire_all()
    return media_data(db.get(Media, mid), detail=True)


@app.post("/api/media/batch-children")
def batch_children(data: BatchChildren, db=Depends(get_db), user=Depends(editor)):
    child_ids = validate_children(db, data.child_ids)
    for mid in set(data.media_ids):
        media = require_active_media(db, mid)
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


@app.delete("/api/media/{mid}")
def trash_media(mid: int, db=Depends(get_db), user=Depends(editor)):
    require_active_media(db, mid).status = "deleted"
    db.commit()
    return {"ok": True}


@app.post("/api/media/{mid}/restore")
def restore_media(mid: int, db=Depends(get_db), user=Depends(editor)):
    row = require_row(db, Media, mid)
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
    return {"url": storage.download_url(file, download), "expires_in": 300}


@app.get("/api/events")
def events(
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
    event = require_row(db, Event, eid)
    if event.status != "active":
        raise HTTPException(404, "事件已删除")
    return save_event(db, event, data)


@app.delete("/api/events/{eid}")
def delete_event(eid: int, db=Depends(get_db), user=Depends(editor)):
    require_row(db, Event, eid).status = "deleted"
    db.commit()
    return {"ok": True}


@app.post("/api/events/{eid}/restore")
def restore_event(eid: int, db=Depends(get_db), user=Depends(editor)):
    require_row(db, Event, eid).status = "active"
    db.commit()
    return {"ok": True}


@app.get("/api/stats")
def stats(db=Depends(get_db), user=Depends(current_user)):
    return {
        "media": db.scalar(
            select(func.count(Media.id)).where(Media.status == "active")
        ),
        "children": db.scalar(
            select(func.count(Child.id)).where(Child.status == "active")
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
        "yearly_permissions": "管理员管理成员与导出，成员编辑家庭内容，访客只读",
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


@app.get("/api/timeline")
def timeline(
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
    db=Depends(get_db),
    user=Depends(current_user),
):
    from sqlalchemy import literal, union_all, and_
    from .schemas import TimelineCursor

    media_query = filter_children(
        select(
            literal("media").label("kind"),
            Media.id.label("id"),
            Media.taken_at_local.label("sort_at"),
        ).where(Media.status == status),
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
        ).where(Event.status == status),
        EventChild,
        Event,
        child_id,
        match,
    )
    if start:
        media_query = media_query.where(Media.taken_at_local >= start)
        event_query = event_query.where(Event.start_at >= start)
    if end:
        media_query = media_query.where(Media.taken_at_local < end)
        event_query = event_query.where(Event.start_at < end)
    if q:
        media_query = media_query.where(
            or_(
                Media.title.contains(q, autoescape=True),
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
    mixed = union_all(media_query, event_query).subquery()
    total = db.scalar(select(func.count()).select_from(mixed))
    query = select(mixed).order_by(
        mixed.c.sort_at.desc(), mixed.c.id.desc(), mixed.c.kind.desc()
    )
    if cursor:
        try:
            position = TimelineCursor.model_validate_json(
                base64.urlsafe_b64decode(cursor)
            )
        except ValueError:
            raise HTTPException(422, "分页游标无效")
        earlier_id = or_(
            mixed.c.id < position.id,
            and_(mixed.c.id == position.id, mixed.c.kind < position.kind),
        )
        if position.sort_at is None:
            query = query.where(mixed.c.sort_at.is_(None), earlier_id)
        else:
            query = query.where(
                or_(
                    mixed.c.sort_at < position.sort_at,
                    mixed.c.sort_at.is_(None),
                    and_(mixed.c.sort_at == position.sort_at, earlier_id),
                )
            )
    else:
        query = query.offset((page - 1) * page_size)
    rows = db.execute(query.limit(page_size + 1)).mappings().all()
    has_more = len(rows) > page_size
    rows = rows[:page_size]
    next_cursor = None
    if has_more:
        position = TimelineCursor(**dict(rows[-1]))
        next_cursor = base64.urlsafe_b64encode(
            position.model_dump_json().encode()
        ).decode()
    media_ids = [r["id"] for r in rows if r["kind"] == "media"]
    event_ids = [r["id"] for r in rows if r["kind"] == "event"]
    media_map = {
        m.id: m for m in db.scalars(select(Media).where(Media.id.in_(media_ids)))
    }
    event_map = {
        e.id: e for e in db.scalars(select(Event).where(Event.id.in_(event_ids)))
    }
    items = []
    for row in rows:
        if row["kind"] == "media":
            items.append(
                {**media_data(media_map[row["id"]], child_id), "kind": "media"}
            )
        else:
            event = event_map[row["id"]]
            items.append(
                {
                    **event_data(event, child_id),
                    "kind": "event",
                    "taken_at_local": event.start_at,
                }
            )
    return {
        "items": items,
        "total": total,
        "page": page,
        "page_size": page_size,
        "next_cursor": next_cursor,
    }
