"""Public sharing has its own allowlisted payload and never grants original access."""
import hashlib
import hmac
import re
import secrets
from base64 import urlsafe_b64encode
from collections import defaultdict
from datetime import date, timedelta
from html import escape
from typing import Literal, Annotated
from types import SimpleNamespace

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from fastapi.responses import HTMLResponse, RedirectResponse
from pydantic import BaseModel, ConfigDict, Field, model_validator
from sqlalchemy import select, func, literal, union_all, or_, case
from sqlalchemy.dialects.mysql import insert

from .age import age_at
from .config import settings
from .db import get_db, now
from .models import (
    TimelineShare,
    ShareVisit,
    Media,
    TimelineFolder,
    Event,
    User,
    VideoPreview,
    TimelineDay,
    Child,
    MediaChild,
    EventChild,
)
from .security import editor, admin
from .services import timeline_time, filter_children
from .share_cover import default_share_avatar_ids, group_cover, share_avatar_ids
from .visibility import sharing_visibility
from .storage import get_storage, preview_resource

router = APIRouter(prefix="/api", tags=["sharing"])


class ShareCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    title: str = Field(default="", max_length=120)
    start_date: date | None = None
    end_date: date | None = None
    media_ids: list[Annotated[int, Field(gt=0, strict=True)]] | None = Field(default=None, min_length=1, max_length=200)
    hours: int = Field(default=24, ge=1, le=168)
    profile_ids: list[Annotated[int, Field(gt=0, strict=True)]] = Field(default_factory=list)

    @model_validator(mode="after")
    def date_order(self):
        if self.media_ids is not None:
            if self.start_date is not None or self.end_date is not None:
                raise ValueError("指定影像分享不能同时设置日期范围")
            self.media_ids = list(dict.fromkeys(self.media_ids))
        elif self.start_date is None or self.end_date is None or self.end_date < self.start_date:
            raise ValueError("请提供有效的起止日期，结束日期不能早于开始日期")
        self.profile_ids = list(dict.fromkeys(self.profile_ids))
        return self


def share_info(db, share, default_avatar_ids=None):
    profiles = share.profiles
    profile = profiles[0] if len(profiles) == 1 else None
    names = "、".join(p.nickname or p.name for p in profiles[:2])
    if len(profiles) > 2:
        names += f"等 {len(profiles)} 位"
    title = share.title or "我们的家庭时光"
    description = "一起看看这些珍藏的照片与视频。记录成长，留住相聚的瞬间。"
    if names:
        title = f"{names} · {share.title}" if share.title else f"{names}的时光"
        description = f"一起看看{names}的照片与视频，珍藏每一个值得记住的瞬间。"
    return {
        "id": share.id,
        "scope": "selection" if share.media_ids is not None else "date_range",
        "selected_count": len(share.media_ids) if share.media_ids is not None else None,
        "title": share.title,
        "profile_ids": share.profile_ids,
        "profile_name": (profile.nickname or profile.name) if profile else None,
        "has_avatar": bool(share_avatar_ids(db, share, default_avatar_ids)),
        "card_title": title,
        "card_description": description,
        "start_date": share.start_date,
        "end_date": share.end_date,
        "expires_at": share.expires_at.isoformat() + "Z",
        "revoked": share.revoked,
        "expired": share.expires_at <= now(),
    }


def share_token(share):
    # Reconstruct current links with a domain-separated server secret. The DB still
    # stores only a hash, and links created with older secrets remain valid.
    identity = f"yearly-share:v1:{share.id}:{share.created_by}:{share.created_at.isoformat()}"
    return urlsafe_b64encode(
        hmac.digest(settings().session_secret.encode(), identity.encode(), "sha256")
    ).decode().rstrip("=")


def token_hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


def share_site():
    config = settings()
    return config.allowed_origin.rstrip("/") + config.app_base_path


def saved_token(share):
    token = share_token(share)
    return token if hmac.compare_digest(token_hash(token), share.token_hash) else None


