"""Administrator-reviewed local face matching. Guesses never become training samples."""
import tempfile
from pathlib import Path
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field, model_validator
from sqlalchemy import delete, select, func, or_

from .organization_history import preferences, record_identity, clear_identity_reviews
from .accounts import record_change
from .db import get_db
from .face_engine import FaceEngine, MODEL_VERSION, availability
from .video_faces import detect_video_faces, similarity, VIDEO_FACE_SIMILARITY
from .config import settings
from .models import Child, DisplayPreview, Media, MediaChild, MediaFace, MediaFaceIndex, MediaFile, VideoPreview, MediaInterview
from .security import admin
from .services import set_children, media_data
from .storage import get_storage
from .visibility import visible_row

router = APIRouter(prefix="/api/faces", tags=["人脸匹配"])
AUTO_LINK_MINIMUM_SIMILARITY = 0.7


class FaceAssignment(BaseModel):
    face_id: int = Field(ge=1)
    child_id: int | None = Field(default=None, ge=1)
    ignored: bool = False

    @model_validator(mode="after")
    def valid_assignment(self):
        if self.ignored and self.child_id is not None:
            raise ValueError("忽略的人脸不能同时关联人物")
        return self


class ConfirmFaces(BaseModel):
    assignments: list[FaceAssignment] = Field(max_length=300)

    @model_validator(mode="after")
    def unique_faces(self):
        if len({a.face_id for a in self.assignments}) != len(self.assignments):
            raise ValueError("同一张人脸只能确认一次")
        return self


class AnalyzeFaces(BaseModel):
    refresh: bool = False


def active_media(db, mid, user):
    media = visible_row(db, Media, mid, user)
    if media.status != "active" or media.purpose != "memory":
        raise HTTPException(404, "影像不存在")
    return media


def face_items(db, rows, matching=True, review_automatic=False, round_scores=True):
    excluded = set(preferences(db)["face_excluded_child_ids"])
    references = db.execute(select(MediaFace, Child).join(Child, Child.id == MediaFace.child_id)
        .join(Media, Media.id == MediaFace.media_id)
        .join(MediaFaceIndex, MediaFaceIndex.media_id == MediaFace.media_id)
        .where(Media.status == "active", Media.purpose == "memory",
               MediaFaceIndex.model == MODEL_VERSION, Child.status != "deleted", Child.profile_type != "pet",
               MediaFace.ignored.is_(False), MediaFace.confirmed_by.is_not(None))).all() if rows and matching else []
    items = []
    for face in rows:
        best = {}
        if not face.ignored and (face.child_id is None or (review_automatic and face.auto_match_score is not None)):
            for sample, person in references:
                if sample.media_id == face.media_id and (
                    sample.frame_seconds is None or face.frame_seconds is None or sample.frame_seconds == face.frame_seconds
                ):
                    continue
                similarity = sum(a*b for a, b in zip(face.embedding, sample.embedding, strict=True))
                if similarity < settings().face_match_threshold or similarity <= best.get(person.id, {}).get("similarity", -1):
                    continue
                best[person.id] = dict(child_id=person.id, name=person.name,
                    similarity=similarity,
                    reference_media_id=sample.media_id, reference_face_id=sample.id,
                    reference_thumbnail="data:image/jpeg;base64," + sample.thumbnail)
        # Suppress excluded identities without falling back to a weaker, wrong person.
        excluded_score = max((candidate["similarity"] for cid, candidate in best.items() if cid in excluded), default=-1)
        candidates = sorted((candidate for cid, candidate in best.items()
                             if cid not in excluded and candidate["similarity"] > excluded_score),
                            key=lambda item: item["similarity"], reverse=True)[:3]
        if round_scores:
            candidates = [dict(candidate, similarity=round(candidate["similarity"], 4)) for candidate in candidates]
        items.append(dict(id=face.id, box=face.box, frame_seconds=face.frame_seconds,
            thumbnail="data:image/jpeg;base64," + face.thumbnail, child_id=face.child_id, ignored=face.ignored,
            auto_assigned=face.auto_match_score is not None, auto_match_score=face.auto_match_score,
            candidates=candidates))
    return items, [(sample, person) for sample, person in references if person.id not in excluded]


def result(db, media):
    index = db.get(MediaFaceIndex, media.id)
    rows = db.scalars(select(MediaFace).where(MediaFace.media_id == media.id).order_by(MediaFace.id)).all()
    items, references = face_items(db, rows, index is not None and index.model == MODEL_VERSION)
    return dict(**availability(), analyzed=index is not None, faces=items, refresh_supported=True,
                reference_people=len({person.id for sample, person in references if sample.media_id != media.id}),
                child_ids=list(db.scalars(select(MediaChild.child_id).where(MediaChild.media_id == media.id))))


