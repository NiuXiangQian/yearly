"""Ownership and transaction-scoped history for account and content changes."""

from fastapi import HTTPException
from fastapi.encoders import jsonable_encoder
from sqlalchemy import event, inspect
from sqlalchemy.orm import Session, object_session

from .db import now
from .models import (
    AuditLog,
    Child,
    Event,
    Media,
    TimelineDay,
    TimelineFolder,
    TimelineShare,
    User,
)

TRACKED = (User, Child, Media, TimelineFolder, TimelineDay, TimelineShare, Event)


def can_edit(user, row):
    owner = (
        row.created_by
        if isinstance(row, (Event, TimelineShare))
        else getattr(row, "owner_id", None)
    )
    return user is not None and (
        user.role == "admin" or (user.role == "member" and owner == user.id)
    )


def require_editable(user, row):
    if not can_edit(user, row):
        raise HTTPException(403, "此内容已锁定，只能修改自己添加的内容")
    return row


def modification_data(row):
    db = object_session(row)
    actor = db.info.get("actor") if db else None
    modifier = db.get(User, row.updated_by) if db and row.updated_by else None
    owner_id = (
        row.created_by
        if isinstance(row, (Event, TimelineShare))
        else getattr(row, "owner_id", None)
    )
    owner = db.get(User, owner_id) if db and owner_id else None
    return {
        "can_edit": can_edit(actor, row),
        "owner_name": owner.username if owner else None,
        "updated_by_name": modifier.username if modifier else None,
    }


def record_change(db, row, changes, action="update"):
    actor = db.info.get("actor")
    if not actor or not changes:
        return
    row.updated_by = actor.id
    row.updated_at = now()
    db.add(
        AuditLog(
            actor_id=actor.id,
            actor_name=actor.username,
            resource_type=row.__tablename__,
            resource_id=str(
                row.timeline_date if isinstance(row, TimelineDay) else row.id
            ),
            action=action,
            changes=jsonable_encoder(changes),
        )
    )


@event.listens_for(Session, "before_flush")
def capture_changes(db, flush_context, instances):
    actor = db.info.get("actor")
    if not actor:
        return
    pending = []
    for row in list(db.new) + list(db.dirty) + list(db.deleted):
        if not isinstance(row, TRACKED):
            continue
        state = inspect(row)
        changes = {}
        for column in row.__table__.columns:
            key = column.key
            if key in {"updated_at", "updated_by", "token_hash"}:
                continue
            history = state.attrs[key].history
            if not history.has_changes():
                continue
            if key == "password_hash":
                changes["password"] = {"changed": True}
            else:
                changes[key] = {
                    "before": history.deleted[0] if history.deleted else None,
                    "after": getattr(row, key),
                }
        if not changes:
            continue
        row.updated_by = actor.id
        row.updated_at = now()
        pending.append(
            (
                row,
                changes,
                "create"
                if row in db.new
                else "delete"
                if row in db.deleted
                else "update",
            )
        )
    db.info["audit_pending"] = pending


@event.listens_for(Session, "after_flush_postexec")
def save_changes(db, flush_context):
    for row, changes, action in db.info.pop("audit_pending", []):
        record_change(db, row, changes, action)
