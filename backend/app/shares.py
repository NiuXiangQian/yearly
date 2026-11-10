"""Public sharing has its own allowlisted payload and never grants original access."""
import hashlib
import hmac
import re
import secrets
from base64 import urlsafe_b64encode
from datetime import date, timedelta
from typing import Literal, Annotated
from types import SimpleNamespace

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from pydantic import BaseModel, ConfigDict, Field, model_validator
from sqlalchemy import select, func, literal, union_all, or_, case
from sqlalchemy.dialects.mysql import insert

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
)
from .security import editor, admin
from .services import timeline_time
from .storage import get_storage, preview_resource

router = APIRouter(prefix="/api", tags=["sharing"])


class ShareCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    title: str = Field(default="", max_length=120)
    start_date: date | None = None
    end_date: date | None = None
    media_ids: list[Annotated[int, Field(gt=0, strict=True)]] | None = Field(default=None, min_length=1, max_length=200)
    hours: int = Field(default=24, ge=1, le=168)

    @model_validator(mode="after")
    def date_order(self):
        if self.media_ids is not None:
            if self.start_date is not None or self.end_date is not None:
                raise ValueError("指定影像分享不能同时设置日期范围")
            self.media_ids = list(dict.fromkeys(self.media_ids))
        elif self.start_date is None or self.end_date is None or self.end_date < self.start_date:
            raise ValueError("请提供有效的起止日期，结束日期不能早于开始日期")
        return self


