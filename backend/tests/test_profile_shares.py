"""Person scope is enforced on every public entry point and card resource."""
from datetime import timedelta
from io import BytesIO

import pytest
from PIL import Image

from app.db import now
from app.models import Child, Media, TimelineShare
from conftest import child, upload
from test_folders import folder
from test_people import person as create_person
from test_pets import pet
from test_shares import share


def avatar_profile(context, name, color, sort_order=0):
    image = BytesIO()
    Image.new("RGB", (96, 64), color).save(image, format="PNG")
    media = upload(context, content=image.getvalue(), purpose="avatar")["media_id"]
    profile = child(context, name)
    response = context.client.put(f"/api/children/{profile['id']}", json={
        "name": name, "birthday": profile["birthday"], "avatar_media_id": media, "sort_order": sort_order,
    })
    assert response.status_code == 200, response.text
    return profile["id"], media


def test_person_share_filters_folders_events_and_direct_media_access(context):
    person, second, other = child(context, "小禾"), child(context, "小满"), child(context, "小树")
    parent, unrelated = folder(context), folder(context, "其他人的相册")
    chosen = upload(context, [person["id"], second["id"]], folder_id=parent["id"])["media_id"]
    second_only = upload(context, [second["id"]], folder_id=parent["id"])["media_id"]
    sibling = upload(context, [other["id"]], folder_id=parent["id"])["media_id"]
    elsewhere = upload(context, [other["id"]], folder_id=unrelated["id"])["media_id"]
    event = context.client.post("/api/events", json={"title": "小满的记录", "start_at": "2024-03-31T12:00:00", "child_ids": [second["id"]]}).json()
    context.client.post("/api/events", json={"title": "其他记录", "start_at": "2024-03-31T13:00:00", "child_ids": [other["id"]]})
    data = share(context, profile_ids=[person["id"], second["id"], person["id"]])
    assert data["card_title"] == "小禾、小满的成长相册"
    assert not data["has_avatar"]
    copied = context.client.post(f'/api/shares/{data["id"]}/copy', json={"hours": 1}).json()
    assert copied["profile_ids"] == [person["id"], second["id"]]
    base = "/api/public/shares/" + data["token"]
    context.client.cookies.clear()
    items = context.client.get(base).json()["days"][0]["items"]
    assert {(item["kind"], item["id"]) for item in items} == {
        ("media", chosen), ("media", second_only), ("event", event["id"]),
    }
    assert len(items) == 3
    assert context.client.get(f"{base}/media/{elsewhere}/url").status_code == 404
    assert context.client.get(f"{base}/media/{sibling}/url").status_code == 404
    assert context.client.get(f"{base}/media/{chosen}/url").status_code == 200


def test_person_selection_intersects_explicit_media_and_validates_profile(context):
    person, other = child(context, "小禾"), child(context, "小满")
    chosen = upload(context, [person["id"]])["media_id"]
    excluded = upload(context, [other["id"]])["media_id"]
    result = context.client.post("/api/shares", json={"media_ids": [chosen, excluded], "profile_ids": [person["id"]]}).json()
    body = context.client.get("/api/public/shares/" + result["token"]).json()
    assert [item["id"] for item in body["days"][0]["items"]] == [chosen]
    assert context.client.post("/api/shares", json={"media_ids": [chosen], "profile_ids": [999999999]}).status_code == 422
    assert context.client.post("/api/shares", json={"media_ids": [chosen], "profile_ids": [other["id"]]}).status_code == 422


def test_card_copy_uses_profiles_and_share_scope(context):
    baby = create_person(context, "小禾", "孩子")
    parent = create_person(context, "妈妈", "妈妈")
    animal = pet(context)
    chosen = upload(context, [baby["id"]])["media_id"]
    family = share(context)
    mixed = share(context, profile_ids=[baby["id"], parent["id"], animal["id"]])
    selected = context.client.post("/api/shares", json={
        "media_ids": [chosen], "profile_ids": [baby["id"]],
    }).json()

    assert family["card_title"] == "我们的家庭相册"
    assert mixed["card_title"] == "小禾、妈妈等 3 位的时光相册"
    assert family["card_description"] == mixed["card_description"] == (
        "一起翻翻这些日子里的回忆。打开链接，无需登录。"
    )
    assert selected["card_title"] == "小禾的成长相册"
    assert selected["card_description"] == "挑了些喜欢的瞬间，想和你分享。打开链接，无需登录。"

    context.client.cookies.clear()
    base = "/api/public/shares/" + selected["token"]
    public = context.client.get(base).json()["share"]
    page = context.client.get(base + "/page")
    for tag, field in (("title", "card_title"), ("description", "card_description")):
        assert public[field] == selected[field]
        assert f'<meta property="og:{tag}" content="{selected[field]}">' in page.text


