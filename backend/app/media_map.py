"""Map queries for the same private, active media shown on the timeline."""

from collections import defaultdict
from heapq import nsmallest
from math import ceil, cos, floor, log2, radians
from typing import Annotated, Literal
from datetime import date

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field, model_validator
from sqlalchemy import and_, func, not_, or_, select, tuple_

from .db import get_db
from .map_geography import administrative_place, geographic_bounds, wrap_longitude
from .models import Media, MediaChild, MediaFile
from .security import current_user
from .services import filter_children, media_data, timeline_time
from .visibility import visible_query

router = APIRouter(prefix="/api/media/map")
MapLevel = Literal["country", "region", "local"]
MediaType = Literal["photo", "video", "live_photo"]
MAX_COVER_GROUPS = 8
MAX_COVER_MEDIA = 3

LOCATED = and_(
    Media.latitude.is_not(None), Media.longitude.is_not(None),
    Media.latitude.between(-90, 90), Media.longitude.between(-180, 180),
)
GROUP_ID = r"^(?:[cr]:[A-Za-z0-9_-]+|g:-?\d{1,2}:\d{1,9}:\d{1,9})$"


class MapWindow(BaseModel):
    south: float = Field(ge=-90, le=90)
    west: float = Field(ge=-180, le=180)
    north: float = Field(ge=-90, le=90)
    east: float = Field(ge=-180, le=180)

    @property
    def span(self):
        width = self.east - self.west
        return max(width if width >= 0 else width + 360, self.north - self.south)

    def restrict(self, query):
        longitude = Media.longitude
        if self.west > self.east:
            longitudes = or_(longitude >= self.west, longitude <= self.east)
        else:
            longitudes = longitude.between(self.west, self.east)
            # The two numeric representations of the date line are the same meridian.
            if self.west == -180:
                longitudes = or_(longitudes, longitude == 180)
            if self.east == 180:
                longitudes = or_(longitudes, longitude == -180)
        return query.where(Media.latitude.between(self.south, self.north), longitudes)


class MapFilters(BaseModel):
    owner_id: int | None = Field(default=None, ge=1)
    child_id: list[int] = Field(default_factory=list, max_length=100)
    media_type: MediaType | None = None
    start: date | None = None
    end: date | None = None
    south: float | None = Field(default=None, ge=-90, le=90)
    west: float | None = Field(default=None, ge=-180, le=180)
    north: float | None = Field(default=None, ge=-90, le=90)
    east: float | None = Field(default=None, ge=-180, le=180)
    level: MapLevel | None = None
    include_unlocated: bool = False
    include_covers: bool = False

    @model_validator(mode="after")
    def validate_scope(self):
        edges = (self.south, self.west, self.north, self.east)
        if any(edge is not None for edge in edges) and any(edge is None for edge in edges):
            raise ValueError("请指定完整地图范围")
        if self.south is not None and self.south >= self.north:
            raise ValueError("地图北边界必须大于南边界")
        if self.start is not None and self.end is not None and self.start >= self.end:
            raise ValueError("结束日期必须晚于开始日期")
        return self

    @property
    def window(self):
        if self.south is not None:
            return MapWindow(south=self.south, west=self.west, north=self.north, east=self.east)

    def media(self, statement, user):
        statement = visible_query(
            statement.where(Media.purpose == "memory", Media.status == "active"), Media, user,
        )
        statement = filter_children(statement, MediaChild, Media, self.child_id, "any")
        if self.owner_id is not None:
            statement = statement.where(Media.owner_id == self.owner_id)
        if self.media_type:
            statement = statement.where(Media.media_type == self.media_type)
        if self.start:
            statement = statement.where(timeline_time() >= self.start)
        if self.end:
            statement = statement.where(timeline_time() < self.end)
        return statement

    def located(self, statement):
        statement = statement.where(LOCATED)
        return self.window.restrict(statement) if self.window else statement


class MapItemsFilters(MapFilters):
    scope: Literal["map", "unlocated"] = "map"
    group: str | None = Field(default=None, max_length=60, pattern=GROUP_ID)
    page: int = Field(default=1, ge=1, le=1000000)
    page_size: int = Field(default=30, ge=1, le=60)

    @model_validator(mode="after")
    def validate_group(self):
        if self.group and (self.scope != "map" or not self.level):
            raise ValueError("查看聚合影像时请指定地图层级")
        if self.group and self.group.startswith("g:") and not -14 <= int(self.group.split(":")[1]) <= 6:
            raise ValueError("无效的聚合范围")
        return self


def zoom_level(window, points):
    if window:
        if window.span >= 45:
            return "country"
        return "region" if window.span >= 3 else "local"
    # Nearby photos can still belong to different countries or provinces.
    return next((level for level in ("country", "region") if spans_areas(points, level)), "local")


def spans_areas(points, level):
    first = None
    for latitude, longitude in points:
        place = administrative_place(latitude, longitude, level)
        if place:
            if first is not None and place[0] != first:
                return True
            first = place[0]
    return False


def group_for(latitude, longitude, level, exponent):
    if level in ("country", "region"):
        place = administrative_place(latitude, longitude, level)
        if place:
            return f"{level[0]}:{place[0]}", place[1]
    side = 2.0 ** exponent
    columns = ceil(360 / side)
    column = floor((wrap_longitude(longitude) + 180) / 360 * columns + 0.5) % columns
    row = floor((latitude + 90) / side)
    return f"g:{exponent}:{column}:{row}", None


