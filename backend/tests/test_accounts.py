from datetime import date

from app.models import AuditLog, Media, TimelineFolder, User, UserSession
from conftest import child, file_payload, upload
from sqlalchemy import select


def act(context, role):
    context.client.cookies.set("yearly_session", role)
    context.client.headers["X-CSRF-Token"] = "csrf-" + role


def test_member_locks_foreign_content_and_batch_rolls_back(context):
    other = upload(context)["media_id"]
    act(context, "member")
    own = upload(context)["media_id"]
    client = context.client
    assert client.get(f"/api/media/{other}").json()["can_edit"] is False
    assert client.get(f"/api/media/{own}").json()["can_edit"] is True
    assert (
        client.put(f"/api/media/{other}", json={"title": "forbidden"}).status_code
        == 403
    )
    assert client.delete(f"/api/media/{other}").status_code == 403
    assert client.post(f"/api/media/{other}/restore", json={}).status_code == 403
    for path, body in [
        (
            "/api/media/batch-organize",
            {"media_ids": [own, other], "batch_name": "forbidden"},
        ),
        ("/api/media/batch-children", {"media_ids": [own, other], "child_ids": []}),
        ("/api/folders/move-media", {"media_ids": [own, other]}),
        ("/api/media/reset-order", {"day": "2024-03-31"}),
        ("/api/media/reorder", {"media_ids": [own], "target_id": other}),
        (
            "/api/timeline/reorder",
            {
                "items": [{"kind": "media", "id": own}],
                "target": {"kind": "media", "id": other},
            },
        ),
    ]:
        assert client.post(path, json=body).status_code == 403, path
    assert (
        client.put(f"/api/media/{own}", json={"title": "my photo"}).status_code == 200
    )
    assert client.delete(f"/api/media/{own}").status_code == 200
    assert client.post(f"/api/media/{own}/restore", json={}).status_code == 200
    with context.db() as db:
        assert db.get(Media, own).batch_name == ""
        assert db.get(Media, other).title == ""
        assert not db.scalar(
            select(AuditLog.id).where(
                AuditLog.actor_id == 2,
                AuditLog.resource_id == str(other),
                AuditLog.resource_type == "media",
            )
        )


def test_folders_profiles_events_and_global_settings(context):
    client = context.client
    foreign = client.post(
        "/api/folders", json={"name": "admin folder", "timeline_date": "2024-03-31"}
    ).json()["id"]
    profile = child(context)
    event = client.post("/api/events", json={"title": "admin journal"}).json()["id"]
    act(context, "member")
    mid = upload(context)["media_id"]
    folder = client.post(
        "/api/folders", json={"name": "my folder", "timeline_date": "2024-03-31"}
    ).json()["id"]
    assert (
        client.put(f"/api/folders/{foreign}", json={"name": "forbidden"}).status_code
        == 403
    )
    assert client.delete(f"/api/folders/{foreign}").status_code == 403
    assert (
        client.post(
            "/api/folders/move-media", json={"media_ids": [mid], "folder_id": foreign}
        ).status_code
        == 403
    )
    assert (
        client.post(
            "/api/folders/move-media", json={"media_ids": [mid], "folder_id": folder}
        ).status_code
        == 200
    )
    assert (
        client.put(f"/api/folders/{folder}", json={"name": "renamed"}).status_code
        == 200
    )
    assert (
        client.put(
            f"/api/children/{profile['id']}",
            json={"name": "forbidden", "birthday": "2020-01-01"},
        ).status_code
        == 403
    )
    assert (
        client.put(f"/api/events/{event}", json={"title": "forbidden"}).status_code
        == 403
    )
    assert client.delete(f"/api/events/{event}").status_code == 403
    assert client.post(f"/api/events/{event}/restore", json={}).status_code == 403
    assert (
        client.put(
            "/api/timeline/days/2024-03-31/sharing", json={"share_allowed": False}
        ).status_code
        == 403
    )
    assert client.get("/api/users").status_code == 403
    act(context, "admin")
    assert (
        client.put(f"/api/folders/{folder}", json={"name": "admin updated"}).status_code
        == 200
    )
    assert (
        client.put(f"/api/media/{mid}", json={"title": "admin updated"}).status_code
        == 200
    )
    with context.db() as db:
        assert db.get(Media, mid).owner_id == 2
        assert db.get(Media, mid).updated_by == 1
        assert db.get(TimelineFolder, folder).updated_by == 1


