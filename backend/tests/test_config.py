import pytest
from app import config


@pytest.fixture(autouse=True)
def environment_files(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "PROJECT_ROOT", tmp_path)
    for key in [
        "APP_ENV",
        "DATABASE_URL",
        "COOKIE_SECURE",
        "ALLOWED_ORIGIN",
        "SESSION_SECRET",
    ]:
        monkeypatch.delenv(key, raising=False)
    (tmp_path / ".env.test").write_text(
        "APP_ENV=test\nDATABASE_URL=mysql+pymysql://test_user:test_password@localhost/yearly_test\nCOOKIE_SECURE=false\nALLOWED_ORIGIN=http://127.0.0.1:5173\nSESSION_SECRET="
        + ("t" * 40)
        + "\n"
    )
    (tmp_path / ".env.production").write_text(
        "APP_ENV=production\nDATABASE_URL=mysql+pymysql://production_user:production_password@localhost/yearly\nCOOKIE_SECURE=true\nALLOWED_ORIGIN=https://yearly.example.com\nSESSION_SECRET="
        + ("p" * 40)
        + "\n"
    )
    config.settings.cache_clear()
    yield
    config.settings.cache_clear()


def test_default_local_profile_and_production_are_separate(monkeypatch):
    local = config.settings()
    assert local.app_env == "test"
    assert "yearly_test" in local.database_url
    assert local.cookie_secure is False
    monkeypatch.setenv("APP_ENV", "production")
    config.settings.cache_clear()
    production = config.settings()
    assert production.app_env == "production"
    assert production.database_url != local.database_url
    assert production.session_secret != local.session_secret
    assert production.cookie_secure is True


def test_mysql_required(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "sqlite://")
    with pytest.raises(ValueError, match="mysql.pymysql"):
        config.settings()


def test_test_profile_rejects_production_database(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "mysql+pymysql://user:password@localhost/yearly")
    with pytest.raises(ValueError, match="_test"):
        config.settings()


def test_production_profile_rejects_test_database(monkeypatch):
    monkeypatch.setenv("APP_ENV", "production")
    monkeypatch.setenv(
        "DATABASE_URL", "mysql+pymysql://user:password@localhost/yearly_test"
    )
    with pytest.raises(ValueError, match="独立"):
        config.settings()


def test_invalid_profile_is_rejected(monkeypatch):
    monkeypatch.setenv("APP_ENV", "development")
    with pytest.raises(ValueError, match="APP_ENV"):
        config.settings()
