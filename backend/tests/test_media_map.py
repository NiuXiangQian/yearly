from datetime import date

from app.map_geography import administrative_place, geographic_bounds
from app.models import Child, Media, MediaChild, MediaFile, TimelineDay, TimelineFolder


def add_media(db, title, latitude, longitude, **fields):
    item = Media(
        owner_id=fields.pop("owner_id", 1), title=title, latitude=latitude, longitude=longitude,
        status=fields.pop("status", "active"), media_type=fields.pop("media_type", "photo"),
        timeline_date=fields.pop("timeline_date", date(2026, 5, 1)), **fields,
    )
    db.add(item)
    db.flush()
    return item.id


def test_map_filters_permission_and_matching_clusters(context):
    with context.db() as db:
        child = Child(name="安安")
        db.add(child)
        db.add(TimelineDay(timeline_date=date(2026, 7, 2), share_allowed=False))
        folder = TimelineFolder(name="仅家庭管理员", timeline_date=date(2026, 5, 1), share_allowed=False)
        db.add(folder)
        db.flush()
        hz = add_media(db, "杭州西湖", 30.241, 120.148, location_name="西湖")
        db.add(MediaChild(media_id=hz, child_id=child.id))
        add_media(db, "拙政园", 31.324, 120.629, media_type="live_photo")
        add_media(db, "上海外滩", 31.239, 121.49, media_type="video", owner_id=2)
        add_media(db, "金门公园", 37.7726, -122.4602, timeline_date=date(2025, 5, 1))
        add_media(db, "仅有地点名", None, None, location_name="家里")
        add_media(db, "经度未知", 30.3, None)
        add_media(db, "0 度是有效值", 0, 0)
        add_media(db, "隐藏照片", 30.241, 120.148, share_allowed=False)
        add_media(db, "隐藏日期", 30.241, 120.148, timeline_date=date(2026, 7, 2))
        add_media(db, "隐藏文件夹", 30.241, 120.148, folder_id=folder.id)
        add_media(db, "回收站", 30.241, 120.148, status="deleted")
        add_media(db, "头像", 30.241, 120.148, purpose="avatar")
        child_id = child.id
        db.commit()

    client = context.client
    admin = client.get("/api/media/map")
    assert admin.status_code == 200, admin.text
    assert admin.json()["located_total"] == 8

    client.cookies.set("yearly_session", "viewer")
    overview = client.get("/api/media/map")
    assert overview.status_code == 200, overview.text
    data = overview.json()
    assert data["level"] == "country"
    assert data["located_total"] == 5
    assert data["unlocated_total"] == 2
    groups = {group["name"]: group for group in data["groups"]}
    assert groups["中国"]["count"] == 3
    assert groups["中国"]["next_level"] == "region"
    assert groups["美国"]["next_level"] == "local"

    response = client.get("/api/media/map/items", params={
        "group": groups["中国"]["id"], "level": "country", "page_size": 2,
    })
    assert response.status_code == 200, response.text
    assert response.json()["total"] == 3 and len(response.json()["items"]) == 2
    second = client.get("/api/media/map/items", params={
        "group": groups["中国"]["id"], "level": "country", "page_size": 2, "page": 2,
    }).json()
    assert len(second["items"]) == 1
    assert {item["title"] for item in [*response.json()["items"], *second["items"]]} == {"杭州西湖", "拙政园", "上海外滩"}

    area = {"south": 30, "north": 32, "west": 119, "east": 123, "level": "region"}
    provinces = client.get("/api/media/map", params=area).json()
    assert {group["name"] for group in provinces["groups"]} == {"浙江省", "江苏省", "上海市"}
    assert provinces["unlocated_total"] is None

    filtered = client.get("/api/media/map", params={
        **area, "owner_id": 1, "child_id": child_id, "media_type": "photo",
        "start": "2026-05-01", "end": "2026-05-02",
    }).json()
    assert filtered["located_total"] == 1
    assert filtered["groups"][0]["name"] == "浙江省"

    unlocated = client.get("/api/media/map/items", params={"scope": "unlocated"}).json()
    assert unlocated["total"] == 2
    assert {item["title"] for item in unlocated["items"]} == {"经度未知", "仅有地点名"}
    client.cookies.clear()
    assert client.get("/api/media/map").status_code == 401