def test_legacy_ownership_is_admin_managed(context):
    with context.db() as db:
        folder = TimelineFolder(name="legacy", timeline_date=date(2024, 3, 31))
        db.add(folder)
        db.commit()
        fid = folder.id
    act(context, "member")
    assert context.client.get(f"/api/folders/{fid}").json()["can_edit"] is False
    assert (
        context.client.put(f"/api/folders/{fid}", json={"name": "claimed"}).status_code
        == 403
    )
    act(context, "admin")
    assert (
        context.client.put(f"/api/folders/{fid}", json={"name": "managed"}).status_code
        == 200
    )


def test_audit_fields_relationship_changes_and_visibility(context):
    client = context.client
    profile = child(context)
    act(context, "member")
    mid = upload(context)["media_id"]
    assert (
        client.post(
            "/api/media/batch-children",
            json={"media_ids": [mid], "child_ids": [profile["id"]]},
        ).status_code
        == 200
    )
    assert (
        client.put(
            f"/api/media/{mid}", json={"title": "changed", "child_ids": [profile["id"]]}
        ).status_code
        == 200
    )
    result = client.get(f"/api/audit-logs?resource_type=media&resource_id={mid}").json()
    assert any(
        row["changes"].get("title") == {"before": "", "after": "changed"}
        for row in result["items"]
    )
    assert any(
        row["changes"].get("child_ids") == {"before": [], "after": [profile["id"]]}
        for row in result["items"]
    )
    assert all(
        row["actor_id"] == 2 for row in client.get("/api/audit-logs").json()["items"]
    )
    with context.db() as db:
        assert db.get(Media, mid).updated_by == 2
    act(context, "admin")
    assert client.get("/api/audit-logs").json()["total"] > result["total"]


def test_account_admin_update_disable_reenable_and_password_redaction(context):
    client = context.client
    assert (
        client.put(
            "/api/users/1", json={"username": "admin", "role": "member", "active": True}
        ).status_code
        == 422
    )
    assert client.delete("/api/users/1").status_code == 422
    assert (
        client.put(
            "/api/users/2",
            json={
                "username": "renamed",
                "role": "admin",
                "active": False,
                "password": "new-password-123",
            },
        ).status_code
        == 200
    )
    with context.db() as db:
        user = db.get(User, 2)
        assert user.username == "renamed" and user.role == "admin" and not user.active
        assert not db.scalar(select(UserSession.id).where(UserSession.user_id == 2))
    assert (
        client.put(
            "/api/users/2",
            json={"username": "renamed", "role": "member", "active": True},
        ).status_code
        == 200
    )
    assert (
        client.post(
            "/api/users",
            json={
                "username": "new-user",
                "password": "new-password-123",
                "role": "member",
            },
        ).status_code
        == 200
    )
    assert (
        client.post(
            "/api/users",
            json={
                "username": "new-user",
                "password": "new-password-123",
                "role": "member",
            },
        ).status_code
        == 409
    )
    logs = client.get("/api/audit-logs?resource_type=sys_user").json()
    assert "new-password-123" not in str(logs) and "argon2" not in str(logs)
    assert any(
        row["changes"].get("password") == {"changed": True} for row in logs["items"]
    )


def test_duplicate_upload_never_modifies_foreign_media(context):
    data = b"same-original-across-accounts"
    mid = upload(context, content=data)["media_id"]
    profile = child(context)
    act(context, "member")
    result = context.client.post(
        "/api/uploads",
        json={
            "media_type": "photo",
            "files": [file_payload(data)],
            "child_ids": [profile["id"]],
        },
    )
    assert result.status_code == 200 and result.json()["duplicate"]
    assert context.client.get(f"/api/media/{mid}").json()["child_ids"] == []