def unanalysed_photos():
    return select(Media).join(MediaFile, MediaFile.media_id == Media.id).join(DisplayPreview, DisplayPreview.sha256 == MediaFile.sha256).outerjoin(MediaFaceIndex, MediaFaceIndex.media_id == Media.id).where(
        Media.status == "active", Media.purpose == "memory", Media.media_type.in_(["photo", "live_photo"]),
        MediaFile.file_role == "original", MediaFile.upload_status == "complete", DisplayPreview.status == "ready", MediaFaceIndex.media_id.is_(None))


@router.get("/review")
def review_queue(scope: Literal["pending", "all"] = "pending", before: int | None = Query(default=None, ge=1),
                 limit: int = Query(default=24, ge=1, le=48), media_id: int | None = Query(default=None, ge=1), db=Depends(get_db), user=Depends(admin)):
    base = select(MediaFace).join(Media, Media.id == MediaFace.media_id).where(Media.status == "active", Media.purpose == "memory")
    pending = base.where(MediaFace.child_id.is_(None), MediaFace.ignored.is_(False))
    query = pending if scope == "pending" else base
    if media_id is not None:
        query = query.where(MediaFace.media_id == media_id)
    if before is not None:
        query = query.where(MediaFace.id < before)
    rows = list(db.scalars(query.order_by(MediaFace.id.desc()).limit(limit + 1)))
    more = len(rows) > limit
    rows = rows[:limit]
    media = {m.id: m for m in db.scalars(select(Media).where(Media.id.in_({f.media_id for f in rows}))).unique()}
    items, _ = face_items(db, rows)
    todo = select(Media.id).outerjoin(MediaInterview).where(Media.status == "active", Media.purpose == "memory",
        or_(MediaInterview.media_id.is_(None), MediaInterview.status == "draft"))
    return dict(**availability(), items=[dict(**item, media=media_data(media[face.media_id])) for item, face in zip(items, rows, strict=True)],
        auto_link_enabled=settings().face_auto_link_enabled,
        next_cursor=rows[-1].id if more else None,
        pending_faces=db.scalar(select(func.count()).select_from(pending.subquery())),
        unanalysed_photos=db.scalar(select(func.count()).select_from(unanalysed_photos().subquery())),
        pending_memories=db.scalar(select(func.count()).select_from(todo.subquery())))


def auto_link(db, user):
    options = preferences(db)
    if not settings().face_auto_link_enabled or not options["people_enabled"]:
        return dict(linked_faces=0, reset_faces=0, media_count=0)
    rows = list(db.scalars(select(MediaFace).join(Media, Media.id == MediaFace.media_id)
        .join(MediaFaceIndex, MediaFaceIndex.media_id == MediaFace.media_id)
        .where(Media.status == "active", Media.purpose == "memory", MediaFaceIndex.model == MODEL_VERSION,
               or_(MediaFace.child_id.is_(None), MediaFace.auto_match_score.is_not(None)),
               or_(MediaFace.child_id.is_(None), MediaFace.child_id.not_in(options["face_excluded_child_ids"])),
               MediaFace.ignored.is_(False), MediaFace.auto_link_blocked.is_(False))))
    items, _ = face_items(db, rows, review_automatic=True, round_scores=False)
    rules = options["person_rules"]
    changes = {}
    for face, item in zip(rows, items, strict=True):
        candidates = item["candidates"]
        best = candidates[0] if candidates and candidates[0]["similarity"] > AUTO_LINK_MINIMUM_SIMILARITY else None
        if best and len(candidates) > 1 and best["similarity"] == candidates[1]["similarity"]:
            best = None
        if best and rules.get(str(best["child_id"])) == "manual":
            continue
        previous = face.child_id
        face.child_id = best["child_id"] if best else None
        face.auto_match_score = best["similarity"] if best else None
        face.auto_reference_face_id = best["reference_face_id"] if best else None
        # confirmed_by stays empty: automatic links never become reference samples.
        if previous != face.child_id:
            record_identity(db, face.media_id, "face", str(face.id),
                dict(child_id=previous, ignored=False), dict(child_id=face.child_id, ignored=False), automatic=True,
                evidence=dict(similarity=face.auto_match_score, reference_face_id=face.auto_reference_face_id,
                    reference_media_id=best["reference_media_id"] if best else None, frame_seconds=float(face.frame_seconds) if face.frame_seconds is not None else None,
                    model=MODEL_VERSION, reason="参考样本明确匹配" if best else "匹配不再明确，撤回自动关联"))
            changes.setdefault(face.media_id, []).append(dict(face_id=face.id, previous_child_id=previous, child_id=face.child_id,
                similarity=face.auto_match_score, reference_face_id=face.auto_reference_face_id))
    for mid, assigned in changes.items():
        current = set(db.scalars(select(MediaChild.child_id).where(MediaChild.media_id == mid)))
        linked = set(db.scalars(select(MediaFace.child_id).where(MediaFace.media_id == mid, MediaFace.child_id.is_not(None), MediaFace.ignored.is_(False))))
        index = db.get(MediaFaceIndex, mid)
        managed = set(index.managed_child_ids)
        index.managed_child_ids = sorted((managed & linked) | (linked - current))
        set_children(db, mid, (current - managed) | linked, MediaChild)
        record_change(db, db.get(Media, mid), {"faces": {
            "before": [dict(face_id=c["face_id"], child_id=c["previous_child_id"]) for c in assigned], "after": assigned}})
    return dict(linked_faces=sum(c["child_id"] is not None for changeset in changes.values() for c in changeset),
        reset_faces=sum(c["child_id"] is None for changeset in changes.values() for c in changeset), media_count=len(changes))


