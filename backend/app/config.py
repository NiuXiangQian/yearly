import os
import re
from functools import lru_cache
from pathlib import Path
from typing import Literal
from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict
from sqlalchemy.engine import make_url

PROJECT_ROOT = Path(__file__).resolve().parents[2]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(extra="ignore", hide_input_in_errors=True)
    app_env: Literal["test", "production"] = "test"
    database_url: str
    session_secret: str = ""
    cookie_secure: bool = True
    allowed_origin: str = "https://yearly.example.com"
    app_base_path: str = ""
    oss_endpoint: str = "https://oss-cn-hangzhou.aliyuncs.com"
    oss_region: str = "cn-hangzhou"
    oss_bucket: str = ""
    oss_access_key_id: str = ""
    oss_access_key_secret: str = ""
    oss_custom_domain: str = ""
    oss_internal_endpoint: str = ""
    oss_archive_originals: bool = False
    upload_part_size: int = 16 * 1024 * 1024
    max_file_size: int = 50 * 1024**3
    session_hours: int = 168
    ai_search_enabled: bool = False
    openai_api_key: str = Field(default="", repr=False)
    openai_proxy_url: str = Field(default="", repr=False)
    ai_analysis_model: Literal["gpt-4.1-mini", "gpt-6.1-sol"] = "gpt-6.1-sol"
    ai_monthly_budget_usd: float = Field(default=80, ge=0, le=100)
    face_matching_enabled: bool = False
    face_auto_link_enabled: bool = False
    face_model_directory: str = str(PROJECT_ROOT / ".local" / "face-models")
    face_match_threshold: float = Field(default=0.45, ge=0, le=1)

    @field_validator("app_base_path")
    @classmethod
    def valid_base_path(cls, value):
        value = value.removesuffix("/")
        if value and not re.fullmatch(r"(/[A-Za-z0-9_-]+)+", value):
            raise ValueError("APP_BASE_PATH 必须为 /yearly 形式的路径")
        return value

    @field_validator("database_url")
    @classmethod
    def mysql_only(cls, value):
        url = make_url(value)
        if url.drivername != "mysql+pymysql" or not url.database:
            raise ValueError("DATABASE_URL 必须使用 mysql+pymysql 并指定数据库")
        ca = url.query.get("ssl_ca")
        if ca and not Path(ca).is_absolute():
            url = url.update_query_dict({"ssl_ca": str(PROJECT_ROOT / ca)})
        return url.render_as_string(hide_password=False)


@lru_cache
def settings():
    profile = os.environ.get("APP_ENV", "test")
    if profile not in ("test", "production"):
        raise ValueError("APP_ENV 只支持 test 或 production")
    cfg = Settings(_env_file=PROJECT_ROOT / f".env.{profile}")
    if cfg.app_env != profile:
        raise ValueError("配置文件的 APP_ENV 与所选环境不一致")
    if profile == "test" and not make_url(cfg.database_url).database.endswith("_test"):
        raise ValueError("测试环境数据库名称必须以 _test 结尾")
    if profile == "production" and make_url(cfg.database_url).database.endswith(
        "_test"
    ):
        raise ValueError("正式环境需使用独立的正式数据库")
    return cfg