def managed_share(sid, db, user):
    share = db.get(TimelineShare, sid)
    if not share or (user.role != "admin" and share.created_by != user.id):
        raise HTTPException(404, "分享不存在")
    return share


@router.post("/shares")
def create_share(data: ShareCreate, response: Response, db=Depends(get_db), user=Depends(editor)):
    return save_share(data, response, db, user, user.id if user.role != "admin" else None)


def save_share(data, response, db, user, owner_scope_id):
    profiles = db.scalars(select(Child).where(
        Child.id.in_(data.profile_ids), Child.status != "deleted",
    ).order_by(Child.id)).all() if data.profile_ids else []
    if len(profiles) != len(data.profile_ids):
        raise HTTPException(422, "关联的人物或宠物不存在")
    if data.media_ids is not None:
        # Validate the same permissions used by all public endpoints. Never silently
        # replace missing/hidden items with a broader date or folder scope.
        selected, _ = shared_queries(SimpleNamespace(media_ids=data.media_ids, owner_scope_id=owner_scope_id))
        visible = set(db.scalars(selected.with_only_columns(Media.id)))
        if visible != set(data.media_ids):
            raise HTTPException(422, "部分影像不存在、已删除或不允许分享，请重新选择")
        if profiles and db.scalar(filter_children(
            selected, MediaChild, Media, data.profile_ids, "any",
        ).with_only_columns(Media.id).limit(1)) is None:
            raise HTTPException(422, "所选影像没有关联任何已勾选的人物")
    share = TimelineShare(
        token_hash=secrets.token_hex(32),
        created_by=user.id,
        owner_scope_id=owner_scope_id,
        title=data.title.strip(),
        profiles=profiles,
        media_ids=data.media_ids,
        # Selection shares use a single virtual page, not a capture/archive date.
        start_date=data.start_date if data.media_ids is None else now().date(),
        end_date=data.end_date if data.media_ids is None else now().date(),
        expires_at=now() + timedelta(hours=data.hours),
    )
    db.add(share)
    db.flush()
    db.refresh(share)
    token = share_token(share)
    share.token_hash = token_hash(token)
    db.commit()
    response.headers["Cache-Control"] = "no-store"
    return {
        **share_info(db, share), "token": token, "link_available": True,
        "can_copy": True, "visit_count": 0, "visitor_count": 0,
    }


@router.get("/shares")
def list_shares(db=Depends(get_db), user=Depends(editor)):
    query = select(TimelineShare)
    if user.role != "admin":
        query = query.where(TimelineShare.created_by == user.id)
    shares = db.scalars(query.order_by(TimelineShare.id.desc()).limit(100)).all()
    default_avatar_ids = default_share_avatar_ids(db) if any(not s.profiles for s in shares) else []
    counts = {
        row.share_id: {"visit_count": row.visits, "visitor_count": row.visitors}
        for row in db.execute(
            select(
                ShareVisit.share_id,
                func.sum(ShareVisit.visit_count).label("visits"),
                func.count().label("visitors"),
            )
            .where(ShareVisit.share_id.in_([s.id for s in shares]))
            .group_by(ShareVisit.share_id)
        )
    }
    return [
        {
            **share_info(db, s, default_avatar_ids),
            **counts.get(s.id, {"visit_count": 0, "visitor_count": 0}),
            "link_available": saved_token(s) is not None,
            "can_copy": True,
        }
        for s in shares
    ]


@router.get("/shares/{sid}/link")
def read_share_link(sid: int, response: Response, db=Depends(get_db), user=Depends(editor)):
    share = managed_share(sid, db, user)
    if share.revoked or share.expires_at <= now():
        raise HTTPException(404, "分享链接不可用")
    token = saved_token(share)
    if token is None:
        raise HTTPException(409, "此记录无法找回原链接，可按原范围创建新链接")
    response.headers["Cache-Control"] = "no-store"
    return {"token": token}


class ShareCopy(BaseModel):
    hours: int = Field(default=24, ge=1, le=168)


