from datetime import timedelta
from sqlalchemy import select, delete, or_, func, cast, DateTime
from fastapi import HTTPException
from .models import Child, Media, MediaChild, Event, EventMedia, EventChild
from sqlalchemy.orm import object_session
from .visibility import visible_query
from .age import age_at
from .accounts import modification_data, record_change


def require_row(db, model, row_id):
    row = db.get(model, row_id)
    if row is None:
        raise HTTPException(404, "记录不存在")
    return row


def validate_children(db, ids):
    ids = set(ids)
    existing = set(
        db.scalars(select(Child.id).where(Child.id.in_(ids), Child.status != "deleted"))
    )
    if existing != ids:
        raise HTTPException(422, "关联的人物或宠物不存在")
    return ids


def set_children(db, parent_id, ids, relation):
    ids = validate_children(db, ids)
    field = relation.media_id if relation is MediaChild else relation.event_id
    previous = sorted(db.scalars(select(relation.child_id).where(field == parent_id)))
    if previous != sorted(ids):
        parent = db.get(Media if relation is MediaChild else Event, parent_id)
        record_change(db, parent, {"child_ids": {"before": previous, "after": sorted(ids)}})
    db.execute(delete(relation).where(field == parent_id))
    key = "media_id" if relation is MediaChild else "event_id"
    db.add_all([relation(**{key: parent_id, "child_id": cid}) for cid in ids])


def apply_time(media):
    corrected = media.corrected_taken_at_local is not None
    media.taken_at_local = (
        media.corrected_taken_at_local if corrected else media.original_taken_at_local
    )
    media.taken_offset_minutes = (
        media.corrected_offset_minutes if corrected else media.original_offset_minutes
    )
    media.time_source = "user" if corrected else media.original_time_source
    if media.time_unknown:
        media.taken_at_local = None
        media.taken_offset_minutes = None
        media.time_source = "user_unknown"
    media.taken_at_utc = (
        media.taken_at_local - timedelta(minutes=media.taken_offset_minutes)
        if media.taken_at_local and media.taken_offset_minutes is not None
        else None
    )


def child_data(child):
    return {**{c.name: getattr(child, c.name) for c in Child.__table__.columns}, **modification_data(child)}


def media_data(media, child_ids=None, detail=False):
    data = {**{c.name: getattr(media, c.name) for c in Media.__table__.columns}, **modification_data(media)}
    data["timeline_day"] = media.timeline_date or (
        media.taken_at_local.date() if media.taken_at_local else None
    )
    children = [c for c in media.children if c.status != "deleted"]
    data["children"] = [
        {
            **child_data(c),
            "age": age_at(
                c.birthday if c.growth_enabled else None,
                media.taken_at_local.date() if media.taken_at_local else None,
            ),
        }
        for c in children
        if not child_ids or c.id in child_ids
    ]
    data["child_ids"] = [c.id for c in children]
    data["files"] = [
        {
            c.name: getattr(f, c.name)
            for c in f.__table__.columns
            if c.name not in ("oss_object_key", "oss_bucket")
        }
        for f in media.files
        if f.upload_status == "complete"
    ]
    if detail and media.metadata_record:
        data["metadata"] = {
            c.name: getattr(media.metadata_record, c.name)
            for c in media.metadata_record.__table__.columns
        }
    return data


def timeline_time():
    return func.coalesce(cast(Media.timeline_date, DateTime), Media.taken_at_local)


def event_data(event, child_ids=None):
    data = {**{c.name: getattr(event, c.name) for c in Event.__table__.columns}, **modification_data(event)}
    data["child_ids"] = [c.id for c in event.children if c.status != "deleted"]
    data["children"] = [
        {
            **child_data(c),
            "age_start": age_at(
                c.birthday if c.growth_enabled else None,
                event.start_at.date() if event.start_at else None,
            ),
            "age_end": age_at(
                c.birthday if c.growth_enabled else None,
                event.end_at.date() if event.end_at else None,
            ),
        }
        for c in event.children
        if c.status != "deleted" and (not child_ids or c.id in child_ids)
    ]
    media_ids = [link.media_id for link in event.media_links]
    db = object_session(event)
    user = db.info.get("actor") if db else None
    if user and user.role != "admin" and (media_ids or event.cover_media_id):
        visible = set(db.scalars(visible_query(select(Media.id).where(
            Media.id.in_([*media_ids, event.cover_media_id]),
        ), Media, user)))
        media_ids = [mid for mid in media_ids if mid in visible]
        if event.cover_media_id not in visible:
            data["cover_media_id"] = None
    data["media_ids"] = media_ids
    data["media_scope"] = "全部事件媒体，按手动顺序排列"
    return data


def filter_children(query, relation, parent, ids, match):
    # EXISTS prevents duplicate rows and keeps count / pagination independent of relationship cardinality.
    ids = list(dict.fromkeys(ids))
    field = relation.media_id if relation is MediaChild else relation.event_id
    if ids:
        if match == "all":
            for cid in ids:
                query = query.where(
                    select(field)
                    .where(field == parent.id, relation.child_id == cid)
                    .exists()
                )
        else:
            query = query.where(
                select(field)
                .where(field == parent.id, relation.child_id.in_(ids))
                .exists()
            )
    return query


def save_event(db, event, payload):
    ids = set(payload.media_ids)
    existing_ids = {link.media_id for link in event.media_links} if event.id else set()
    user = db.info["actor"]
    found = set(
        db.scalars(
            visible_query(select(Media.id).where(
                Media.id.in_(ids),
                or_(Media.status == "active", Media.id.in_(existing_ids)),
            ), Media, user)
        )
    )
    if found != ids:
        raise HTTPException(422, "事件包含不可用媒体")
    media_ids = list(payload.media_ids)
    if user.role != "admin" and existing_ids:
        visible_existing = set(db.scalars(visible_query(
            select(Media.id).where(Media.id.in_(existing_ids)), Media, user,
        )))
        # The editor cannot see restricted attachments; preserve them when saving visible fields.
        media_ids.extend(link.media_id for link in event.media_links if link.media_id not in visible_existing)
    if payload.cover_media_id:
        if not db.scalar(visible_query(select(Media.id).where(Media.id == payload.cover_media_id), Media, user)):
            raise HTTPException(422, "事件封面不可用")
    validate_children(db, payload.child_ids)
    excluded = {"child_ids", "media_ids"} | (
        {"share_allowed"} - payload.model_fields_set
    )
    if user.role != "admin" and event.cover_media_id and payload.cover_media_id is None:
        if not db.scalar(visible_query(select(Media.id).where(Media.id == event.cover_media_id), Media, user)):
            excluded.add("cover_media_id")
    for key, value in payload.model_dump(exclude=excluded).items():
        setattr(event, key, value)
    db.add(event)
    db.flush()
    set_children(db, event.id, payload.child_ids, EventChild)
    previous = [link.media_id for link in event.media_links]
    if previous != media_ids:
        record_change(db, event, {"media_ids": {"before": previous, "after": media_ids}})
    db.execute(delete(EventMedia).where(EventMedia.event_id == event.id))
    db.add_all(
        [
            EventMedia(event_id=event.id, media_id=mid, sort_order=i)
            for i, mid in enumerate(media_ids)
        ]
    )
    db.commit()
    db.expire_all()
    return event_data(db.get(Event, event.id))