def test_member_shares_only_own_content(context):
    client = context.client
    other = upload(context)["media_id"]
    act(context, "member")
    own = upload(context)["media_id"]
    assert client.post("/api/shares", json={"media_ids": [other]}).status_code == 422
    share = client.post(
        "/api/shares", json={"start_date": "2024-01-01", "end_date": "2024-12-31"}
    ).json()
    public = client.get(f"/api/public/shares/{share['token']}").json()
    assert [m["id"] for day in public["days"] for m in day["items"]] == [own]


def test_admin_copy_preserves_member_share_scope_and_role_change_revokes(context):
    client = context.client
    upload(context)
    act(context, "member")
    own = upload(context)["media_id"]
    share = client.post(
        "/api/shares", json={"start_date": "2024-01-01", "end_date": "2024-12-31"}
    ).json()
    act(context, "admin")
    copied = client.post(f"/api/shares/{share['id']}/copy", json={}).json()
    public = client.get(f"/api/public/shares/{copied['token']}").json()
    assert [m["id"] for day in public["days"] for m in day["items"]] == [own]
    assert (
        client.put(
            "/api/users/2", json={"username": "member", "role": "admin", "active": True}
        ).status_code
        == 200
    )
    assert client.get(f"/api/public/shares/{share['token']}").status_code == 404


def test_failed_mixed_batch_rolls_back_links_and_history(context):
    act(context, "member")
    own = upload(context)["media_id"]
    act(context, "admin")
    other = upload(context)["media_id"]
    profile = child(context)
    act(context, "member")
    with context.db() as db:
        previous_logs = list(db.scalars(select(AuditLog.id)))
    result = context.client.post(
        "/api/media/batch-children",
        json={"media_ids": [own, other], "child_ids": [profile["id"]]},
    )
    assert result.status_code == 403
    assert context.client.get(f"/api/media/{own}").json()["child_ids"] == []
    with context.db() as db:
        assert list(db.scalars(select(AuditLog.id))) == previous_logs


def test_uploader_filter_keeps_counts_dates_positions_and_deleted_content_scoped(
    context,
):
    client = context.client
    admin_media = upload(context, taken="2024-04-01T10:00:00")["media_id"]
    client.post(
        "/api/events",
        json={"title": "administrator journal", "start_at": "2024-04-01T10:00:00"},
    )
    act(context, "member")
    own = upload(context, taken="2024-03-31T10:00:00")["media_id"]
    event = client.post(
        "/api/events",
        json={"title": "member journal", "start_at": "2024-03-31T10:00:00"},
    ).json()["id"]
    assert {row["id"] for row in client.get("/api/uploaders").json()} == {1, 2}
    assert all(
        set(row) == {"id", "username", "nickname"} for row in client.get("/api/uploaders").json()
    )
    result = client.get(
        "/api/timeline?owner_id=2&include_dates=true&media_positions=true&group_folders=false"
    ).json()
    assert result["total"] == 2 and result["dates"] == ["2024-03-31"]
    assert {(row["kind"], row["id"]) for row in result["items"]} == {
        ("media", own),
        ("event", event),
    }
    media = next(row for row in result["items"] if row["kind"] == "media")
    assert media["media_position"] == {
        "index": 1,
        "total": 1,
        "day_index": 1,
        "day_total": 1,
    }
    assert client.get("/api/media?owner_id=1").json()["items"][0]["id"] == admin_media
    assert client.get("/api/events?owner_id=2").json()["total"] == 1
    assert client.get("/api/timeline?owner_id=999999999").json()["total"] == 0
    assert client.get("/api/timeline?owner_id=0").status_code == 422
    assert client.delete(f"/api/media/{own}").status_code == 200
    deleted = client.get("/api/timeline?status=deleted&owner_id=2").json()
    assert deleted["total"] == 1 and deleted["items"][0]["id"] == own
    assert {row["id"] for row in client.get("/api/uploaders").json()} == {1, 2}