@router.post("/shares/{sid}/copy")
def copy_share(sid: int, data: ShareCopy, response: Response, db=Depends(get_db), user=Depends(editor)):
    share = managed_share(sid, db, user)
    scope = (
        {"media_ids": share.media_ids} if share.media_ids is not None
        else {"start_date": share.start_date, "end_date": share.end_date}
    )
    return save_share(ShareCreate(title=share.title, profile_ids=share.profile_ids, hours=data.hours, **scope), response, db, user, share.owner_scope_id)


@router.delete("/shares/{sid}")
def revoke_share(sid: int, db=Depends(get_db), user=Depends(editor)):
    share = managed_share(sid, db, user)
    share.revoked = True
    db.commit()
    return {"ok": True}


def public_share(token: str, response: Response, db=Depends(get_db)):
    response.headers["X-Robots-Tag"] = "noindex, nofollow, noarchive"
    share = db.scalar(
        select(TimelineShare).where(
            TimelineShare.token_hash == token_hash(token)
        )
    )
    if not share or share.revoked or share.expires_at <= now():
        raise HTTPException(404, "分享已失效或不存在")
    owner = db.get(User, share.created_by)
    if not owner or not owner.active or owner.role not in ("admin", "member"):
        raise HTTPException(404, "分享已失效或不存在")
    if any(profile.status == "deleted" for profile in share.profiles):
        raise HTTPException(404, "分享已失效或不存在")
    return share


@router.get("/public/shares/{token}/page", response_class=HTMLResponse)
def share_page(token: str, response: Response, db=Depends(get_db)):
    status = 200
    try:
        info = share_info(db, public_share(token, response, db))
    except HTTPException as error:
        status = error.status_code
        info = {
            "card_title": "分享已失效或不存在",
            "card_description": "请联系分享者获取新的链接",
            "has_avatar": False,
        }
    config = settings()
    base = share_site()
    image = f"{base}/api/public/shares/{token}/avatar" if info["has_avatar"] else f"{base}/share-logo.png"
    title, description, image = (
        escape(value, quote=True)
        for value in (info["card_title"], info["card_description"], image)
    )
    entry = config.app_base_path + "/share-entry.js"
    logo = config.app_base_path + "/share-logo.png"
    return HTMLResponse(f'''<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta name="robots" content="noindex, nofollow, noarchive">
  <meta name="referrer" content="no-referrer">
  <meta name="theme-color" content="#f3f5f7">
  <title>{title}</title>
  <meta name="description" content="{description}">
  <meta property="og:type" content="website">
  <meta property="og:site_name" content="yearly">
  <meta property="og:title" content="{title}">
  <meta property="og:description" content="{description}">
  <meta property="og:image" content="{image}">
  <link rel="image_src" href="{image}">
  <link rel="icon" href="{image}">
  <style>
    body:has(.share-cover) {{ margin: 0; background: #f3f5f7; color: #202d3c; }}
    .share-cover {{ box-sizing: border-box; max-width: 1040px; margin: auto; padding: 0 16px; font: 14px/1.6 system-ui, sans-serif; }}
    .share-cover header {{ position: relative; display: grid; place-content: center; min-height: 54px; border-bottom: 1px solid #d6dfe8; font-weight: 650; font-size: 16px; }}
    .share-cover header img {{ position: absolute; left: 0; top: 14px; border-radius: 6px; }}
    .share-cover section {{ padding: 14px 0; border-bottom: 1px solid #d6dfe8; }}
    .share-cover h1 {{ margin: 0 0 3px; font: 650 clamp(21px, 4vw, 27px)/1.25 "Songti SC", Georgia, serif; overflow-wrap: anywhere; }}
    .share-cover p {{ margin: 0; color: #526478; }}
    @media (max-width: 540px) {{ .share-cover {{ padding: 0 12px; }} }}
    @media (prefers-color-scheme: dark) {{
      body:has(.share-cover) {{ background: #141c27; color: #edf3fa; }}
      .share-cover header, .share-cover section {{ border-color: #354559; }}
      .share-cover p {{ color: #a6b7cb; }}
    }}
  </style>
</head>
<body>
  <div id="app">
    <main class="share-cover">
      <header><img src="{logo}" alt="yearly" width="26" height="26">成长时间线</header>
      <section>
        <h1>{title}</h1>
        <p>{description}</p>
      </section>
    </main>
  </div>
  <script type="module" src="{entry}"></script>
</body>
</html>''', status_code=status, headers={
        "Cache-Control": "no-store",
        "X-Robots-Tag": response.headers["X-Robots-Tag"],
    })