def group_annotations(rows, level, span):
    exponent = min(6, max(-14, ceil(log2(max(span / 9, 0.0001)))))
    groups = defaultdict(list)
    names = {}
    for latitude, longitude, count in rows:
        key, name = group_for(latitude, longitude, level, exponent)
        groups[key].append((latitude, longitude, count))
        names[key] = name
    annotations = []
    for key, members in groups.items():
        coordinates = [(lat, lon) for lat, lon, _ in members]
        bounds = geographic_bounds(coordinates)
        total = sum(count for _, _, count in members)
        west = bounds["west"]
        center_lat = sum(lat * count for lat, _, count in members) / total
        center_lon = wrap_longitude(west + sum((lon - west) % 360 * count for _, lon, count in members) / total)
        longitude_scale = cos(radians(center_lat))

        def distance(point):
            lat, lon = point
            return ((lat - center_lat) ** 2 + (wrap_longitude(lon - center_lon) * longitude_scale) ** 2, point)

        nearby = nsmallest(MAX_COVER_MEDIA, coordinates, key=distance)
        latitude, longitude = nearby[0]
        annotations.append({
            "id": key, "name": names[key], "count": total,
            "latitude": latitude, "longitude": longitude, "bounds": bounds,
            "next_level": "region" if level == "country" and spans_areas(coordinates, "region") else "local",
            "cover_coordinates": nearby,
        })
    return sorted(annotations, key=lambda item: (-item["count"], item["id"]))


def add_covers(db, filters, user, groups):
    original = select(func.min(MediaFile.id)).where(
        MediaFile.media_id == Media.id,
        MediaFile.file_role == "original", MediaFile.upload_status == "complete",
    ).scalar_subquery()
    statement = filters.media(select(Media.id, original, Media.media_type, Media.title, Media.batch_name), user)
    statement = statement.where(original.is_not(None)).order_by(*media_ordering()).limit(MAX_COVER_MEDIA)
    for group in groups:
        query = statement.where(tuple_(Media.latitude, Media.longitude).in_(group["cover_coordinates"]))
        group["covers"] = [
            {"media_id": media_id, "file_id": file_id, "media_type": media_type, "title": title or batch}
            for media_id, file_id, media_type, title, batch in db.execute(query)
        ]


@router.get("")
def map_summary(filters: Annotated[MapFilters, Query()], db=Depends(get_db), user=Depends(current_user)):
    statement = filters.media(select(Media.latitude, Media.longitude, func.count()), user)
    statement = filters.located(statement).group_by(Media.latitude, Media.longitude)
    rows = [(float(lat), float(lon), count) for lat, lon, count in db.execute(statement)]
    points = [(lat, lon) for lat, lon, _ in rows]
    bounds = geographic_bounds(points)
    window = filters.window
    level = filters.level or zoom_level(window, points)
    span = window.span if window else MapWindow(**bounds).span if bounds else 0
    unlocated = None
    if window is None or filters.include_unlocated:
        unlocated = db.scalar(filters.media(select(func.count()).select_from(Media), user).where(not_(LOCATED)))
    groups = group_annotations(rows, level, span)
    if filters.include_covers and len(groups) <= MAX_COVER_GROUPS:
        add_covers(db, filters, user, groups)
    for group in groups:
        group.pop("cover_coordinates")
    return {
        "level": level, "bounds": bounds, "groups": groups,
        "located_total": sum(count for _, _, count in rows), "unlocated_total": unlocated,
    }


def media_ordering():
    return (func.date(timeline_time()).desc(), Media.sort_order.desc(), Media.taken_at_local.desc(), Media.id.desc())


@router.get("/items")
def map_items(filters: Annotated[MapItemsFilters, Query()], db=Depends(get_db), user=Depends(current_user)):
    offset = (filters.page - 1) * filters.page_size
    if filters.group:
        exponent = int(filters.group.split(":")[1]) if filters.group.startswith("g:") else 0
        # Stream lightweight candidates. Fetch file and profile data for this page only.
        statement = filters.media(select(Media.id, Media.latitude, Media.longitude), user)
        statement = filters.located(statement).order_by(*media_ordering()).execution_options(yield_per=1000)
        ids = []
        total = 0
        with db.execute(statement) as candidates:
            for media_id, latitude, longitude in candidates:
                if group_for(float(latitude), float(longitude), filters.level, exponent)[0] == filters.group:
                    if offset <= total < offset + filters.page_size:
                        ids.append(media_id)
                    total += 1
        media = {item.id: item for item in db.scalars(filters.media(select(Media).where(Media.id.in_(ids)), user))}
        rows = [media[mid] for mid in ids if mid in media]
    else:
        statement = filters.media(select(Media), user)
        statement = statement.where(not_(LOCATED)) if filters.scope == "unlocated" else filters.located(statement)
        total = db.scalar(select(func.count()).select_from(statement.with_only_columns(Media.id).subquery()))
        rows = list(db.scalars(statement.order_by(*media_ordering()).offset(offset).limit(filters.page_size)))
    return {
        "items": [media_data(item, filters.child_id) for item in rows],
        "total": total, "page": filters.page, "page_size": filters.page_size,
    }
