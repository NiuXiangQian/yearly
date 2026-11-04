from conftest import child, upload, file_payload


def test_independent_avatar_can_be_saved_replaced_and_cleared_without_timeline_entry(
    context,
):
    avatar = upload(context, purpose="avatar", content=b"avatar-image")["media_id"]
    ordinary = upload(context, content=b"avatar-image")["media_id"]
    assert avatar != ordinary
    assert upload(context, purpose="avatar", content=b"avatar-image")["duplicate"]
    c = context.client.post(
        "/api/children",
        json={
            "name": "宝宝",
            "birthday": "2024-03-31",
            "avatar_media_id": avatar,
        },
    ).json()
    assert c["avatar_media_id"] == avatar
    media = context.client.get(f"/api/media/{avatar}").json()
    assert media["purpose"] == "avatar"
    fid = media["files"][0]["id"]
    assert (
        context.client.get(
            f"/api/media/{avatar}/files/{fid}/url?purpose=thumbnail"
        ).status_code
        == 200
    )
    assert context.client.get("/api/stats").json()["media"] == 1
    assert [m["id"] for m in context.client.get("/api/media").json()["items"]] == [
        ordinary
    ]
    assert [
        m["id"]
        for m in context.client.get("/api/timeline?group_folders=true").json()["items"]
    ] == [ordinary]
    c["avatar_media_id"] = ordinary
    assert (
        context.client.put(f"/api/children/{c['id']}", json=c).json()["avatar_media_id"]
        == ordinary
    )
    c["avatar_media_id"] = None
    assert (
        context.client.put(f"/api/children/{c['id']}", json=c).json()["avatar_media_id"]
        is None
    )
    manifest = context.client.get("/api/export/manifest").json()
    assert any(
        m["id"] == avatar and m["purpose"] == "avatar"
        for m in manifest["tables"]["media"]
    )
    assert any(f["media_id"] == avatar for f in manifest["tables"]["media_file"])


def test_avatar_upload_validation_and_permissions(context):
    base = {"purpose": "avatar", "media_type": "photo", "files": [file_payload()]}
    oversized = {**file_payload(), "file_size": 1024 * 1024 + 1}
    for changes in (
        {"files": [oversized]},
        {"media_type": "video"},
        {"folder_id": 1},
        {"child_ids": [1]},
    ):
        assert (
            context.client.post("/api/uploads", json={**base, **changes}).status_code
            == 422
        )
    context.client.cookies.set("yearly_session", "viewer")
    context.client.headers["X-CSRF-Token"] = "csrf-viewer"
    assert context.client.post("/api/uploads", json=base).status_code == 403


def test_video_cannot_be_used_as_child_avatar(context):
    video = upload(context, media_type="video", files=[file_payload(name="clip.mp4")])[
        "media_id"
    ]
    c = child(context)
    c["avatar_media_id"] = video
    assert context.client.put(f"/api/children/{c['id']}", json=c).status_code == 422
