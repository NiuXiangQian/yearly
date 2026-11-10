from datetime import date, datetime
from typing import Literal
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import select, func
from .db import get_db
from .models import TimelineFolder, Media
from .security import current_user, editor
from .services import require_row, timeline_time
from .accounts import require_editable, modification_data

router = APIRouter(prefix="/api/folders", tags=["folders"])


class FolderName(BaseModel):
    name: str = Field(min_length=1, max_length=255)

    @field_validator("name")
    @classmethod
    def nonblank(cls, value):
        if not value.strip():
            raise ValueError("请输入文件夹名称")
        return value.strip()


class FolderEdit(FolderName):
    share_allowed: bool = True


class FolderCreate(FolderName):
    timeline_date: date


class FolderMove(BaseModel):
    media_ids: list[int] = Field(min_length=1, max_length=1000)
    folder_id: int | None = Field(default=None, ge=1)


class FolderOrder(BaseModel):
    target_id: int = Field(ge=1)
    placement: Literal["before", "after"] = "before"


def active_folder(db, fid):
    folder = require_row(db, TimelineFolder, fid)
    if folder.status != "active":
        raise HTTPException(404, "文件夹已删除")
    return folder


def folder_data(folder, count=0):
    return {
        **modification_data(folder),
        "owner_id": folder.owner_id,
        "updated_by": folder.updated_by,
        "updated_at": folder.updated_at,
        "id": folder.id,
        "name": folder.name,
        "share_allowed": folder.share_allowed,
        "timeline_day": folder.timeline_date,
        "sort_order": folder.sort_order,
        "media_count": count,
        "kind": "folder",
    }


@router.get("")
def folders(day: date, db=Depends(get_db), user=Depends(current_user)):
    rows = db.execute(
        select(TimelineFolder, func.count(Media.id))
        .outerjoin(
            Media, (Media.folder_id == TimelineFolder.id) & (Media.status == "active")
        )
        .where(TimelineFolder.status == "active", TimelineFolder.timeline_date == day)
        .group_by(TimelineFolder.id)
        .order_by(TimelineFolder.sort_order.desc(), TimelineFolder.id.desc())
    )
    return [folder_data(folder, count) for folder, count in rows]


@router.post("")
def create_folder(data: FolderCreate, db=Depends(get_db), user=Depends(editor)):
    folder = TimelineFolder(**data.model_dump(), owner_id=user.id)
    db.add(folder)
    db.commit()
    return folder_data(folder)


@router.post("/move-media")
def move_media(data: FolderMove, db=Depends(get_db), user=Depends(editor)):
    folder = require_editable(user, active_folder(db, data.folder_id)) if data.folder_id else None
    rows = db.scalars(
        select(Media).where(
            Media.id.in_(set(data.media_ids)),
            Media.status == "active",
            Media.purpose == "memory",
        )
    ).all()
    if len(rows) != len(set(data.media_ids)):
        raise HTTPException(404, "部分影像已不可用")
    if folder and any(
        (m.timeline_date or (m.taken_at_local.date() if m.taken_at_local else None))
        != folder.timeline_date
        for m in rows
    ):
        raise HTTPException(422, "只能移入同一天的文件夹，请先调整影像归档日期")
    for media in rows:
        require_editable(user, media)
        if media.folder_id:
            require_editable(user, active_folder(db, media.folder_id))
    for media in rows:
        media.folder_id = data.folder_id
        media.sort_order = 0
    db.commit()
    return {"ok": True, "count": len(rows)}


@router.get("/{fid}")
def folder_detail(fid: int, db=Depends(get_db), user=Depends(current_user)):
    folder = active_folder(db, fid)
    count = db.scalar(
        select(func.count())
        .select_from(Media)
        .where(Media.folder_id == fid, Media.status == "active")
    )
    return folder_data(folder, count)


@router.put("/{fid}")
def rename_folder(fid: int, data: FolderEdit, db=Depends(get_db), user=Depends(editor)):
    folder = require_editable(user, active_folder(db, fid))
    folder.name = data.name
    if "share_allowed" in data.model_fields_set:
        folder.share_allowed = data.share_allowed
    db.commit()
    return folder_data(folder)


@router.delete("/{fid}")
def remove_folder(fid: int, db=Depends(get_db), user=Depends(editor)):
    folder = require_editable(user, active_folder(db, fid))
    contents = list(db.scalars(select(Media).where(Media.folder_id == fid)))
    for media in contents:
        require_editable(user, media)
    for media in contents:
        media.folder_id = None
        media.sort_order = 0
    folder.status = "deleted"
    db.commit()
    return {"ok": True}


def reorder_day_entries(db, moving_keys, target_key, placement, user):
    target = require_row(
        db, TimelineFolder if target_key[0] == "folder" else Media, target_key[1]
    )
    day = (
        target.timeline_date
        if target_key[0] == "folder"
        else target.timeline_date
        or (target.taken_at_local.date() if target.taken_at_local else None)
    )
    day_column = func.date(timeline_time())
    media_rows = db.scalars(
        select(Media).where(
            Media.status == "active",
            Media.purpose == "memory",
            Media.folder_id.is_(None),
            day_column == day if day else day_column.is_(None),
        )
    ).all()
    folder_rows = (
        db.scalars(
            select(TimelineFolder).where(
                TimelineFolder.status == "active",
                TimelineFolder.timeline_date == day,
            )
        ).all()
        if day
        else []
    )
    for row in [*media_rows, *folder_rows]:
        require_editable(user, row)
    entries = {("media", m.id): m for m in media_rows}
    entries.update({("folder", f.id): f for f in folder_rows})
    moving = list(dict.fromkeys(moving_keys))
    if (
        target_key not in entries
        or target_key in moving
        or any(key not in entries for key in moving)
    ):
        raise HTTPException(422, "只能调整同一天根目录的文件夹和影像，放置位置不能是已选项目")
    ordered = sorted(
        entries,
        key=lambda key: (
            entries[key].sort_order,
            key[0] == "folder",
            (entries[key].taken_at_local or datetime.min)
            if key[0] == "media"
            else datetime.min,
            key[1],
        ),
        reverse=True,
    )
    moving_set = set(moving)
    ordered = [key for key in ordered if key not in moving_set]
    index = ordered.index(target_key) + (placement == "after")
    ordered[index:index] = moving
    for index, key in enumerate(ordered):
        entries[key].sort_order = len(ordered) - index
    return ordered


@router.post("/{fid}/reorder")
def reorder_folder(
    fid: int, data: FolderOrder, db=Depends(get_db), user=Depends(editor)
):
    reorder_day_entries(
        db, [("folder", fid)], ("folder", data.target_id), data.placement, user
    )
    db.commit()
    return {"ok": True}