def share_info(share):
    return {
        "id": share.id,
        "scope": "selection" if share.media_ids is not None else "date_range",
        "selected_count": len(share.media_ids) if share.media_ids is not None else None,
        "title": share.title,
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
    if data.media_ids is not None:
        # Validate the same permissions used by all public endpoints. Never silently
        # replace missing/hidden items with a broader date or folder scope.
        selected, _, _ = shared_queries(SimpleNamespace(media_ids=data.media_ids, owner_scope_id=owner_scope_id))
        visible = set(db.scalars(selected.with_only_columns(Media.id)))
        if visible != set(data.media_ids):
            raise HTTPException(422, "部分影像不存在、已删除或不允许分享，请重新选择")
    share = TimelineShare(
        token_hash=secrets.token_hex(32),
        created_by=user.id,
        owner_scope_id=owner_scope_id,
        title=data.title.strip(),
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
        **share_info(share), "token": token, "link_available": True,
        "can_copy": True, "visit_count": 0, "visitor_count": 0,
    }


@router.get("/shares")
def list_shares(db=Depends(get_db), user=Depends(editor)):
    query = select(TimelineShare)
    if user.role != "admin":
        query = query.where(TimelineShare.created_by == user.id)
    shares = db.scalars(query.order_by(TimelineShare.id.desc()).limit(100)).all()
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
            **share_info(s),
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
    return save_share(ShareCreate(title=share.title, hours=data.hours, **scope), response, db, user, share.owner_scope_id)


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
    return share


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
    """Apply the same scope to listing, folder previews and direct media access."""
    blocked_days = select(TimelineDay.timeline_date).where(
        TimelineDay.share_allowed.is_(False)
    )
    day = func.date(timeline_time())

    selection = share is not None and share.media_ids is not None

    def in_range(column):
        limits = (column >= share.start_date, column <= share.end_date) if share and not selection else ()
        visibility = or_(column.is_(None), column.not_in(blocked_days)) if selection else column.not_in(blocked_days)
        return (*limits, visibility)

    folders = select(TimelineFolder).where(
        TimelineFolder.status == "active",
        *in_range(TimelineFolder.timeline_date),
        TimelineFolder.share_allowed.is_(True),
    )
    media = select(Media).where(
        Media.status == "active",
        Media.purpose == "memory",
        *in_range(day),
        Media.share_allowed.is_(True),
        or_(
            Media.folder_id.is_(None),
            Media.folder_id.in_(folders.with_only_columns(TimelineFolder.id)),
        ),
    )
    events = select(Event).where(
        Event.status == "active",
        *in_range(func.date(Event.start_at)),
        Event.share_allowed.is_(True),
    )
    if share is not None and getattr(share, "owner_scope_id", None) is not None:
        media = media.where(Media.owner_id == share.owner_scope_id)
        folders = folders.where(TimelineFolder.owner_id == share.owner_scope_id)
        events = events.where(Event.created_by == share.owner_scope_id)
    if selection:
        media = media.where(Media.id.in_(share.media_ids))
        # Selected folder members are flattened; never expose their unselected siblings.
        folders = folders.where(literal(False))
        events = events.where(literal(False))
    return media, folders, events


def root_query(share):
    media, folders, events = shared_queries(share)
    if share is not None and share.media_ids is not None:
        return media.with_only_columns(
            literal("media").label("kind"), Media.id.label("id"),
            literal(share.start_date).label("day"),
            (-case({mid: index for index, mid in enumerate(share.media_ids)}, value=Media.id, else_=0)).label("position"),
            literal(0).label("group_order"), Media.taken_at_local.label("taken"),
        ).subquery()
    return union_all(
        media.where(Media.folder_id.is_(None)).with_only_columns(
            literal("media").label("kind"),
            Media.id.label("id"),
            func.date(timeline_time()).label("day"),
            Media.sort_order.label("position"),
            literal(0).label("group_order"),
            Media.taken_at_local.label("taken"),
        ),
        folders.with_only_columns(
            literal("folder"),
            TimelineFolder.id,
            TimelineFolder.timeline_date,
            TimelineFolder.sort_order,
            literal(1),
            literal(None),
        ),
        events.with_only_columns(
            literal("event"),
            Event.id,
            func.date(Event.start_at),
            literal(0),
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


def public_media(media):
    # No filenames, GPS, EXIF, account/child IDs, storage keys or original URLs.
    return {
        "kind": "media",
        "id": media.id,
        "title": media.title,
        "media_type": media.media_type,
    }


def entries(db, share, day, offset=0, limit=8, order="desc"):
    root = root_query(share)
    query = select(root).where(root.c.day == day)
    total = db.scalar(select(func.count()).select_from(query.subquery()))
    rows = (
        db.execute(
            query.order_by(
                root.c.position.desc(),
                root.c.group_order.desc(),
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
    media_query, _, _ = shared_queries(share)
    media_ids = [r["id"] for r in rows if r["kind"] == "media"]
    event_ids = [r["id"] for r in rows if r["kind"] == "event"]
    # Read only public columns; do not hydrate child/EXIF/file relationships for cards.
    media_map = {
        m.id: m
        for m in db.execute(
            select(Media.id, Media.title, Media.media_type).where(
                Media.id.in_(media_ids)
            )
        )
    }
    event_map = {
        e.id: e
        for e in db.execute(
            select(Event.id, Event.title, Event.content).where(Event.id.in_(event_ids))
        )
    }
    items = []
    for row in rows:
        if row["kind"] == "media":
            items.append(public_media(media_map[row["id"]]))
        elif row["kind"] == "event":
            event = event_map[row["id"]]
            items.append(
                {
                    "kind": "event",
                    "id": event.id,
                    "title": event.title,
                    "content": event.content,
                }
            )
        else:
            folder = db.get(TimelineFolder, row["id"])
            visible = media_query.where(Media.folder_id == folder.id)
            previews = db.execute(
                visible.with_only_columns(Media.id, Media.title, Media.media_type)
                .order_by(
                    Media.sort_order.desc(),
                    Media.taken_at_local.desc(),
                    Media.id.desc(),
                )
                .limit(4)
            )
            items.append(
                {
                    "kind": "folder",
                    "id": folder.id,
                    "name": folder.name,
                    "media_count": db.scalar(
                        select(func.count()).select_from(visible.subquery())
                    ),
                    "previews": [public_media(m) for m in previews],
                }
            )
    return {"day": day, "items": items, "total": total}


@router.get("/public/shares/{token}/dates")
def share_dates(share=Depends(public_share), db=Depends(get_db)):
    root = root_query(share)
    return {
        "dates": db.scalars(select(root.c.day).distinct().order_by(root.c.day)).all()
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
        "share": share_info(share),
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


@router.get("/public/shares/{token}/folders/{fid}")
def read_folder(
    fid: int,
    offset: int = Query(default=0, ge=0, le=1000000),
    order: Literal["asc", "desc"] = "desc",
    share=Depends(public_share),
    db=Depends(get_db),
):
    media, folders, _ = shared_queries(share)
    folder = db.scalar(folders.where(TimelineFolder.id == fid))
    if not folder:
        raise HTTPException(404, "文件夹不存在")
    query = media.where(Media.folder_id == fid)
    total = db.scalar(select(func.count()).select_from(query.subquery()))
    rows = db.execute(
        query.with_only_columns(Media.id, Media.title, Media.media_type)
        .order_by(
            Media.sort_order.desc(),
            Media.taken_at_local.is_(None).asc(),
            Media.taken_at_local.asc()
            if order == "asc"
            else Media.taken_at_local.desc(),
            Media.id.desc(),
        )
        .offset(offset)
        .limit(40)
    )
    return {
        "id": folder.id,
        "name": folder.name,
        "items": [public_media(m) for m in rows],
        "total": total,
    }


@router.get("/public/shares/{token}/media/{mid}/url")
def preview_url(
    mid: int,
    purpose: Literal["thumbnail", "preview"] = "preview",
    live: bool = False,
    share=Depends(public_share),
    db=Depends(get_db),
    storage=Depends(get_storage),
):
    media_query, _, _ = shared_queries(share)
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