@router.get("/public/shares/{token}/avatar")
def share_avatar(
    token: str,
    redirect: bool = True,
    share=Depends(public_share),
    db=Depends(get_db),
    storage=Depends(get_storage),
):
    avatar_ids = share_avatar_ids(db, share)
    if not avatar_ids:
        raise HTTPException(404, "分享头像不存在")
    if len(share.profiles) != 1:
        site = share_site()
        if not redirect:
            return {
                "url": f"{site}/api/public/shares/{token}/avatar",
                "status": "ready",
                "mime_type": "image/png",
            }
        cover = group_cover(db, storage, avatar_ids)
        if share.expires_at <= now():
            raise HTTPException(404, "分享已失效或不存在")
        headers = {"Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow, noarchive"}
        if cover is None:
            return RedirectResponse(f"{site}/share-logo.png", status_code=302, headers=headers)
        return Response(content=cover, media_type="image/png", headers=headers)
    avatar = db.get(Media, avatar_ids[0])
    if not avatar or avatar.status != "active":
        raise HTTPException(404, "分享头像不存在")
    file = next(
        (f for f in avatar.files if f.file_role == "original" and f.upload_status == "complete"),
        None,
    )
    if not file:
        raise HTTPException(404, "分享头像不存在")
    ttl = min(60, max(1, int((share.expires_at - now()).total_seconds())))
    resource = preview_resource(db, storage, file, "thumbnail", expires=ttl)
    if not resource["url"]:
        raise HTTPException(404, "分享头像正在准备")
    if redirect:
        return RedirectResponse(resource["url"], status_code=302)
    return resource


@router.post("/public/shares/{token}/visits")
def record_visit(
    request: Request, response: Response, share=Depends(public_share), db=Depends(get_db)
):
    client = request.cookies.get("yearly_share_client", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]{43}", client):
        client = secrets.token_urlsafe(32)
    db.execute(
        insert(ShareVisit)
        .values(share_id=share.id, client_hash=token_hash(client), visit_count=1)
        .on_duplicate_key_update(visit_count=ShareVisit.visit_count + 1)
    )
    db.commit()
    response.set_cookie(
        "yearly_share_client", client,
        max_age=365 * 24 * 3600,
        path=settings().app_base_path + "/api/public/shares",
        httponly=True,
        secure=settings().cookie_secure,
        samesite="lax",
    )
    response.headers["Cache-Control"] = "no-store"
    return {"ok": True}


class DaySharing(BaseModel):
    share_allowed: bool


@router.put("/timeline/days/{day}/sharing")
def update_day_sharing(
    day: date, data: DaySharing, db=Depends(get_db), user=Depends(admin)
):
    preference = db.get(TimelineDay, day)
    if preference is None:
        preference = TimelineDay(timeline_date=day)
        db.add(preference)
    preference.share_allowed = data.share_allowed
    db.commit()
    return {"day": day, "share_allowed": preference.share_allowed}