@router.post("/auto-link")
def auto_link_faces(db=Depends(get_db), user=Depends(admin)):
    summary = auto_link(db, user)
    db.commit()
    return dict(**summary, enabled=settings().face_auto_link_enabled,
                minimum_similarity=AUTO_LINK_MINIMUM_SIMILARITY, minimum_similarity_exclusive=True,
                minimum_margin=0.0, ties_require_review=True)


@router.post("/analyze-next")
def analyze_next(limit: int = Query(default=5, ge=1, le=5), db=Depends(get_db), user=Depends(admin), storage=Depends(get_storage)):
    state = availability()
    if not state["enabled"] or not state["ready"]:
        raise HTTPException(503, state["message"])
    rows = list(db.scalars(unanalysed_photos().order_by(Media.id.desc()).limit(limit)))
    processed, failed = [], []
    for media in rows:
        try:
            analyze(db, storage, media)
            processed.append(media.id)
        except HTTPException as exc:
            db.rollback()
            failed.append(dict(media_id=media.id, message=exc.detail))
    auto_link(db, user)
    db.commit()
    return dict(processed=processed, failed=failed,
        remaining=db.scalar(select(func.count()).select_from(unanalysed_photos().subquery())))


def analyze(db, storage, media, refresh=False):
    file = db.scalar(select(MediaFile).where(MediaFile.media_id == media.id, MediaFile.file_role == "original", MediaFile.upload_status == "complete"))
    if file is None:
        raise HTTPException(409, "请等待影像上传完成")
    index = db.get(MediaFaceIndex, media.id)
    if index is not None:
        if index.source_sha256 != file.sha256 or index.model != MODEL_VERSION:
            raise HTTPException(409, "影像或模型已变化，请先清除旧人脸样本后重新分析")
        if not refresh:
            return  # Persisted detections, including zero faces, are the analysis cache.
    preview = db.get(VideoPreview if media.media_type == "video" else DisplayPreview, file.sha256)
    if preview is None or preview.status != "ready":
        raise HTTPException(409, "请等待压缩预览生成完成后重试")
    detector = FaceEngine()
    found = []
    if media.media_type == "video":
        with tempfile.TemporaryDirectory(prefix="yearly-faces-") as directory:
            video = Path(directory) / "preview.mp4"
            storage.bucket.get_object_to_file(preview.object_key, str(video))
            found = detect_video_faces(video, directory, detector, media.duration_ms)
    else:
        found = detector.detect(storage.bucket.get_object(preview.image_key).read())
    for face in found:
        face.pop("_quality", None)
    if index is None:
        db.add(MediaFaceIndex(media_id=media.id, model=MODEL_VERSION, source_sha256=file.sha256))
        db.flush()
    # Refresh is additive: keep row IDs, human choices and automatic-match evidence valid.
    available = list(db.scalars(select(MediaFace).where(MediaFace.media_id == media.id).order_by(MediaFace.id)
        .with_for_update().execution_options(populate_existing=True))) if index else []
    for face in found:
        matches = sorted(((similarity(face["embedding"], row.embedding), row) for row in available), key=lambda item: item[0], reverse=True)
        # A new crop never inherits or overwrites a human-confirmed identity.
        if matches and matches[0][0] >= VIDEO_FACE_SIMILARITY:
            row = matches[0][1]
            available.remove(row)
            if (row.confirmed_by is None and row.child_id is None and not row.ignored and not row.auto_link_blocked
                    and row.auto_match_score is None and row.auto_reference_face_id is None):
                for key, value in face.items():
                    setattr(row, key, value)
        else:
            db.add(MediaFace(media_id=media.id, **face))
    db.commit()


