"""Public sharing has its own allowlisted payload and never grants original access."""
import hashlib
import secrets
from datetime import date, timedelta
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from pydantic import BaseModel, ConfigDict, Field, model_validator
from sqlalchemy import select, func, literal, union_all, or_

from .db import get_db, now
from .models import (
    TimelineShare,
    Media,
    TimelineFolder,
    Event,
    User,
    VideoPreview,
    TimelineDay,
)
from .security import editor
from .services import timeline_time
from .storage import get_storage

router = APIRouter(prefix="/api", tags=["sharing"])


class ShareCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    title: str = Field(default="", max_length=120)
    start_date: date
    end_date: date
    hours: int = Field(default=24, ge=1, le=168)

    @model_validator(mode="after")
    def date_order(self):
        if self.end_date < self.start_date:
            raise ValueError("结束日期不能早于开始日期")
        return self


def share_info(share):
    return {
        "id": share.id,
        "title": share.title,
        "start_date": share.start_date,
        "end_date": share.end_date,
        "expires_at": share.expires_at.isoformat() + "Z",
        "revoked": share.revoked,
        "expired": share.expires_at <= now(),
    }


@router.post("/shares")
def create_share(data: ShareCreate, db=Depends(get_db), user=Depends(editor)):
    token = secrets.token_urlsafe(32)
    share = TimelineShare(
        token_hash=hashlib.sha256(token.encode()).hexdigest(),
        created_by=user.id,
        title=data.title.strip(),
        start_date=data.start_date,
        end_date=data.end_date,
        expires_at=now() + timedelta(hours=data.hours),
    )
    db.add(share)
    db.commit()
    # The bearer secret is returned once and never included in lists or exports.
    return {**share_info(share), "token": token}


@router.get("/shares")
def list_shares(db=Depends(get_db), user=Depends(editor)):
    query = select(TimelineShare)
    if user.role != "admin":
        query = query.where(TimelineShare.created_by == user.id)
    return [
        share_info(s)
        for s in db.scalars(query.order_by(TimelineShare.id.desc()).limit(100))
    ]


@router.delete("/shares/{sid}")
def revoke_share(sid: int, db=Depends(get_db), user=Depends(editor)):
    share = db.get(TimelineShare, sid)
    if not share or (user.role != "admin" and share.created_by != user.id):
        raise HTTPException(404, "分享不存在")
    share.revoked = True
    db.commit()
    return {"ok": True}


def public_share(token: str, response: Response, db=Depends(get_db)):
    response.headers["X-Robots-Tag"] = "noindex, nofollow, noarchive"
    share = db.scalar(
        select(TimelineShare).where(
            TimelineShare.token_hash == hashlib.sha256(token.encode()).hexdigest()
        )
    )
    if not share or share.revoked or share.expires_at <= now():
        raise HTTPException(404, "分享已失效或不存在")
    owner = db.get(User, share.created_by)
    if not owner or not owner.active or owner.role not in ("admin", "member"):
        raise HTTPException(404, "分享已失效或不存在")
    return share


class DaySharing(BaseModel):
    share_allowed: bool


@router.put("/timeline/days/{day}/sharing")
def update_day_sharing(
    day: date, data: DaySharing, db=Depends(get_db), user=Depends(editor)
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

    def in_range(column):
        return (
            column >= share.start_date,
            column <= share.end_date,
            column.not_in(blocked_days),
        )

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
    return media, folders, events


def root_query(share):
    media, folders, events = shared_queries(share)
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


def public_media(media):
    # No filenames, GPS, EXIF, account/child IDs, storage keys or original URLs.
    return {
        "kind": "media",
        "id": media.id,
        "title": media.title,
        "media_type": media.media_type,
    }


def entries(db, share, day, offset=0, limit=8):
    root = root_query(share)
    query = select(root).where(root.c.day == day)
    total = db.scalar(select(func.count()).select_from(query.subquery()))
    rows = (
        db.execute(
            query.order_by(
                root.c.position.desc(),
                root.c.group_order.desc(),
                root.c.taken.desc(),
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


@router.get("/public/shares/{token}")
def read_share(
    before: date | None = None, share=Depends(public_share), db=Depends(get_db)
):
    root = root_query(share)
    query = select(root.c.day).distinct()
    if before:
        query = query.where(root.c.day < before)
    days = db.scalars(query.order_by(root.c.day.desc()).limit(8)).all()
    return {
        "share": share_info(share),
        "days": [entries(db, share, d) for d in days[:7]],
        "next_before": days[6] if len(days) > 7 else None,
    }


@router.get("/public/shares/{token}/days/{day}")
def read_day(
    day: date,
    offset: int = Query(default=0, ge=0, le=1000000),
    share=Depends(public_share),
    db=Depends(get_db),
):
    return entries(db, share, day, offset, 40)


@router.get("/public/shares/{token}/folders/{fid}")
def read_folder(
    fid: int,
    offset: int = Query(default=0, ge=0, le=1000000),
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
        .order_by(Media.sort_order.desc(), Media.taken_at_local.desc(), Media.id.desc())
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
    if purpose == "preview" and original.mime_type.startswith("video/"):
        preview = db.get(VideoPreview, original.sha256)
        if not preview or preview.status != "ready":
            return {"status": "pending", "url": None}
        url = storage.video_url(preview, expires=ttl)
    else:
        url = storage.image_url(file, purpose, expires=ttl)
    return {"url": url, "status": "ready", "expires_in": ttl}