def shared_queries(share):
    """Apply the same scope to the flat timeline and direct media access."""
    day = func.date(timeline_time())

    selection = share is not None and share.media_ids is not None

    def in_range(column):
        limits = (column >= share.start_date, column <= share.end_date) if share and not selection else ()
        return limits if selection else (*limits, column.is_not(None))

    folders = select(TimelineFolder).where(
        TimelineFolder.status == "active",
        *in_range(TimelineFolder.timeline_date),
        sharing_visibility(TimelineFolder),
    )
    media = select(Media).where(
        Media.status == "active",
        Media.purpose == "memory",
        *in_range(day),
        sharing_visibility(Media),
        or_(
            Media.folder_id.is_(None),
            Media.folder_id.in_(folders.with_only_columns(TimelineFolder.id)),
        ),
    )
    events = select(Event).where(
        Event.status == "active",
        *in_range(func.date(Event.start_at)),
        sharing_visibility(Event),
    )
    if share is not None and getattr(share, "owner_scope_id", None) is not None:
        media = media.where(Media.owner_id == share.owner_scope_id)
        events = events.where(Event.created_by == share.owner_scope_id)
    profile_ids = getattr(share, "profile_ids", ())
    if profile_ids:
        media = filter_children(media, MediaChild, Media, profile_ids, "any")
        events = filter_children(events, EventChild, Event, profile_ids, "any")
    if selection:
        media = media.where(Media.id.in_(share.media_ids))
        events = events.where(literal(False))
    return media, events


def root_query(share):
    media, events = shared_queries(share)
    if share is not None and share.media_ids is not None:
        return media.with_only_columns(
            literal("media").label("kind"), Media.id.label("id"),
            literal(share.start_date).label("day"),
            (-case({mid: index for index, mid in enumerate(share.media_ids)}, value=Media.id, else_=0)).label("position"),
            Media.taken_at_local.label("taken"),
        ).subquery()
    return union_all(
        media.with_only_columns(
            literal("media").label("kind"),
            Media.id.label("id"),
            func.date(timeline_time()).label("day"),
            Media.sort_order.label("position"),
            Media.taken_at_local.label("taken"),
        ),
        events.with_only_columns(
            literal("event"),
            Event.id,
            func.date(Event.start_at),
            literal(0),
            Event.start_at,
        ),
    ).subquery()


@router.get("/shares/bounds")
def sharing_bounds(db=Depends(get_db), user=Depends(editor)):
    root = root_query(None)
    earliest, latest = db.execute(
        select(func.min(root.c.day), func.max(root.c.day))
    ).one()
    return {"earliest": earliest, "latest": latest}


def public_child_ages(db, media_ids):
    ages = defaultdict(list)
    if not media_ids:
        return ages
    rows = db.execute(
        select(
            MediaChild.media_id, Child.name, Child.nickname,
            Child.birthday, Media.taken_at_local,
        )
        .select_from(MediaChild)
        .join(Child, Child.id == MediaChild.child_id)
        .join(Media, Media.id == MediaChild.media_id)
        .where(
            MediaChild.media_id.in_(media_ids),
            Child.status == "active",
            Child.growth_enabled.is_(True),
            Child.birthday.is_not(None),
            or_(
                Child.profile_type == "child",
                (Child.profile_type == "person") & (Child.relationship == "孩子"),
            ),
            Media.time_unknown.is_(False),
            Media.taken_at_local.is_not(None),
        )
        .order_by(Child.sort_order, Child.id)
    )
    for media_id, name, nickname, birthday, taken in rows:
        ages[media_id].append({
            "name": nickname or name,
            "age": age_at(birthday, taken.date()),
        })
    return ages


def public_media(media, child_ages=None):
    # Only display names and derived ages from child profiles go into the payload.
    item = {
        "kind": "media",
        "id": media.id,
        "title": media.title,
        "media_type": media.media_type,
    }
    if child_ages:
        item["child_ages"] = child_ages
    return item


