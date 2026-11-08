from datetime import timedelta
from app.models import Captcha, UserSession
from app.db import now
from app.security import digest
from conftest import upload


def challenge(context, code="ABCDE"):
    with context.db() as db:
        db.add(
            Captcha(
                id="challenge",
                answer_hash=digest(code),
                expires_at=now() + timedelta(minutes=5),
            )
        )
        db.commit()
    return {
        "username": "admin",
        "password": "testing-password-123",
        "captcha_id": "challenge",
        "captcha": code,
    }


def test_login_session_captcha_single_use_and_logout(context):
    client = context.client
    client.cookies.clear()
    payload = challenge(context)
    result = client.post("/api/auth/login", json=payload)
    assert result.status_code == 200
    assert "HttpOnly" in result.headers["set-cookie"]
    assert "SameSite=strict" in result.headers["set-cookie"]
    assert client.post("/api/auth/login", json=payload).status_code == 400
    csrf = result.json()["csrf_token"]
    assert client.get("/api/auth/me").json()["username"] == "admin"
    client.headers["X-CSRF-Token"] = csrf
    assert client.post("/api/auth/logout", json={}).status_code == 200
    assert client.get("/api/media").status_code == 401


def test_private_routes_and_roles(context):
    result = upload(context)
    client = context.client
    client.cookies.clear()
    for path in [
        "/api/media",
        "/api/children",
        "/api/events",
        "/api/stats",
        "/api/export/manifest",
        f"/api/media/{result['media_id']}/files/{result['tasks'][0]['file_id']}/url",
    ]:
        assert client.get(path).status_code == 401
    client.cookies.set("yearly_session", "viewer")
    client.headers["X-CSRF-Token"] = "csrf-viewer"
    assert client.get("/api/media").status_code == 200
    assert (
        client.post(
            "/api/children", json={"name": "test", "birthday": "2020-01-01"}
        ).status_code
        == 403
    )
    assert client.post("/api/events", json={"title": "test"}).status_code == 403
    for path in ["/api/users", "/api/settings", "/api/export/manifest"]:
        assert client.get(path).status_code == 403
    client.cookies.set("yearly_session", "member")
    client.headers["X-CSRF-Token"] = "csrf-member"
    assert (
        client.post(
            "/api/children", json={"name": "test", "birthday": "2020-01-01"}
        ).status_code
        == 200
    )
    assert (
        client.post(
            "/api/users", json={"username": "test", "password": "a-long-password"}
        ).status_code
        == 403
    )


def test_csrf_origin_and_rate_limit(context):
    client = context.client
    data = {"name": "test", "birthday": "2020-01-01"}
    client.headers["X-CSRF-Token"] = "bad"
    assert client.post("/api/children", json=data).status_code == 403
    client.headers["X-CSRF-Token"] = "csrf-admin"
    client.headers["Origin"] = "https://evil.invalid"
    assert client.post("/api/children", json=data).status_code == 403
    client.headers["Origin"] = "http://testserver"
    for _ in range(10):
        assert (
            client.post(
                "/api/auth/login",
                json={
                    "username": "wrong",
                    "password": "wrong",
                    "captcha_id": "missing",
                    "captcha": "wrong",
                },
            ).status_code
            == 400
        )
    assert (
        client.post(
            "/api/auth/login",
            json={
                "username": "wrong",
                "password": "wrong",
                "captcha_id": "missing",
                "captcha": "wrong",
            },
        ).status_code
        == 429
    )


def test_password_change_invalidates_sessions(context):
    client = context.client
    assert (
        client.post(
            "/api/auth/password",
            json={
                "old_password": "testing-password-123",
                "new_password": "new-long-password",
            },
        ).status_code
        == 200
    )
    assert client.get("/api/auth/me").status_code == 401


def test_arbitrary_file_signing_denied(context):
    result = upload(context)
    mid = result["media_id"]
    fid = result["tasks"][0]["file_id"]
    assert (
        context.client.get(f"/api/media/{mid}/files/{fid + 100}/url").status_code == 404
    )


def test_graphical_captcha_and_secure_cookie(context, monkeypatch):
    from app.config import settings

    result = context.client.get("/api/auth/captcha")
    assert result.status_code == 200
    assert result.json()["image"].startswith("data:image/png;base64,")
    monkeypatch.setattr(settings(), "cookie_secure", True)
    payload = challenge(context)
    response = context.client.post("/api/auth/login", json=payload)
    assert response.status_code == 200
    assert "Secure" in response.headers["set-cookie"]


def test_prefixed_session_is_secure_and_removed_on_logout(context, monkeypatch):
    from fastapi.testclient import TestClient
    from app.config import settings
    from app.main import app

    monkeypatch.setattr(settings(), "app_base_path", "/yearly")
    monkeypatch.setattr(settings(), "allowed_origin", "https://testserver")
    monkeypatch.setattr(settings(), "cookie_secure", True)
    monkeypatch.setattr(app, "root_path", "/yearly")
    client = TestClient(app, base_url="https://testserver", headers={"Origin": "https://testserver"})
    response = client.post("/yearly/api/auth/login", json=challenge(context))
    assert response.status_code == 200
    assert "Path=/yearly/" in response.headers["set-cookie"]
    assert "Secure" in response.headers["set-cookie"]
    uploads = client.get("/yearly/api/uploads")
    assert uploads.status_code == 200
    assert uploads.headers["X-Yearly-Upload-Protocol"] == "idempotent-v1"
    assert client.get("/api/uploads").status_code == 401
    client.headers["X-CSRF-Token"] = response.json()["csrf_token"]
    logout = client.post("/yearly/api/auth/logout", json={})
    assert logout.status_code == 200
    assert "Path=/yearly/" in logout.headers["set-cookie"]
    assert client.get("/yearly/api/uploads").status_code == 401
