import hashlib
import hmac
import io
import secrets
from datetime import timedelta
from argon2 import PasswordHasher
from argon2.exceptions import VerificationError
from fastapi import Depends, HTTPException, Request
from PIL import Image, ImageDraw, ImageFont
from sqlalchemy import select
from .config import settings
from .db import get_db, now
from .models import User, UserSession, Captcha

passwords = PasswordHasher(time_cost=3, memory_cost=32768, parallelism=2)
DUMMY_HASH = passwords.hash("unused-timing-equalizer")


def digest(value: str):
    return hmac.new(
        settings().session_secret.encode(), value.encode(), hashlib.sha256
    ).hexdigest()


def current_user(request: Request, db=Depends(get_db)):
    token = request.cookies.get("yearly_session", "")
    session = db.get(UserSession, digest(token)) if token else None
    if not session or session.expires_at <= now():
        raise HTTPException(401, "请先登录")
    user = db.get(User, session.user_id)
    if not user or not user.active:
        raise HTTPException(401, "账户已停用")
    if request.method not in ("GET", "HEAD", "OPTIONS"):
        if request.headers.get("origin") != settings().allowed_origin:
            raise HTTPException(403, "请求来源校验失败")
        if not secrets.compare_digest(
            request.headers.get("x-csrf-token", ""), session.csrf_token
        ):
            raise HTTPException(403, "CSRF 校验失败")
    db.info["actor"] = user
    request.state.session = session
    return user


def editor(user=Depends(current_user)):
    if user.role not in ("admin", "member"):
        raise HTTPException(403, "需要家庭编辑权限")
    return user


def admin(user=Depends(current_user)):
    if user.role != "admin":
        raise HTTPException(403, "需要管理员权限")
    return user


def make_captcha(db):
    code = "".join(secrets.choice("23456789ABCDEFGHJKLMNPQRSTUVWXYZ") for _ in range(5))
    key = secrets.token_urlsafe(24)
    db.add(
        Captcha(
            id=key, answer_hash=digest(code), expires_at=now() + timedelta(minutes=5)
        )
    )
    db.commit()
    image = Image.new("RGB", (180, 56), "#f6f2eb")
    draw = ImageDraw.Draw(image)
    font = ImageFont.load_default(size=30)
    for i, char in enumerate(code):
        draw.text(
            (14 + i * 31, 8 + secrets.randbelow(7)), char, fill="#45534a", font=font
        )
    for _ in range(10):
        draw.line(
            (
                secrets.randbelow(180),
                secrets.randbelow(56),
                secrets.randbelow(180),
                secrets.randbelow(56),
            ),
            fill="#bfb9ab",
        )
    output = io.BytesIO()
    image.save(output, "PNG")
    return key, output.getvalue()