def entries(db, share, day, offset=0, limit=8, order="desc"):
    root = root_query(share)
    query = select(root).where(root.c.day == day)
    total = db.scalar(select(func.count()).select_from(query.subquery()))
    rows = (
        db.execute(
            query.order_by(
                root.c.position.desc(),
                root.c.taken.is_(None).asc(),
                root.c.taken.asc() if order == "asc" else root.c.taken.desc(),
                root.c.id.desc(),
                root.c.kind.desc(),
            )
            .offset(offset)
            .limit(limit)
        )
        .mappings()
        .all()
    )
    media_ids = [r["id"] for r in rows if r["kind"] == "media"]
    event_ids = [r["id"] for r in rows if r["kind"] == "event"]
    # Read card fields without hydrating child/EXIF/file relationships.
    media_map = {
        m.id: m
        for m in db.execute(
            select(Media.id, Media.title, Media.media_type).where(
                Media.id.in_(media_ids)
            )
        )
    }
    child_ages = public_child_ages(db, media_ids)
    event_map = {
        e.id: e
        for e in db.execute(
            select(Event.id, Event.title, Event.content).where(Event.id.in_(event_ids))
        )
    }
    items = []
    for row in rows:
        if row["kind"] == "media":
            media_id = row["id"]
            items.append(public_media(media_map[media_id], child_ages.get(media_id)))
        else:
            event = event_map[row["id"]]
            items.append(
                {
                    "kind": "event",
                    "id": event.id,
                    "title": event.title,
                    "content": event.content,
                }
            )
    return {"day": day, "items": items, "total": total}


@router.get("/public/shares/{token}/dates")
def share_dates(share=Depends(public_share), db=Depends(get_db)):
    root = root_query(share)
    rows = db.execute(
        select(root.c.day, func.count(), func.sum(case((root.c.kind == "media", 1), else_=0)))
        .group_by(root.c.day)
        .order_by(root.c.day)
    ).all()
    return {
        "dates": [day for day, _, _ in rows],
        "total": sum(total for _, total, _ in rows),
        "media_counts": {str(day): int(count) for day, _, count in rows},
    }


@router.get("/public/shares/{token}")
def read_share(
    before: date | None = None,
    after: date | None = None,
    anchor: date | None = None,
    order: Literal["asc", "desc"] = "desc",
    backward: bool = False,
    share=Depends(public_share),
    db=Depends(get_db),
):
    root = root_query(share)
    query = select(root.c.day).distinct()
    ascending = (order == "asc") != backward
    if anchor:
        query = query.where(
            root.c.day >= anchor if ascending else root.c.day <= anchor
        )
    if before and not ascending:
        query = query.where(root.c.day < before)
    if after and ascending:
        query = query.where(root.c.day > after)
    days = db.scalars(
        query.order_by(root.c.day.asc() if ascending else root.c.day.desc()).limit(
            8
        )
    ).all()
    page = days[:7]
    if backward:
        page.reverse()
    return {
        "share": share_info(db, share),
        "days": [entries(db, share, d, order=order) for d in page],
        "next_before": days[6] if len(days) > 7 and not ascending else None,
        "next_after": days[6] if len(days) > 7 and ascending else None,
    }


@router.get("/public/shares/{token}/days/{day}")
def read_day(
    day: date,
    offset: int = Query(default=0, ge=0, le=1000000),
    order: Literal["asc", "desc"] = "desc",
    share=Depends(public_share),
    db=Depends(get_db),
):
    return entries(db, share, day, offset, 40, order=order)


@router.get("/public/shares/{token}/media/{mid}/url")
def preview_url(
    mid: int,
    purpose: Literal["thumbnail", "preview"] = "preview",
    live: bool = False,
    share=Depends(public_share),
    db=Depends(get_db),
    storage=Depends(get_storage),
):
    media_query, _ = shared_queries(share)
    media = db.scalar(media_query.where(Media.id == mid))
    if not media:
        raise HTTPException(404, "影像不存在")
    files = [f for f in media.files if f.upload_status == "complete"]
    role = "live_video" if live else "original"
    original = next((f for f in files if f.file_role == role), None)
    if not original:
        raise HTTPException(404, "影像不存在")
    file = next((f for f in files if f.file_role == "preview" and not live), original)
    ttl = min(60, int((share.expires_at - now()).total_seconds()))
    if ttl < 1:
        raise HTTPException(404, "分享已失效或不存在")
    source = original if purpose == "preview" and original.mime_type.startswith("video/") else file
    resource = preview_resource(db, storage, source, purpose, expires=ttl)
    if not resource["url"]:
        return {"status": "pending", "url": None}
    return {**resource, "expires_in": ttl}