@router.get("/media/{mid}")
def get_faces(mid: int, db=Depends(get_db), user=Depends(admin)):
    return result(db, active_media(db, mid, user))


@router.post("/media/{mid}/analyze")
def analyze_faces(mid: int, data: AnalyzeFaces | None = None, db=Depends(get_db), user=Depends(admin), storage=Depends(get_storage)):
    media = active_media(db, mid, user)
    state = availability()
    if not state["enabled"] or not state["ready"]:
        raise HTTPException(503, state["message"])
    analyze(db, storage, media, refresh=data.refresh if data else False)
    auto_link(db, user)
    db.commit()
    return result(db, media)


@router.put("/media/{mid}/confirm")
def confirm_faces(mid: int, data: ConfirmFaces, db=Depends(get_db), user=Depends(admin)):
    media = active_media(db, mid, user)
    summary = apply_assignments(db, media, data, user)
    db.commit()
    return dict(**result(db, media), auto_linked=summary["linked_faces"], auto_reset=summary.get("reset_faces", 0))


def apply_assignments(db, media, data, user):
    mid = media.id
    index = db.get(MediaFaceIndex, mid)
    if index is None:
        raise HTTPException(409, "请先分析影像中的人脸")
    rows = {f.id: f for f in db.scalars(select(MediaFace).where(MediaFace.media_id == mid))}
    if any(a.face_id not in rows for a in data.assignments):
        raise HTTPException(422, "人脸不属于当前影像")
    ids = {a.child_id for a in data.assignments if a.child_id is not None}
    valid = set(db.scalars(select(Child.id).where(Child.id.in_(ids), Child.status != "deleted", Child.profile_type != "pet")))
    if valid != ids:
        raise HTTPException(422, "请选择有效的人物档案，宠物不支持人脸匹配")
    changes = []
    for assignment in data.assignments:
        face = rows[assignment.face_id]
        before = dict(child_id=face.child_id, ignored=face.ignored)
        if face.auto_match_score is not None:
            before["automatic"] = True
        face.child_id, face.ignored = assignment.child_id, assignment.ignored
        face.confirmed_by = user.id if face.child_id is not None or face.ignored else None
        face.auto_match_score = face.auto_reference_face_id = None
        # Released clients submit unchanged, unassigned faces alongside an edited one.
        # Only withdrawing an existing identity blocks later automatic matching.
        face.auto_link_blocked = (face.auto_link_blocked or before["child_id"] is not None) if face.child_id is None else False
        after = dict(child_id=face.child_id, ignored=face.ignored)
        record_identity(db, mid, "face", str(face.id), {k: v for k, v in before.items() if k != "automatic"}, after,
            automatic=False, evidence=dict(reason="管理员确认", frame_seconds=float(face.frame_seconds) if face.frame_seconds is not None else None))
        if before != after:
            changes.append(dict(face_id=face.id, before=before, after=after))
    current = set(db.scalars(select(MediaChild.child_id).where(MediaChild.media_id == mid)))
    confirmed = {f.child_id for f in rows.values() if f.child_id is not None and not f.ignored}
    managed = set(index.managed_child_ids)
    # Preserve unrelated, manually associated people/pets when correcting a face.
    desired = (current - managed) | confirmed
    index.managed_child_ids = sorted((managed & confirmed) | (confirmed - current))
    set_children(db, mid, desired, MediaChild)
    record_change(db, media, {"faces": {
        "before": [dict(face_id=c["face_id"], **c["before"]) for c in changes],
        "after": [dict(face_id=c["face_id"], **c["after"]) for c in changes],
    }} if changes else {})
    return auto_link(db, user)


@router.delete("/media/{mid}")
def clear_faces(mid: int, db=Depends(get_db), user=Depends(admin)):
    media = active_media(db, mid, user)
    index = db.get(MediaFaceIndex, mid)
    if index:
        current = set(db.scalars(select(MediaChild.child_id).where(MediaChild.media_id == mid)))
        set_children(db, mid, current - set(index.managed_child_ids), MediaChild)
        clear_identity_reviews(db, mid, "face")
        db.execute(delete(MediaFace).where(MediaFace.media_id == mid))
        db.delete(index)
        auto_link(db, user)
        record_change(db, media, {"faces": {"before": "已分析", "after": "已清除"}})
        db.commit()
    return result(db, media)