def test_map_wraps_date_line_and_matches_local_bucket(context):
    with context.db() as db:
        add_media(db, "日期线东侧", 11, 179.99)
        add_media(db, "日期线西侧", 11.002, -179.99)
        add_media(db, "日期线", 11.003, 180)
        add_media(db, "范围外", 11, 0)
        db.commit()
    client = context.client
    area = {"south": 10.99, "north": 11.03, "west": 179.8, "east": -179.8}
    response = client.get("/api/media/map", params=area)
    assert response.status_code == 200, response.text
    data = response.json()
    assert data["bounds"]["west"] == 179.99 and data["bounds"]["east"] == -179.99
    assert data["located_total"] == 3 and data["level"] == "local"
    for group in data["groups"]:
        items = client.get("/api/media/map/items", params={**area, "group": group["id"], "level": "local"})
        assert items.json()["total"] == group["count"]
        assert abs(group["longitude"]) >= 179.99
    assert client.get("/api/media/map", params={"west": 10}).status_code == 422
    assert client.get("/api/media/map", params={**area, "north": 0}).status_code == 422
    assert client.get("/api/media/map/items", params={"group": data["groups"][0]["id"]}).status_code == 422


def test_offline_boundary_data_and_bounds():
    assert administrative_place(30.241, 120.148, "region")[1] == "浙江省"
    assert administrative_place(37.7726, -122.4602, "country")[1] == "美国"
    assert administrative_place(0, 0, "country") is None
    assert geographic_bounds([(1, 180), (2, -180)]) == {"south": 1, "north": 2, "west": -180, "east": -180}


def test_sparse_map_covers_are_visible_completed_originals(context, monkeypatch):
    def original(db, media_id, status="complete"):
        file = MediaFile(
            media_id=media_id, file_role="original", oss_bucket="fixture",
            oss_object_key=f"fixture/{media_id}", original_filename="photo.jpg",
            mime_type="image/jpeg", file_size=10, sha256="0" * 64, crc64="0", upload_status=status,
        )
        db.add(file)
        db.flush()
        return file.id

    with context.db() as db:
        public_media = add_media(db, "西湖", 30.241, 120.148)
        public_file = original(db, public_media)
        original(db, add_media(db, "隐藏照片", 30.241, 120.148, share_allowed=False))
        original(db, add_media(db, "等待原件", 31.324, 120.629), status="pending")
        for index in range(4):
            original(db, add_media(db, f"上海影像{index}", 31.239, 121.49))
        db.commit()

    client = context.client
    client.cookies.set("yearly_session", "viewer")
    area = {"south": 30, "north": 32, "west": 119, "east": 123, "level": "region"}
    result = client.get("/api/media/map", params={**area, "include_covers": True})
    assert result.status_code == 200, result.text
    groups = {group["name"]: group for group in result.json()["groups"]}
    assert groups["浙江省"]["cover"] == {
        "media_id": public_media, "file_id": public_file, "media_type": "photo", "title": "西湖",
    }
    assert all("sample_id" not in group for group in groups.values())
    assert "cover" not in groups["江苏省"]
    assert "cover" not in groups["上海市"]

    result = client.get("/api/media/map", params=area)
    assert all("cover" not in group for group in result.json()["groups"])
    monkeypatch.setattr("app.media_map.MAX_COVER_GROUPS", 2)
    result = client.get("/api/media/map", params={**area, "include_covers": True})
    assert len(result.json()["groups"]) == 3
    assert all("cover" not in group for group in result.json()["groups"])
