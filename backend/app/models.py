from datetime import date, datetime, time
from decimal import Decimal
from sqlalchemy import (
    String,
    Text,
    ForeignKey,
    UniqueConstraint,
    Index,
    JSON,
    Integer,
    Boolean,
    Numeric,
    Date,
    Time,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship
from .db import Base, ID, DT, now


class Timestamp:
    created_at: Mapped[datetime] = mapped_column(DT, default=now)
    updated_at: Mapped[datetime] = mapped_column(DT, default=now, onupdate=now)


class User(Base, Timestamp):
    __tablename__ = "sys_user"
    id: Mapped[int] = mapped_column(ID, primary_key=True)
    username: Mapped[str] = mapped_column(String(80), unique=True)
    password_hash: Mapped[str] = mapped_column(String(255))
    role: Mapped[str] = mapped_column(String(16), default="member")
    active: Mapped[bool] = mapped_column(Boolean, default=True)


class UserSession(Base):
    __tablename__ = "user_session"
    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("sys_user.id"), index=True)
    csrf_token: Mapped[str] = mapped_column(String(64))
    expires_at: Mapped[datetime] = mapped_column(DT, index=True)
    created_at: Mapped[datetime] = mapped_column(DT, default=now)


class LoginGuard(Base):
    __tablename__ = "login_guard"
    key: Mapped[str] = mapped_column(String(64), primary_key=True)
    failures: Mapped[int] = mapped_column(Integer, default=0)
    reset_at: Mapped[datetime] = mapped_column(DT, index=True)


class Child(Base, Timestamp):
    __tablename__ = "child"
    id: Mapped[int] = mapped_column(ID, primary_key=True)
    name: Mapped[str] = mapped_column(String(80))
    nickname: Mapped[str] = mapped_column(String(80), default="")
    avatar_media_id: Mapped[int | None] = mapped_column(
        ForeignKey("media.id", use_alter=True, name="fk_child_avatar")
    )
    birthday: Mapped[date] = mapped_column(Date)
    birth_time: Mapped[time | None] = mapped_column(Time)
    gender: Mapped[str | None] = mapped_column(String(24))
    description: Mapped[str] = mapped_column(Text, default="")
    theme_color: Mapped[str] = mapped_column(String(7), default="#bf775d")
    sort_order: Mapped[int] = mapped_column(Integer, default=0)
    status: Mapped[str] = mapped_column(String(16), default="active", index=True)


class MediaChild(Base):
    __tablename__ = "media_child"
    __table_args__ = (
        UniqueConstraint("media_id", "child_id", name="uq_media_child"),
        Index("ix_child_media", "child_id", "media_id"),
    )
    id: Mapped[int] = mapped_column(ID, primary_key=True)
    media_id: Mapped[int] = mapped_column(ForeignKey("media.id"), index=True)
    child_id: Mapped[int] = mapped_column(ForeignKey("child.id"))
    created_at: Mapped[datetime] = mapped_column(DT, default=now)


class TimelineFolder(Base, Timestamp):
    __tablename__ = "timeline_folder"
    id: Mapped[int] = mapped_column(ID, primary_key=True)
    name: Mapped[str] = mapped_column(String(255))
    timeline_date: Mapped[date] = mapped_column(Date, index=True)
    sort_order: Mapped[int] = mapped_column(Integer, default=0)
    status: Mapped[str] = mapped_column(String(16), default="active")


class Media(Base, Timestamp):
    __tablename__ = "media"
    __table_args__ = (Index("ix_media_status_taken", "status", "taken_at_local", "id"),)
    id: Mapped[int] = mapped_column(ID, primary_key=True)
    owner_id: Mapped[int] = mapped_column(ForeignKey("sys_user.id"))
    folder_id: Mapped[int | None] = mapped_column(
        ForeignKey("timeline_folder.id"), index=True
    )
    purpose: Mapped[str] = mapped_column(
        String(16), default="memory", server_default="memory"
    )
    media_type: Mapped[str] = mapped_column(String(16))
    title: Mapped[str] = mapped_column(String(255), default="")
    batch_name: Mapped[str] = mapped_column(String(255), default="", server_default="")
    timeline_date: Mapped[date | None] = mapped_column(Date)
    sort_order: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    remark: Mapped[str] = mapped_column(Text, default="")
    tags: Mapped[list] = mapped_column(JSON, default=list)
    original_taken_at_local: Mapped[datetime | None] = mapped_column(DT)
    original_offset_minutes: Mapped[int | None] = mapped_column(Integer)
    original_time_source: Mapped[str] = mapped_column(String(64), default="unknown")
    corrected_taken_at_local: Mapped[datetime | None] = mapped_column(DT)
    corrected_offset_minutes: Mapped[int | None] = mapped_column(Integer)
    taken_at_local: Mapped[datetime | None] = mapped_column(DT, index=True)
    taken_at_utc: Mapped[datetime | None] = mapped_column(DT)
    taken_offset_minutes: Mapped[int | None] = mapped_column(Integer)
    time_source: Mapped[str] = mapped_column(String(64), default="unknown")
    time_confidence: Mapped[str] = mapped_column(String(16), default="unknown")
    time_unknown: Mapped[bool] = mapped_column(
        Boolean, default=False, server_default="0"
    )
    latitude: Mapped[Decimal | None] = mapped_column(Numeric(10, 7))
    longitude: Mapped[Decimal | None] = mapped_column(Numeric(10, 7))
    altitude: Mapped[Decimal | None] = mapped_column(Numeric(12, 3))
    location_name: Mapped[str] = mapped_column(String(255), default="")
    width: Mapped[int | None] = mapped_column(Integer)
    height: Mapped[int | None] = mapped_column(Integer)
    duration_ms: Mapped[int | None] = mapped_column(ID)
    device_make: Mapped[str | None] = mapped_column(String(120))
    device_model: Mapped[str | None] = mapped_column(String(120))
    status: Mapped[str] = mapped_column(String(16), default="uploading")
    children: Mapped[list[Child]] = relationship(
        secondary="media_child", lazy="selectin", viewonly=True
    )
    files: Mapped[list["MediaFile"]] = relationship(lazy="selectin")
    metadata_record: Mapped["MediaMetadata | None"] = relationship(
        lazy="select", uselist=False
    )


