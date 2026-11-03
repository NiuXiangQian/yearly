import os

os.environ["APP_ENV"] = "test"
import hashlib
from datetime import timedelta
from types import SimpleNamespace
import pytest
import oss2
from sqlalchemy import create_engine, delete, update, inspect
from sqlalchemy.orm import sessionmaker
from fastapi.testclient import TestClient
from app.config import settings

settings.cache_clear()
from app.db import Base, get_db, now
from app.main import app
from app.models import User, UserSession, Child
from app.security import passwords, digest
from app.storage import get_storage


class FakeStorage:
    def __init__(self):
        self.uploads = {}
        self.objects = {}
        self.initiations = 0
        self.completions = 0

    def initiate(self, file):
        self.initiations += 1
        uid = "upload-" + str(self.initiations)
        self.uploads[uid] = {"file": file, "parts": {}}
        return uid

    def sign_part(self, file, uid, number):
        return "https://private.invalid/part"

    def parts(self, file, uid):
        return [
            SimpleNamespace(
                part_number=n, size=len(data), etag=hashlib.md5(data).hexdigest()
            )
            for n, data in sorted(self.uploads[uid]["parts"].items())
        ]

    def complete(self, file, uid, parts):
        assert file.oss_object_key not in self.objects
        self.completions += 1
        self.objects[file.oss_object_key] = b"".join(
            self.uploads[uid]["parts"][p.part_number] for p in parts
        )

    def head(self, file):
        if file.oss_object_key not in self.objects:
            raise oss2.exceptions.NoSuchKey(404, {}, b"", {"Code": "NoSuchKey"})
        content = self.objects[file.oss_object_key]
        crc = oss2.utils.Crc64()
        crc(content)
        return {
            "size": len(content),
            "crc64": str(crc.crc),
            "sha256": hashlib.sha256(content).hexdigest(),
        }

    def download_url(self, file, attachment=False):
        return "https://private.invalid/signed-original"


@pytest.fixture(scope="session")
def mysql_engine():
    cfg = settings()
    engine = create_engine(cfg.database_url, pool_pre_ping=True, hide_parameters=True)
    from sqlalchemy.engine import make_url

    if cfg.app_env != "test" or not make_url(cfg.database_url).database.endswith(
        "_test"
    ):
        raise RuntimeError("自动化测试仅能连接 _test 数据库")
    with engine.connect() as connection:
        if (
            connection.exec_driver_sql("SELECT VERSION()")
            .scalar()
            .lower()
            .find("mariadb")
            >= 0
        ):
            raise RuntimeError("测试要求使用 MySQL 实例")
    missing = set(Base.metadata.tables) - set(inspect(engine).get_table_names())
    if missing:
        raise RuntimeError(
            "测试数据库尚未建表，请先运行 scripts/manage.sh test migrate"
        )
    yield engine
    engine.dispose()


@pytest.fixture
def context(tmp_path, monkeypatch, mysql_engine):
    connection = mysql_engine.connect()
    transaction = connection.begin()
    try:
        # Clear test-visible rows within the outer transaction. Every API commit is a savepoint,
        # and final rollback restores the test environment's existing records.
        connection.execute(update(Child).values(avatar_media_id=None))
        for table in reversed(Base.metadata.sorted_tables):
            connection.execute(delete(table))
        factory = sessionmaker(
            bind=connection,
            expire_on_commit=False,
            join_transaction_mode="create_savepoint",
        )
        with factory() as db:
            for i, role in enumerate(["admin", "member", "viewer"], 1):
                db.add(
                    User(
                        id=i,
                        username=role,
                        password_hash=passwords.hash("testing-password-123"),
                        role=role,
                    )
                )
                db.flush()
                db.add(
                    UserSession(
                        id=digest(role),
                        user_id=i,
                        csrf_token="csrf-" + role,
                        expires_at=now() + timedelta(days=1),
                    )
                )
            db.commit()

        def get_test_db():
            with factory() as db:
                yield db

        monkeypatch.setattr(settings(), "allowed_origin", "http://testserver")
        monkeypatch.setattr(settings(), "cookie_secure", False)
        storage = FakeStorage()
        app.dependency_overrides[get_db] = get_test_db
        app.dependency_overrides[get_storage] = lambda: storage
        import app.backup as backup

        monkeypatch.setattr(backup, "SessionLocal", factory)
        client = TestClient(app)
        client.cookies.set("yearly_session", "admin")
        client.headers.update(
            {"Origin": "http://testserver", "X-CSRF-Token": "csrf-admin"}
        )
        yield SimpleNamespace(
            client=client, db=factory, storage=storage, tmp_path=tmp_path
        )
    finally:
        app.dependency_overrides.clear()
        transaction.rollback()
        connection.close()


def file_payload(
    content=b"unchanged-camera-original", name="camera.jpg", role="original"
):
    crc = oss2.utils.Crc64()
    crc(content)
    return {
        "original_filename": name,
        "mime_type": "image/jpeg",
        "file_size": len(content),
        "sha256": hashlib.sha256(content).hexdigest(),
        "crc64": str(crc.crc),
        "file_role": role,
    }


def upload(
    context,
    children=None,
    content=b"unchanged-camera-original",
    taken="2024-03-31T10:30:00",
    files=None,
    media_type="photo",
):
    client = context.client
    payload = {
        "media_type": media_type,
        "files": files or [file_payload(content)],
        "child_ids": children or [],
        "original_taken_at_local": taken,
        "time_source": "EXIF.DateTimeOriginal",
        "time_confidence": "high",
        "metadata": {"Make": "Apple", "DateTimeOriginal": taken, "latitude": 30.5},
    }
    response = client.post("/api/uploads", json=payload)
    assert response.status_code == 200, response.text
    result = response.json()
    for task in result["tasks"]:
        response = client.post(f"/api/uploads/{task['id']}/sign?number=1", json={})
        assert response.status_code == 200, response.text
        with context.db() as db:
            from app.models import UploadTask

            uid = db.get(UploadTask, task["id"]).oss_upload_id
        context.storage.uploads[uid]["parts"][1] = content
        response = client.post(f"/api/uploads/{task['id']}/complete", json={})
        assert response.status_code == 200, response.text
    return result


def child(context, name="哥哥", birthday="2021-01-31"):
    response = context.client.post(
        "/api/children", json={"name": name, "birthday": birthday}
    )
    assert response.status_code == 200, response.text
    return response.json()
