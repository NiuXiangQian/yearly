from datetime import date, datetime, time
from typing import Literal
from pydantic import BaseModel, Field, field_validator, model_validator


class ChildIn(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    nickname: str = Field(default="", max_length=80)
    birthday: date
    birth_time: time | None = None
    gender: str | None = Field(default=None, max_length=24)
    description: str = Field(default="", max_length=10000)
    theme_color: str = Field(default="#bf775d", pattern=r"^#[0-9a-fA-F]{6}$")
    sort_order: int = 0
    status: Literal["active", "archived"] = "active"
    avatar_media_id: int | None = None

    @field_validator("birthday")
    @classmethod
    def birthday_valid(cls, value):
        if value > date.today():
            raise ValueError("出生日期不能晚于今天")
        return value


class MediaEdit(BaseModel):
    share_allowed: bool = True
    batch_name: str = Field(default="", max_length=255)
    timeline_date: date | None = None
    time_unknown: bool = False
    title: str = Field(default="", max_length=255)
    remark: str = Field(default="", max_length=20000)
    tags: list[str] = Field(default_factory=list, max_length=30)
    location_name: str = Field(default="", max_length=255)
    latitude: float | None = Field(default=None, ge=-90, le=90)
    longitude: float | None = Field(default=None, ge=-180, le=180)
    corrected_taken_at_local: datetime | None = None
    corrected_offset_minutes: int | None = Field(default=None, ge=-840, le=840)
    child_ids: list[int] = Field(default_factory=list, max_length=100)

    @field_validator("corrected_taken_at_local")
    @classmethod
    def local_time(cls, value):
        if value is not None and value.tzinfo is not None:
            raise ValueError("本地拍摄时间不得包含时区，请单独提供偏移")
        return value

    @field_validator("tags")
    @classmethod
    def valid_tags(cls, value):
        if any(len(x) > 80 for x in value):
            raise ValueError("标签过长")
        return list(dict.fromkeys(value))


class FileIn(BaseModel):
    original_filename: str = Field(min_length=1, max_length=255)
    mime_type: str = Field(max_length=120)
    file_size: int = Field(gt=0)
    sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    crc64: str = Field(pattern=r"^\d{1,20}$")
    file_role: Literal["original", "live_video", "preview"] = "original"

    @field_validator("original_filename")
    @classmethod
    def filename_valid(cls, value):
        if "/" in value or "\\" in value or any(ord(c) < 32 for c in value):
            raise ValueError("文件名不合法")
        return value


class UploadIn(BaseModel):
    purpose: Literal["memory", "avatar"] = "memory"
    folder_id: int | None = Field(default=None, ge=1)
    batch_name: str = Field(default="", max_length=255)
    timeline_date: date | None = None
    time_unknown: bool = False
    media_type: Literal["photo", "video", "live_photo"]
    files: list[FileIn] = Field(min_length=1, max_length=3)
    child_ids: list[int] = Field(default_factory=list, max_length=100)
    metadata: dict = Field(default_factory=dict)
    title: str = Field(default="", max_length=255)
    original_taken_at_local: datetime | None = None
    original_offset_minutes: int | None = Field(default=None, ge=-840, le=840)
    time_source: str = Field(default="unknown", max_length=64)
    time_confidence: Literal["high", "medium", "low", "unknown"] = "unknown"
    latitude: float | None = Field(default=None, ge=-90, le=90)
    longitude: float | None = Field(default=None, ge=-180, le=180)
    altitude: float | None = None
    width: int | None = Field(default=None, gt=0)
    height: int | None = Field(default=None, gt=0)
    duration_ms: int | None = Field(default=None, ge=0)
    device_make: str | None = Field(default=None, max_length=120)
    device_model: str | None = Field(default=None, max_length=120)
    location_name: str = Field(default="", max_length=255)
    corrected_taken_at_local: datetime | None = None
    corrected_offset_minutes: int | None = Field(default=None, ge=-840, le=840)

    @model_validator(mode="after")
    def validate_files(self):
        if self.purpose == "avatar" and (
            self.media_type != "photo"
            or len(self.files) != 1
            or self.files[0].file_size > 1024 * 1024
            or self.files[0].original_filename.rsplit(".", 1)[-1].lower()
            not in {"jpg", "jpeg", "png", "webp"}
            or self.child_ids
            or self.folder_id
        ):
            raise ValueError("独立头像需为 1 MiB 以内的 JPG、PNG 或 WebP 图片，不能归入时间线或文件夹")
        roles = [f.file_role for f in self.files]
        if roles.count("original") != 1 or len(roles) != len(set(roles)):
            raise ValueError("每个逻辑媒体必须有且只有一份静态或视频原件")
        if ("live_video" in roles) != (self.media_type == "live_photo"):
            raise ValueError("Live Photo 必须包含静态原件和配套 MOV")
        if (
            self.original_taken_at_local
            and self.original_taken_at_local.tzinfo is not None
        ):
            raise ValueError("拍摄当地时间和时区偏移需要分开保存")
        if (
            self.corrected_taken_at_local
            and self.corrected_taken_at_local.tzinfo is not None
        ):
            raise ValueError("修正时间必须为无时区本地时间")
        return self


class EventIn(BaseModel):
    share_allowed: bool = True
    title: str = Field(min_length=1, max_length=255)
    content: str = Field(default="", max_length=50000)
    start_at: datetime | None = None
    end_at: datetime | None = None
    cover_media_id: int | None = None
    child_ids: list[int] = Field(default_factory=list, max_length=100)
    media_ids: list[int] = Field(default_factory=list, max_length=1000)

    @model_validator(mode="after")
    def validate_range(self):
        if any(d and d.tzinfo for d in [self.start_at, self.end_at]):
            raise ValueError("事件日期使用当地时间")
        if self.start_at and self.end_at and self.end_at < self.start_at:
            raise ValueError("结束日期不能早于开始日期")
        if self.cover_media_id and self.cover_media_id not in self.media_ids:
            raise ValueError("封面必须属于事件媒体")
        self.media_ids = list(dict.fromkeys(self.media_ids))
        return self


class BatchChildren(BaseModel):
    media_ids: list[int] = Field(min_length=1, max_length=1000)
    child_ids: list[int] = Field(default_factory=list, max_length=100)
    mode: Literal["replace", "add", "remove"] = "add"


class BatchOrganize(BaseModel):
    media_ids: list[int] = Field(min_length=1, max_length=1000)
    batch_name: str | None = Field(default=None, max_length=255)
    timeline_date: date | None = None


class MediaReorder(BaseModel):
    media_ids: list[int] = Field(min_length=1, max_length=1000)
    target_id: int = Field(ge=1)
    placement: Literal["before", "after"] = "before"


class LoginIn(BaseModel):
    username: str = Field(min_length=1, max_length=80)
    password: str = Field(min_length=1, max_length=256)
    captcha_id: str = Field(max_length=64)
    captcha: str = Field(max_length=8)


class UserIn(BaseModel):
    username: str = Field(min_length=2, max_length=80, pattern=r"^[\w.@-]+$")
    password: str = Field(min_length=12, max_length=256)
    role: Literal["admin", "member", "viewer"] = "member"


class TimelineCursor(BaseModel):
    id: int = Field(ge=1)
    kind: Literal["media", "event", "folder"]
    sort_at: datetime | None = None
    sort_day: date | None = None
    sort_order: int = 0
    sort_group: int = 0

    @field_validator("sort_at")
    @classmethod
    def local_sort_date(cls, value):
        if value and value.tzinfo:
            raise ValueError("游标使用拍摄当地时间")
        return value