def test_public_cards_show_capture_ages_for_tagged_children(context):
    client = context.client
    baby = child(context, "大名", "2024-03-31")
    response = client.put(f"/api/children/{baby['id']}", json={
        "name": "大名", "nickname": "小禾", "birthday": "2024-03-31",
    })
    assert response.status_code == 200, response.text
    sibling = create_person(context, "小满", "孩子", birthday="2024-01-31")
    parent = create_person(context, "妈妈", "妈妈", birthday="1990-01-01", growth_enabled=True)
    hidden_age = create_person(context, "小雨", "孩子", birthday="2024-03-01", growth_enabled=False)
    no_birthday = create_person(context, "小风", "孩子")
    animal = pet(context, birthday="2020-01-01")
    children = [p["id"] for p in (baby, sibling, parent, hidden_age, no_birthday, animal)]
    album = folder(context)
    root = upload(context, children, taken="2024-03-30T10:00:00", timeline_date="2024-04-02")["media_id"]
    edit = client.put(f"/api/media/{root}", json={
        "corrected_taken_at_local": "2024-03-31T10:00:00", "child_ids": children,
    })
    assert edit.status_code == 200, edit.text
    nested = upload(context, [baby["id"], parent["id"]], folder_id=album["id"])["media_id"]
    unknown = upload(context, [baby["id"], parent["id"]], taken=None, timeline_date="2024-04-02")["media_id"]
    date_share = share(context, profile_ids=[parent["id"]])
    selection = client.post("/api/shares", json={"media_ids": [nested, unknown]}).json()
    client.cookies.clear()

    base = "/api/public/shares/" + date_share["token"]
    expected = [{"name": "小禾", "age": "出生当天"}, {"name": "小满", "age": "2 个月"}]
    for page in (client.get(base).json()["days"][0], client.get(base + "/days/2024-04-02").json()):
        by_id = {item["id"]: item for item in page["items"]}
        assert by_id[root] == {
            "kind": "media", "id": root, "title": "", "media_type": "photo", "child_ages": expected,
        }
        assert "child_ages" not in by_id[unknown]
    archived = client.get(base + "/days/2024-03-31").json()["items"]
    selected_items = client.get("/api/public/shares/" + selection["token"]).json()["days"][0]["items"]
    assert archived[0]["id"] == nested
    assert selected_items[0] == archived[0]
    assert selected_items[0]["child_ages"] == expected[:1]
    assert "child_ages" not in selected_items[1]


@pytest.mark.parametrize("unavailable", ["revoked", "expired"])
def test_person_metadata_and_avatar_follow_link_expiry_and_escape_titles(context, unavailable):
    avatar = upload(context)["media_id"]
    person = child(context, '小禾 <script>')
    updated = context.client.put(f'/api/children/{person["id"]}', json={
        "name": person["name"], "birthday": person["birthday"], "avatar_media_id": avatar,
    })
    assert updated.status_code == 200, updated.text
    data = share(context, profile_ids=[person["id"]], title='相册 " <测试>')
    base = "/api/public/shares/" + data["token"]
    page = context.client.get(base + "/page")
    assert page.status_code == 200
    assert '<h1>相册 &quot; &lt;测试&gt;</h1>' in page.text
    assert '<meta property="og:title" content="相册 &quot; &lt;测试&gt;">' in page.text
    assert page.headers["cache-control"] == "no-store"
    assert int(page.headers["content-length"]) == len(page.content)
    assert f'{base}/avatar' in page.text
    assert '/share-entry.js' in page.text
    assert '<script>' not in page.text
    assert context.client.get(base + "/avatar", follow_redirects=False).status_code == 302
    assert context.client.get(base + "/avatar?redirect=false").json()["url"] == "https://private.invalid/thumbnail"
    assert context.storage.last_expiry <= 60
    with context.db() as db:
        record = db.get(TimelineShare, data["id"])
        if unavailable == "revoked":
            record.revoked = True
        else:
            record.expires_at = now() - timedelta(seconds=1)
        db.commit()
    unavailable_page = context.client.get(base + "/page")
    assert unavailable_page.status_code == 404
    assert "<h1>分享已失效或不存在</h1>" in unavailable_page.text
    assert "小禾" not in unavailable_page.text
    assert context.client.get(base + "/avatar", follow_redirects=False).status_code == 404


