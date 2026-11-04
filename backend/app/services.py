from datetime import timedelta
from sqlalchemy import select, delete, or_, func, cast, DateTime
from fastapi import HTTPException
from .models import Child, Media, MediaChild, Event, EventMedia, EventChild
from .age import age_at


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
        raise HTTPException(422, "关联的孩子不存在")
    return ids


def set_children(db, parent_id, ids, relation):
    ids = validate_children(db, ids)
    field = relation.media_id if relation is MediaChild else relation.event_id
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
    return {c.name: getattr(child, c.name) for c in Child.__table__.columns}


def media_data(media, child_ids=None, detail=False):
    data = {c.name: getattr(media, c.name) for c in Media.__table__.columns}
    data["timeline_day"] = media.timeline_date or (
        media.taken_at_local.date() if media.taken_at_local else None
    )
    children = [c for c in media.children if c.status != "deleted"]
    data["children"] = [
        {
            **child_data(c),
            "age": age_at(
                c.birthday,
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
    data = {c.name: getattr(event, c.name) for c in Event.__table__.columns}
    data["child_ids"] = [c.id for c in event.children if c.status != "deleted"]
    data["children"] = [
        {
            **child_data(c),
            "age_start": age_at(
                c.birthday, event.start_at.date() if event.start_at else None
            ),
            "age_end": age_at(
                c.birthday, event.end_at.date() if event.end_at else None
            ),
        }
        for c in event.children
        if c.status != "deleted" and (not child_ids or c.id in child_ids)
    ]
    data["media_ids"] = [link.media_id for link in event.media_links]
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
    found = set(
        db.scalars(
            select(Media.id).where(
                Media.id.in_(ids),
                or_(Media.status == "active", Media.id.in_(existing_ids)),
            )
        )
    )
    if found != ids:
        raise HTTPException(422, "事件包含不可用媒体")
    validate_children(db, payload.child_ids)
    for key, value in payload.model_dump(exclude={"child_ids", "media_ids"}).items():
        setattr(event, key, value)
    db.add(event)
    db.flush()
    set_children(db, event.id, payload.child_ids, EventChild)
    db.execute(delete(EventMedia).where(EventMedia.event_id == event.id))
    db.add_all(
        [
            EventMedia(event_id=event.id, media_id=mid, sort_order=i)
            for i, mid in enumerate(payload.media_ids)
        ]
    )
    db.commit()
    db.expire_all()
    return event_data(db.get(Event, event.id))
