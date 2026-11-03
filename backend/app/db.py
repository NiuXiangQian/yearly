from datetime import datetime, timezone
from sqlalchemy import create_engine, BigInteger
from sqlalchemy.dialects.mysql import DATETIME
from sqlalchemy.orm import DeclarativeBase, sessionmaker
from .config import settings


def now():
    return datetime.now(timezone.utc).replace(tzinfo=None)


class Base(DeclarativeBase):
    pass


ID = BigInteger()
DT = DATETIME(fsp=3)
engine = create_engine(
    settings().database_url,
    pool_pre_ping=True,
    hide_parameters=True,
)
SessionLocal = sessionmaker(engine, expire_on_commit=False)


def get_db():
    with SessionLocal() as db:
        yield db