def test_deleting_a_selected_profile_invalidates_the_link(context):
    first, second = child(context, "小禾"), child(context, "小满")
    upload(context, [second["id"]])
    data = share(context, profile_ids=[first["id"], second["id"]])
    response = context.client.delete(f"/api/children/{first['id']}", params={"confirm_name": first["name"]})
    assert response.status_code == 200, response.text
    assert context.client.get("/api/public/shares/" + data["token"]).status_code == 404
    assert context.client.post(f"/api/shares/{data['id']}/copy", json={"hours": 24}).status_code == 422


@pytest.mark.parametrize("scope", ["selected", "all"])
def test_group_cover_uses_the_first_nine_avatars_in_profile_order(context, scope):
    colors = [(20 + i * 20, 50, 200 - i * 10) for i in range(12)]
    profiles = [
        avatar_profile(context, f"档案 {i}", color, -max(0, i - 8))[0]
        for i, color in enumerate(colors)
    ]
    with context.db() as db:
        db.get(Child, profiles[11]).status = "archived"
        db.commit()
    unpictured = child(context, "没有头像")["id"]
    selected = [unpictured, *reversed(profiles[:10])] if scope == "selected" else []
    expected = [colors[9], *colors[:8]] if selected else [colors[10], colors[9], *colors[:7]]
    data = share(context, profile_ids=selected)
    assert data["has_avatar"] is True and data["profile_name"] is None
    saved = context.client.get("/api/shares").json()[0]
    assert saved["has_avatar"] is True and saved["profile_ids"] == sorted(selected)
    base = "/api/public/shares/" + data["token"]
    context.client.cookies.clear()

    page = context.client.get(base + "/page")
    published = context.client.get(base).json()["share"]
    assert published["has_avatar"] is True and published["profile_ids"] == sorted(selected)
    resource = context.client.get(base + "/avatar?redirect=false").json()
    assert resource["mime_type"] == "image/png"
    assert resource["url"].endswith(base + "/avatar")
    assert f'<meta property="og:image" content="{resource["url"]}">' in page.text

    response = context.client.get(base + "/avatar")
    assert response.status_code == 200
    assert response.headers["content-type"] == "image/png"
    assert response.headers["cache-control"] == "no-store"
    assert response.headers["x-robots-tag"] == "noindex, nofollow, noarchive"
    with Image.open(BytesIO(response.content)) as cover:
        assert cover.size == (360, 360)
        pixels = [cover.getpixel((x, y)) for y in (66, 180, 294) for x in (66, 180, 294)]
        assert pixels == expected

    with context.db() as db:
        db.get(TimelineShare, data["id"]).revoked = True
        db.commit()
    assert context.client.get(base + "/avatar").status_code == 404
    assert context.client.get(base + "/avatar?redirect=false").status_code == 404


def test_group_cover_omits_restricted_avatars_and_can_fall_back_to_the_logo(context):
    first, first_image = avatar_profile(context, "第一位", (80, 100, 240))
    second, second_image = avatar_profile(context, "第二位", (120, 180, 45))
    third, third_image = avatar_profile(context, "第三位", (240, 180, 70))
    data = share(context, profile_ids=[first, second, third])
    base = "/api/public/shares/" + data["token"]
    context.client.cookies.clear()
    with context.db() as db:
        db.get(Media, second_image).share_allowed = False
        db.commit()

    response = context.client.get(base + "/avatar")
    with Image.open(BytesIO(response.content)) as cover:
        assert cover.getpixel((90, 180)) == (80, 100, 240)
        assert cover.getpixel((270, 180)) == (240, 180, 70)
        assert cover.getpixel((180, 30)) == (232, 234, 237)

    with context.db() as db:
        db.get(Media, first_image).status = "deleted"
        db.get(Media, third_image).share_allowed = False
        db.commit()
    fallback = context.client.get(base + "/avatar", follow_redirects=False)
    assert fallback.status_code == 302
    assert fallback.headers["location"].endswith("/share-logo.png")