class MediaFile(Base):
    __tablename__ = "media_file"
    id: Mapped[int] = mapped_column(ID, primary_key=True)
    media_id: Mapped[int] = mapped_column(ForeignKey("media.id"), index=True)
    file_role: Mapped[str] = mapped_column(String(24))
    oss_bucket: Mapped[str] = mapped_column(String(100))
    oss_object_key: Mapped[str] = mapped_column(String(191), unique=True)
    original_filename: Mapped[str] = mapped_column(String(255))
    mime_type: Mapped[str] = mapped_column(String(120))
    file_size: Mapped[int] = mapped_column(ID)
    sha256: Mapped[str] = mapped_column(String(64), index=True)
    crc64: Mapped[str] = mapped_column(String(20))
    upload_status: Mapped[str] = mapped_column(String(16), default="pending")
    created_at: Mapped[datetime] = mapped_column(DT, default=now)


class VideoPreview(Base, Timestamp):
    __tablename__ = "video_preview"
    sha256: Mapped[str] = mapped_column(String(64), primary_key=True)
    status: Mapped[str] = mapped_column(String(16), default="processing")
    object_key: Mapped[str] = mapped_column(String(191), default="")
    file_size: Mapped[int] = mapped_column(ID, default=0)
    error: Mapped[str] = mapped_column(String(255), default="")


class MediaMetadata(Base):
    __tablename__ = "media_metadata"
    media_id: Mapped[int] = mapped_column(ForeignKey("media.id"), primary_key=True)
    raw_metadata: Mapped[dict] = mapped_column(JSON, default=dict)
    parser_name: Mapped[str] = mapped_column(String(120))
    parser_version: Mapped[str] = mapped_column(String(80))
    parse_status: Mapped[str] = mapped_column(String(24))
    parse_error: Mapped[str | None] = mapped_column(Text)
    updated_at: Mapped[datetime] = mapped_column(DT, default=now, onupdate=now)


class Event(Base, Timestamp):
    __tablename__ = "timeline_event"
    id: Mapped[int] = mapped_column(ID, primary_key=True)
    title: Mapped[str] = mapped_column(String(255))
    content: Mapped[str] = mapped_column(Text, default="")
    start_at: Mapped[datetime | None] = mapped_column(DT, index=True)
    end_at: Mapped[datetime | None] = mapped_column(DT)
    cover_media_id: Mapped[int | None] = mapped_column(ForeignKey("media.id"))
    created_by: Mapped[int] = mapped_column(ForeignKey("sys_user.id"))
    status: Mapped[str] = mapped_column(String(16), default="active", index=True)
    children: Mapped[list[Child]] = relationship(
        secondary="timeline_event_child", lazy="selectin", viewonly=True
    )
    media_links: Mapped[list["EventMedia"]] = relationship(
        lazy="selectin", order_by="EventMedia.sort_order"
    )


class EventMedia(Base):
    __tablename__ = "timeline_event_media"
    event_id: Mapped[int] = mapped_column(
        ForeignKey("timeline_event.id"), primary_key=True
    )
    media_id: Mapped[int] = mapped_column(
        ForeignKey("media.id"), primary_key=True, index=True
    )
    sort_order: Mapped[int] = mapped_column(Integer, default=0)


class EventChild(Base):
    __tablename__ = "timeline_event_child"
    event_id: Mapped[int] = mapped_column(
        ForeignKey("timeline_event.id"), primary_key=True
    )
    child_id: Mapped[int] = mapped_column(
        ForeignKey("child.id"), primary_key=True, index=True
    )


class UploadTask(Base, Timestamp):
    __tablename__ = "upload_task"
    __table_args__ = (Index("ix_upload_status_updated", "status", "updated_at"),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    owner_id: Mapped[int] = mapped_column(ForeignKey("sys_user.id"), index=True)
    media_id: Mapped[int] = mapped_column(ForeignKey("media.id"), index=True)
    file_id: Mapped[int] = mapped_column(ForeignKey("media_file.id"), unique=True)
    oss_upload_id: Mapped[str | None] = mapped_column(String(255))
    part_size: Mapped[int] = mapped_column(Integer)
    status: Mapped[str] = mapped_column(String(24), default="pending")
    expires_at: Mapped[datetime] = mapped_column(DT, index=True)


class Captcha(Base):
    __tablename__ = "captcha"
    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    answer_hash: Mapped[str] = mapped_column(String(64))
    expires_at: Mapped[datetime] = mapped_column(DT, index=True)


for table in Base.metadata.tables.values():
    table.dialect_options["mysql"]["engine"] = "InnoDB"
    table.dialect_options["mysql"]["charset"] = "utf8mb4"
    table.dialect_options["mysql"]["collate"] = "utf8mb4_unicode_ci"