def test_grouped_uploader_filter_scopes_folder_previews_and_count(context):
    client = context.client
    folder = client.post(
        "/api/folders", json={"name": "mixed folder", "timeline_date": "2024-03-31"}
    ).json()["id"]
    upload(context, folder_id=folder)
    act(context, "member")
    own = upload(context)["media_id"]
    act(context, "admin")
    assert (
        client.post(
            "/api/folders/move-media", json={"media_ids": [own], "folder_id": folder}
        ).status_code
        == 200
    )
    result = client.get("/api/timeline?owner_id=2&group_folders=true").json()
    assert result["total"] == 1
    assert result["items"][0]["media_count"] == 1
    assert [row["id"] for row in result["items"][0]["previews"]] == [own]
    assert client.get(f"/api/media?folder_id={folder}&owner_id=2").json()["total"] == 1


def test_uploaders_empty_and_authentication(context):
    assert context.client.get("/api/uploaders").json() == []
    context.client.cookies.clear()
    assert context.client.get("/api/uploaders").status_code == 401


def test_account_nickname_create_edit_and_clear(context):
    client = context.client
    created = client.post("/api/users", json={
        "username": "family-login", "nickname": "  小禾爸爸  ",
        "password": "testing-password-123", "role": "member",
    })
    assert created.status_code == 200
    uid = created.json()["id"]
    row = next(row for row in client.get("/api/users").json() if row["id"] == uid)
    assert row["username"] == "family-login" and row["nickname"] == "小禾爸爸"
    payload = {"username": "family-login", "nickname": "小禾爸爸", "role": "member", "active": True}
    assert client.put(f"/api/users/{uid}", json=payload).status_code == 200
    with context.db() as db:
        assert db.get(User, uid).display_name == "小禾爸爸"
    assert client.put(f"/api/users/{uid}", json={**payload, "nickname": "  "}).status_code == 200
    with context.db() as db:
        assert db.get(User, uid).nickname == "" and db.get(User, uid).display_name == "family-login"
    for nickname in ["禾" * 80, "禾" * 81]:
        response = client.put(f"/api/users/{uid}", json={**payload, "nickname": nickname})
        assert response.status_code == (200 if len(nickname) == 80 else 422)
    act(context, "member")
    assert client.put(f"/api/users/{uid}", json={**payload, "nickname": "越权"}).status_code == 403


def test_nickname_display_session_and_audit_use_current_account_name(context):
    client = context.client
    mid = upload(context)["media_id"]
    before = client.get("/api/auth/me").json()
    response = client.put("/api/users/1", json={
        "username": "admin", "nickname": "家庭管理员", "role": "admin", "active": True,
    })
    assert response.status_code == 200 and response.json()["reauthenticate"] is False
    after = client.get("/api/auth/me").json()
    assert after["nickname"] == "家庭管理员" and after["username"] == "admin"
    assert before["csrf_token"] == after["csrf_token"]
    assert client.get("/api/uploaders").json() == [{"id": 1, "username": "admin", "nickname": "家庭管理员"}]
    media = client.get(f"/api/media/{mid}").json()
    assert media["owner_name"] == "家庭管理员" and media["updated_by_name"] == "家庭管理员"
    history = client.get(f"/api/audit-logs?resource_type=media&resource_id={mid}").json()
    assert all(row["actor_name"] == "家庭管理员" for row in history["items"])
    logs = client.get("/api/audit-logs?resource_type=sys_user&resource_id=1").json()
    assert any(row["changes"].get("nickname") == {"before": "", "after": "家庭管理员"} for row in logs["items"])
    assert client.put("/api/users/1", json={"username": "admin", "nickname": "", "role": "admin", "active": True}).status_code == 200
    assert client.get(f"/api/media/{mid}").json()["owner_name"] == "admin"
    with context.db() as db:
        assert db.get(User, 1).username == "admin"
        assert db.scalar(select(UserSession.id).where(UserSession.user_id == 1))


def test_login_returns_nickname_and_keeps_username_as_login_identifier(context):
    from test_security import challenge

    with context.db() as db:
        db.get(User, 1).nickname = "小禾爸爸"
        db.commit()
    payload = challenge(context)
    assert context.client.post("/api/auth/login", json={**payload, "username": "小禾爸爸"}).status_code == 401
    payload = challenge(context)
    result = context.client.post("/api/auth/login", json=payload)
    assert result.status_code == 200
    assert result.json()["username"] == "admin" and result.json()["nickname"] == "小禾爸爸"
