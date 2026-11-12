"""Sharing restrictions also define content visible to non-admin accounts."""
from fastapi import HTTPException
from sqlalchemy import and_, func, or_, select
from .models import Event, Media, TimelineDay, TimelineFolder


def sharing_visibility(model):
    blocked_days = select(TimelineDay.timeline_date).where(TimelineDay.share_allowed.is_(False))
    if model is TimelineFolder:
        day = TimelineFolder.timeline_date
    elif model is Media:
        day = func.date(func.coalesce(Media.timeline_date, Media.taken_at_local))
    else:
        day = func.date(Event.start_at)
    conditions = [model.share_allowed.is_(True), or_(day.is_(None), day.not_in(blocked_days))]
    return and_(*conditions)


def visible_query(query, model, user):
    if user.role == "admin":
        return query
    query = query.where(sharing_visibility(model))
    if model is Media:
        folders = select(TimelineFolder.id).where(
            TimelineFolder.status == "active", sharing_visibility(TimelineFolder)
        ).correlate(None)
        query = query.where(or_(Media.folder_id.is_(None), Media.folder_id.in_(folders)))
    return query


def visible_row(db, model, row_id, user):
    row = db.scalar(visible_query(select(model).where(model.id == row_id), model, user))
    if row is None:
        raise HTTPException(404, "记录不存在")
    return row
