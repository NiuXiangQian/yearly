"""Administrator-reviewed local face matching. Guesses never become training samples."""
import tempfile
import subprocess
from collections import defaultdict
from io import BytesIO
from itertools import islice
from pathlib import Path
from typing import Literal

from PIL import Image, ImageOps
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field, model_validator
from sqlalchemy import String, cast, delete, func, or_, select, update

from .organization_history import preferences, record_identity, clear_identity_reviews
from .accounts import record_change
from .db import get_db
from .face_engine import FaceEngine, MODEL_VERSION, availability
from .face_quality import assess_crop, QUALITY_VERSION
from .video_faces import detect_video_faces, overlap, similarity, VIDEO_FACE_SIMILARITY
from .config import settings
from .models import Child, DisplayPreview, Media, MediaChild, MediaFace, MediaFaceIndex, MediaFile, VideoPreview, MediaInterview, OrganizationReview
from .security import admin
from .services import set_children, media_data
from .storage import get_storage
from .visibility import visible_row

router = APIRouter(prefix="/api/faces", tags=["人脸匹配"])
FACE_MATCH_MINIMUM_SIMILARITY = 0.60
AUTO_LINK_MINIMUM_MARGIN = 0.08
FACE_COMPETITION_MINIMUM_SIMILARITY = FACE_MATCH_MINIMUM_SIMILARITY - AUTO_LINK_MINIMUM_MARGIN
VIDEO_CONFIRMATION_MINIMUM = 0.55
VIDEO_REFERENCE_MINIMUM = 0.65
REFERENCE_BATCH_SIZE = 150
NO_MATCH_CHANGES = dict(linked_faces=0, reset_faces=0, media_count=0)


class FaceAssignment(BaseModel):
    face_id: int = Field(ge=1)
    child_id: int | None = Field(default=None, ge=1)
    ignored: bool = False
    rejected_child_id: int | None = Field(default=None, ge=1)

    @model_validator(mode="after")
    def valid_assignment(self):
        if self.rejected_child_id is not None and (self.child_id is not None or self.ignored):
            raise ValueError("排除候选时请保留人脸待确认")
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
    detailed_photo: bool = False


class ConfirmFaceGroup(BaseModel):
    face_ids: list[int] = Field(min_length=1, max_length=24)
    child_id: int = Field(ge=1)

    @model_validator(mode="after")
    def unique_faces(self):
        if len(set(self.face_ids)) != len(self.face_ids) or min(self.face_ids) < 1:
            raise ValueError("请选择不同的有效人脸")
        return self


def track_similarity(first, second):
    first_vectors = [first.embedding, *(first.alternate_embeddings or [])]
    second_vectors = [second.embedding, *(second.alternate_embeddings or [])]
    return max(similarity(a, b) for a in first_vectors for b in second_vectors)


def capture_day(media):
    if media.taken_at_local and (media.time_confidence == "high" or media.time_source == "user"):
        return media.taken_at_local.date()
    return None


def active_media(db, mid, user):
    media = visible_row(db, Media, mid, user)
    if media.status != "active" or media.purpose != "memory":
        raise HTTPException(404, "影像不存在")
    return media


def reviewable_face(face):
    # Keep past decisions visible. Only a definite failure hides an unconfirmed crop.
    return (face.child_id is not None or face.confirmed_by is not None
            or assess_crop(face.thumbnail, face.box)[0] is not False)


def face_items(db, rows, matching=True, review_automatic=False, round_scores=True):
    rows = list(rows)
    excluded = set(preferences(db)["face_excluded_child_ids"])
    references = db.execute(select(MediaFace, Child, Media, MediaFaceIndex.source_sha256).join(Child, Child.id == MediaFace.child_id)
        .join(Media, Media.id == MediaFace.media_id)
        .join(MediaFaceIndex, MediaFaceIndex.media_id == MediaFace.media_id)
        .where(Media.status == "active", Media.purpose == "memory",
               MediaFaceIndex.model == MODEL_VERSION, Child.status != "deleted", Child.profile_type != "pet",
               MediaFace.ignored.is_(False), MediaFace.confirmed_by.is_not(None))).all() if rows and matching else []
    references = [row for row in references if assess_crop(row[0].thumbnail, row[0].box)[0] is True]
    media_rows = {media.id: media for media in db.scalars(select(Media).where(Media.id.in_({row.media_id for row in rows})))} if rows and matching else {}
    items = []
    for face in rows:
        matches = defaultdict(list)
        if (references and (not face.ignored or review_automatic) and assess_crop(face.thumbnail, face.box)[0] is True
                and (face.child_id is None or (review_automatic and face.auto_match_score is not None))):
            taken = capture_day(media_rows[face.media_id])
            for sample, person, source, source_hash in references:
                if person.id in (face.rejected_child_ids or []):
                    continue
                if sample.media_id == face.media_id and (
                    sample.frame_seconds is None or face.frame_seconds is None or sample.frame_seconds == face.frame_seconds
                ):
                    continue
                score = track_similarity(face, sample)
                # A score just below the candidate cutoff can still make an automatic decision ambiguous.
                if score < FACE_COMPETITION_MINIMUM_SIMILARITY:
                    continue
                source_day = capture_day(source)
                nearby = bool(person.birthday and person.profile_type == "child" and taken and source_day
                              and abs((taken - source_day).days) <= 90)
                matches[person.id].append((score, nearby, source_day, source_hash, sample, person))
        best = {}
        for person_id, samples in matches.items():
            score, _, _, _, sample, person = max(samples, key=lambda entry: (
                entry[0] >= FACE_MATCH_MINIMUM_SIMILARITY, entry[0] + .025 * entry[1], entry[0], -entry[4].id,
            ))
            best[person_id] = dict(child_id=person.id, name=person.name, similarity=score,
                reference_media_id=sample.media_id, reference_face_id=sample.id,
                reference_thumbnail="data:image/jpeg;base64," + sample.thumbnail)
            if face.frame_seconds is not None:
                local = [entry for entry in samples if entry[4].media_id == face.media_id
                         and entry[0] >= VIDEO_CONFIRMATION_MINIMUM]
                if local:
                    local_score, _, _, _, local_sample, _ = max(local, key=lambda entry: entry[0])
                    best[person_id]["_local"] = (local_sample.id, local_score)
                    if review_automatic:
                        best[person_id]["_video_support"] = video_reference_support(samples, face.media_id)
        suppressed = {cid for cid, candidate in best.items() if cid in excluded and "_local" not in candidate}
        excluded_score = max((best[cid]["similarity"] for cid in suppressed), default=-1)
        candidates = sorted((candidate for cid, candidate in best.items()
                             if cid not in suppressed and candidate["similarity"] > excluded_score
                             and candidate["similarity"] >= FACE_MATCH_MINIMUM_SIMILARITY),
                            key=lambda item: item["similarity"], reverse=True)[:3]
        public_candidates = [{key: round(value, 4) if key == "similarity" and round_scores else value
                              for key, value in candidate.items() if not key.startswith("_")} for candidate in candidates]
        items.append(dict(id=face.id, box=face.box, frame_seconds=face.frame_seconds,
            thumbnail="data:image/jpeg;base64," + face.thumbnail, child_id=face.child_id, ignored=face.ignored,
            auto_assigned=face.auto_match_score is not None, auto_match_score=face.auto_match_score,
            candidates=public_candidates))
        if review_automatic:
            items[-1]["_auto_candidates"] = candidates
            if candidates:
                items[-1]["_runner_up"] = max((value["similarity"] for cid, value in best.items()
                                               if cid != candidates[0]["child_id"]), default=0)
    return items, [(sample, person) for sample, person, _, _ in references if person.id not in excluded]


def video_reference_support(samples, media_id):
    days, hashes = set(), set()
    for score, _, day, source_hash, sample, _ in sorted(samples, key=lambda entry: -entry[0]):
        if sample.media_id == media_id or score < VIDEO_REFERENCE_MINIMUM or source_hash in hashes:
            continue
        if day is not None and day in days:
            continue
        hashes.add(source_hash)
        if day is not None:
            days.add(day)
    return len(hashes)


def result(db, media):
    index = db.get(MediaFaceIndex, media.id)
    rows = db.scalars(select(MediaFace).where(MediaFace.media_id == media.id).order_by(MediaFace.id)).all()
    items, references = face_items(db, (face for face in rows if reviewable_face(face)),
                                  index is not None and index.model == MODEL_VERSION)
    return dict(**availability(), analyzed=index is not None, faces=items,
                reference_people=len({person.id for sample, person in references if sample.media_id != media.id}),
                child_ids=list(db.scalars(select(MediaChild.child_id).where(MediaChild.media_id == media.id))))


def unanalysed_media():
    return (select(Media).join(MediaFile, MediaFile.media_id == Media.id)
        .outerjoin(DisplayPreview, DisplayPreview.sha256 == MediaFile.sha256)
        .outerjoin(VideoPreview, VideoPreview.sha256 == MediaFile.sha256)
        .outerjoin(MediaFaceIndex, MediaFaceIndex.media_id == Media.id)
        .where(Media.status == "active", Media.purpose == "memory",
            MediaFile.file_role == "original", MediaFile.upload_status == "complete", MediaFaceIndex.media_id.is_(None),
            or_((Media.media_type == "video") & (VideoPreview.status == "ready"),
                Media.media_type.in_(["photo", "live_photo"]) & (DisplayPreview.status == "ready"))))


@router.get("/review")
def review_queue(scope: Literal["pending", "all"] = "pending", before: int | None = Query(default=None, ge=1),
                 limit: int = Query(default=24, ge=1, le=48), media_id: int | None = Query(default=None, ge=1), db=Depends(get_db), user=Depends(admin)):
    base = select(MediaFace).join(Media, Media.id == MediaFace.media_id).where(Media.status == "active", Media.purpose == "memory")
    pending = base.where(MediaFace.child_id.is_(None), MediaFace.ignored.is_(False))
    columns = (MediaFace.id, MediaFace.media_id, MediaFace.child_id,
               MediaFace.confirmed_by, MediaFace.thumbnail, MediaFace.box)
    pending_total, page_ids = 0, []
    # Load crops for the quality check without fetching every face's embeddings or media.
    pending_keys = pending.with_only_columns(*columns).order_by(MediaFace.id.desc())
    with db.execute(pending_keys.execution_options(yield_per=128)) as keys:
        for face in keys:
            if not reviewable_face(face):
                continue
            pending_total += 1
            if (scope == "pending" and len(page_ids) <= limit
                    and (before is None or face.id < before) and (media_id is None or face.media_id == media_id)):
                page_ids.append(face.id)
    if scope == "all":
        query = base.with_only_columns(*columns).order_by(MediaFace.id.desc())
        if media_id is not None:
            query = query.where(MediaFace.media_id == media_id)
        if before is not None:
            query = query.where(MediaFace.id < before)
        while len(page_ids) <= limit:
            keys = db.execute(query.limit(128)).all()
            remaining = limit + 1 - len(page_ids)
            page_ids.extend(islice((face.id for face in keys if reviewable_face(face)), remaining))
            if len(keys) < 128:
                break
            query = query.where(MediaFace.id < keys[-1].id)
    more = len(page_ids) > limit
    rows = list(db.scalars(select(MediaFace).where(MediaFace.id.in_(page_ids[:limit])).order_by(MediaFace.id.desc())))
    media = {m.id: m for m in db.scalars(select(Media).where(Media.id.in_({f.media_id for f in rows}))).unique()}
    items, _ = face_items(db, rows)
    if scope == "pending" and media_id is None:
        # Review groups start from a shared candidate and a strong anchor. One face per media.
        anchors = []
        for face, item in zip(rows, items, strict=True):
            candidates = item["candidates"]
            if assess_crop(face.thumbnail, face.box)[0] is not True:
                continue
            child_id = candidates[0]["child_id"] if candidates and candidates[0]["similarity"] >= .65 else None
            group_threshold = .78 if child_id is not None else .88
            for anchor, candidate, media_ids in anchors:
                if (candidate == child_id and face.media_id not in media_ids and len(media_ids) < 24
                        and similarity(face.embedding, anchor.embedding) >= group_threshold):
                    item["review_group_id"] = anchor.id
                    media_ids.add(face.media_id)
                    break
            else:
                anchors.append((face, child_id, {face.media_id}))
                item["review_group_id"] = face.id
    todo = select(Media.id).outerjoin(MediaInterview).where(Media.status == "active", Media.purpose == "memory",
        or_(MediaInterview.media_id.is_(None), MediaInterview.status == "draft"))
    return dict(**availability(), items=[dict(**item, media=media_data(media[face.media_id])) for item, face in zip(items, rows, strict=True)],
        auto_link_enabled=settings().face_auto_link_enabled,
        next_cursor=rows[-1].id if more else None,
        pending_faces=pending_total,
        unanalysed_media=db.scalar(select(func.count()).select_from(unanalysed_media().subquery())),
        pending_memories=db.scalar(select(func.count()).select_from(todo.subquery())))


def ignore_low_quality_faces(db, user, media_ids=None):
    """Discard only untreated crops; preserve all identities and media bindings."""
    query = (select(MediaFace).join(Media, Media.id == MediaFace.media_id)
        .where(Media.status == "active", Media.purpose == "memory",
               MediaFace.child_id.is_(None), MediaFace.confirmed_by.is_(None),
               MediaFace.ignored.is_(False), MediaFace.auto_link_blocked.is_(False)))
    if media_ids is not None:
        query = query.where(MediaFace.media_id.in_(media_ids))
    rows = list(db.scalars(query.with_for_update().execution_options(populate_existing=True)))
    changed = {}
    for face in rows:
        eligible, reason = assess_crop(face.thumbnail, face.box)
        if eligible is not False:
            continue
        face.ignored = True
        face.auto_match_score = face.auto_reference_face_id = None
        record_identity(db, face.media_id, "face", str(face.id),
            dict(child_id=None, ignored=False), dict(child_id=None, ignored=True), automatic=True,
            evidence=dict(reason="图像质量不合格，自动忽略", quality_reason=reason, quality_version=QUALITY_VERSION))
        changed.setdefault(face.media_id, []).append(face.id)
    for mid, ids in changed.items():
        record_change(db, db.get(Media, mid), {"faces": {
            "before": [dict(face_id=fid, child_id=None, ignored=False) for fid in ids],
            "after": [dict(face_id=fid, child_id=None, ignored=True) for fid in ids]}})
    return sum(len(ids) for ids in changed.values())


def matchable_face():
    # Reconsider legacy rows suppressed only because the album already contained this person.
    duplicate = select(OrganizationReview.id).where(
        OrganizationReview.media_id == MediaFace.media_id, OrganizationReview.kind == "face",
        OrganizationReview.target_id == cast(MediaFace.id, String), OrganizationReview.status == "automatic",
        OrganizationReview.automatic.is_(True),
        func.json_contains_path(OrganizationReview.evidence, "one", "$.already_bound_child_ids") == 1,
    ).exists()
    return or_(MediaFace.ignored.is_(False), MediaFace.confirmed_by.is_(None) & duplicate)


def auto_link(db, user, media_ids=None, *, pending_only=False):
    options = preferences(db)
    if not settings().face_auto_link_enabled or not options["people_enabled"]:
        return NO_MATCH_CHANGES.copy()
    ignore_low_quality_faces(db, user, media_ids)
    query = (select(MediaFace).join(Media, Media.id == MediaFace.media_id)
        .join(MediaFaceIndex, MediaFaceIndex.media_id == MediaFace.media_id)
        .where(Media.status == "active", Media.purpose == "memory", MediaFaceIndex.model == MODEL_VERSION,
               MediaFace.auto_link_blocked.is_(False)))
    if pending_only:
        query = query.where(MediaFace.child_id.is_(None), MediaFace.ignored.is_(False))
    else:
        query = query.where(or_(MediaFace.child_id.is_(None), MediaFace.auto_match_score.is_not(None)), matchable_face())
    if media_ids is not None:
        query = query.where(MediaFace.media_id.in_(media_ids))
    rows = list(db.scalars(query.order_by(MediaFace.id).with_for_update().execution_options(populate_existing=True)))
    items, _ = face_items(db, rows, review_automatic=True, round_scores=False)
    rules = options["person_rules"]
    claims = defaultdict(set)
    if rows:
        assigned = db.execute(select(MediaFace.id, MediaFace.media_id, MediaFace.frame_seconds, MediaFace.child_id)
            .where(MediaFace.media_id.in_({row.media_id for row in rows}), MediaFace.child_id.is_not(None),
                   MediaFace.ignored.is_(False)))
        for face_id, media_id, seconds, child_id in assigned:
            claims[media_id, seconds, child_id].add(face_id)
    proposed = {}
    for face, item in zip(rows, items, strict=True):
        candidates = item["_auto_candidates"]
        best = candidates[0] if candidates else None
        if not best or best["similarity"] - item["_runner_up"] < AUTO_LINK_MINIMUM_MARGIN:
            continue
        if rules.get(str(best["child_id"])) == "manual":
            continue
        local = best.get("_local")
        if local and best["child_id"] in options["face_excluded_child_ids"]:
            if local[1] < FACE_MATCH_MINIMUM_SIMILARITY and best.get("_video_support", 0) < 2:
                continue
            best = dict(best, reference_face_id=local[0], reference_media_id=face.media_id)
        proposed[face.id] = best
        claims[face.media_id, face.frame_seconds, best["child_id"]].add(face.id)
    changes = {}
    for face in rows:
        if assess_crop(face.thumbnail, face.box)[0] is not True:
            continue  # Keep existing assignments; unusable crops cannot drive new decisions.
        previous_reference = db.get(MediaFace, face.auto_reference_face_id) if face.auto_reference_face_id else None
        if face.child_id in options["face_excluded_child_ids"] and (
                previous_reference is None or previous_reference.media_id != face.media_id):
            continue  # Preserve links predating the exclusion; new scoped links always cite a local reference.
        if previous_reference is not None and assess_crop(previous_reference.thumbnail, previous_reference.box)[0] is not True:
            continue  # A quality-policy change must not silently undo historical bindings.
        best = proposed.get(face.id)
        if best and len(claims[face.media_id, face.frame_seconds, best["child_id"]]) > 1:
            best = None
        if best is None and face.child_id is not None and face.auto_reference_face_id is not None:
            reference = db.get(MediaFace, face.auto_reference_face_id)
            if reference and reference.child_id == face.child_id and reference.confirmed_by is not None and not reference.ignored:
                source = db.get(Media, reference.media_id)
                if source and source.status == "active" and source.purpose == "memory":
                    continue
        if face.ignored and best is None:
            continue
        previous, previously_ignored = face.child_id, face.ignored
        face.ignored = False
        face.child_id = best["child_id"] if best else None
        face.auto_match_score = best["similarity"] if best else None
        face.auto_reference_face_id = best["reference_face_id"] if best else None
        # confirmed_by stays empty: automatic links never become reference samples.
        if previous != face.child_id:
            record_identity(db, face.media_id, "face", str(face.id),
                dict(child_id=previous, ignored=previously_ignored), dict(child_id=face.child_id, ignored=False), automatic=True,
                evidence=dict(similarity=face.auto_match_score, reference_face_id=face.auto_reference_face_id,
                    reference_media_id=best["reference_media_id"] if best else None,
                    local_reference_similarity=best["_local"][1] if best and best.get("_local") else None, frame_seconds=float(face.frame_seconds) if face.frame_seconds is not None else None,
                    model=MODEL_VERSION, reason="参考样本明确匹配" if best else "匹配不再明确，撤回自动关联"))
            changes.setdefault(face.media_id, []).append(dict(face_id=face.id, previous_child_id=previous, child_id=face.child_id,
                similarity=face.auto_match_score, reference_face_id=face.auto_reference_face_id))
    for mid, assigned in changes.items():
        sync_face_people(db, db.get(MediaFaceIndex, mid))
        record_change(db, db.get(Media, mid), {"faces": {
            "before": [dict(face_id=c["face_id"], child_id=c["previous_child_id"]) for c in assigned], "after": assigned}})
    return dict(linked_faces=sum(c["child_id"] is not None for changeset in changes.values() for c in changeset),
        reset_faces=sum(c["child_id"] is None for changeset in changes.values() for c in changeset), media_count=len(changes))


def sync_face_people(db, index):
    mid = index.media_id
    current = set(db.scalars(select(MediaChild.child_id).where(MediaChild.media_id == mid)))
    linked = set(db.scalars(select(MediaFace.child_id).join(Child, Child.id == MediaFace.child_id)
        .where(MediaFace.media_id == mid, MediaFace.ignored.is_(False), Child.status != "deleted",
               Child.profile_type != "pet")))
    managed = set(index.managed_child_ids)
    index.managed_child_ids = sorted((managed & linked) | (linked - current))
    desired = (current - managed) | linked
    if desired != current:
        set_children(db, mid, desired, MediaChild)


def queue_reference_dependents(db, reference_ids):
    targets = select(MediaFace.media_id).where(MediaFace.auto_reference_face_id.in_(reference_ids))
    db.execute(update(MediaFaceIndex).where(MediaFaceIndex.media_id.in_(targets)).values(match_pending=True))


def process_face_work(db, user):
    if not settings().face_auto_link_enabled or not preferences(db)["people_enabled"]:
        return False
    # Lock one durable work item. Photos and video share the same retryable worker.
    pending = db.scalar(select(MediaFaceIndex).join(Media)
        .where(Media.status == "active", Media.purpose == "memory", MediaFaceIndex.match_pending.is_(True))
        .order_by(MediaFaceIndex.media_id).limit(1).with_for_update())
    if pending:
        auto_link(db, user, {pending.media_id})
        pending.match_pending = False
        db.commit()
        return True
    source = db.scalar(select(MediaFaceIndex).join(Media)
        .where(Media.status == "active", Media.purpose == "memory", MediaFaceIndex.reference_cursor.is_not(None))
        .order_by(MediaFaceIndex.media_id).limit(1).with_for_update())
    if source is None:
        return False
    samples = list(db.scalars(select(MediaFace).where(MediaFace.media_id == source.media_id,
        MediaFace.confirmed_by.is_not(None), MediaFace.child_id.is_not(None), MediaFace.ignored.is_(False))))
    samples = [sample for sample in samples if assess_crop(sample.thumbnail, sample.box)[0] is True]
    targets = list(db.scalars(select(MediaFace).join(Media, Media.id == MediaFace.media_id)
        .join(MediaFaceIndex, MediaFaceIndex.media_id == MediaFace.media_id)
        .where(Media.status == "active", Media.purpose == "memory", MediaFaceIndex.model == MODEL_VERSION,
               MediaFace.id > source.reference_cursor, matchable_face(), MediaFace.auto_link_blocked.is_(False),
               MediaFace.confirmed_by.is_(None)).order_by(MediaFace.id).limit(REFERENCE_BATCH_SIZE)))
    affected = {face.media_id for face in targets if samples and assess_crop(face.thumbnail, face.box)[0] is True
                and any(track_similarity(face, sample) >= FACE_COMPETITION_MINIMUM_SIMILARITY for sample in samples)}
    if affected:
        db.execute(update(MediaFaceIndex).where(MediaFaceIndex.media_id.in_(affected)).values(match_pending=True))
    source.reference_cursor = targets[-1].id if samples and len(targets) == REFERENCE_BATCH_SIZE else None
    db.commit()
    return True


@router.post("/auto-link")
def auto_link_faces(db=Depends(get_db), user=Depends(admin)):
    summary = auto_link(db, user)
    db.commit()
    return dict(**summary, enabled=settings().face_auto_link_enabled,
                minimum_similarity=FACE_MATCH_MINIMUM_SIMILARITY, minimum_similarity_exclusive=False,
                minimum_margin=AUTO_LINK_MINIMUM_MARGIN, minimum_independent_references=1, ties_require_review=True)


@router.post("/analyze-next")
def analyze_next(limit: int = Query(default=5, ge=1, le=5), db=Depends(get_db), user=Depends(admin), storage=Depends(get_storage)):
    state = availability()
    if not state["enabled"] or not state["ready"]:
        raise HTTPException(503, state["message"])
    rows = list(db.scalars(unanalysed_media().order_by(Media.id.desc()).limit(limit)))
    processed, failed = [], []
    for media in rows:
        if media.media_type == "video" and (processed or failed):
            break
        try:
            analyze(db, storage, media)
            processed.append(media.id)
        except HTTPException as exc:
            db.rollback()
            failed.append(dict(media_id=media.id, message=exc.detail))
        if media.media_type == "video":
            break
    return dict(processed=processed, failed=failed,
        remaining=db.scalar(select(func.count()).select_from(unanalysed_media().subquery())))


def photo_detections(raw, detector, detailed):
    found = detector.detect(raw)
    if not detailed:
        return found
    with Image.open(BytesIO(raw)) as source:
        image = ImageOps.exif_transpose(source).convert("RGB")
    width, height = image.size
    if max(width, height) <= 1280:
        return found
    # Four overlapping tiles preserve small faces and leave room near tile boundaries.
    tile_width, tile_height = round(width * .65), round(height * .65)
    for left in (0, width - tile_width):
        for top in (0, height - tile_height):
            image_data = BytesIO()
            image.crop((left, top, left + tile_width, top + tile_height)).save(image_data, "JPEG", quality=93)
            for face in detector.detect(image_data.getvalue()):
                x, y, w, h = face["box"]
                face["box"] = [(left + x * tile_width) / width, (top + y * tile_height) / height,
                               w * tile_width / width, h * tile_height / height]
                if all(overlap(face["box"], existing["box"]) < .4 for existing in found):
                    found.append(face)
    return found


def analyze(db, storage, media, refresh=False, detailed_photo=False):
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
            try:
                found = detect_video_faces(video, directory, detector, media.duration_ms)
            except (subprocess.SubprocessError, ValueError) as exc:
                raise HTTPException(422, "无法读取视频画面，请稍后重新查找") from exc
    else:
        found = photo_detections(storage.bucket.get_object(preview.image_key).read(), detector, detailed_photo)
    for face in found:
        face.pop("_quality", None)
        face.pop("_usable", None)
    state = db.execute(select(Media.status, Media.purpose).where(Media.id == media.id).with_for_update()).one_or_none()
    if state != ("active", "memory"):
        raise HTTPException(404, "影像不存在")
    index = db.scalar(select(MediaFaceIndex).where(MediaFaceIndex.media_id == media.id)
                      .with_for_update().execution_options(populate_existing=True))
    if index is not None and not refresh:
        db.commit()
        return
    if index is None:
        index = MediaFaceIndex(media_id=media.id, model=MODEL_VERSION, source_sha256=file.sha256)
        db.add(index)
        db.flush()
        available = []
    else:
        available = list(db.scalars(select(MediaFace).where(MediaFace.media_id == media.id).order_by(MediaFace.id)
                                    .with_for_update().execution_options(populate_existing=True)))
    for face in found:
        # Use geometry for photo reconciliation so co-occurring similar relatives stay distinct.
        if media.media_type == "video":
            matches = [(similarity(face["embedding"], row.embedding), row) for row in available]
            threshold = VIDEO_FACE_SIMILARITY
        else:
            matches = [(overlap(face["box"], row.box), row) for row in available]
            threshold = .4
        score, row = max(matches, key=lambda item: item[0], default=(-1, None))
        if score >= threshold:
            available.remove(row)
            if (row.confirmed_by is None and row.child_id is None and not row.ignored and not row.auto_link_blocked
                    and row.auto_match_score is None and row.auto_reference_face_id is None):
                for key, value in face.items():
                    setattr(row, key, value)
        else:
            db.add(MediaFace(media_id=media.id, **face))
    index.match_pending = True
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
    analyze(db, storage, media, refresh=bool(data and (data.refresh or data.detailed_photo)),
            detailed_photo=bool(data and data.detailed_photo))
    return result(db, media)


@router.put("/media/{mid}/confirm")
def confirm_faces(mid: int, data: ConfirmFaces, db=Depends(get_db), user=Depends(admin)):
    media = active_media(db, mid, user)
    summary = apply_assignments(db, media, data, user)
    db.commit()
    return dict(**result(db, media), matching_queued=summary["matching_queued"])


def apply_assignments(db, media, data, user):
    mid = media.id
    db.execute(select(Media.id).where(Media.id == mid).with_for_update()).scalar_one()
    index = db.scalar(select(MediaFaceIndex).where(MediaFaceIndex.media_id == mid)
                      .with_for_update().execution_options(populate_existing=True))
    if index is None:
        raise HTTPException(409, "请先分析影像中的人脸")
    rows = {f.id: f for f in db.scalars(select(MediaFace).where(MediaFace.media_id == mid)
            .with_for_update().execution_options(populate_existing=True))}
    if any(a.face_id not in rows for a in data.assignments):
        raise HTTPException(422, "人脸不属于当前影像")
    ids = {cid for a in data.assignments for cid in (a.child_id, a.rejected_child_id) if cid is not None}
    valid = set(db.scalars(select(Child.id).where(Child.id.in_(ids), Child.status != "deleted", Child.profile_type != "pet")))
    if valid != ids:
        raise HTTPException(422, "请选择有效的人物档案，宠物不支持人脸匹配")
    changes = []
    changed_references = []
    for assignment in data.assignments:
        face = rows[assignment.face_id]
        if (assignment.child_id is not None and (assignment.child_id != face.child_id or face.confirmed_by is None)
                and assess_crop(face.thumbnail, face.box)[0] is False):
            raise HTTPException(409, "这张人脸的图像质量不足，请选择更清晰的人脸")
        before = dict(child_id=face.child_id, ignored=face.ignored)
        if assignment.rejected_child_id is not None and face.child_id not in (None, assignment.rejected_child_id):
            raise HTTPException(409, "人物已被修改，请刷新后再排除候选")
        old_reference = face.child_id if face.confirmed_by is not None else None
        rejects = set(face.rejected_child_ids or [])
        if assignment.rejected_child_id is not None:
            rejects.add(assignment.rejected_child_id)
        if assignment.child_id is not None:
            rejects.discard(assignment.child_id)
        face.rejected_child_ids = sorted(rejects) or None
        if face.auto_match_score is not None:
            before["automatic"] = True
        face.child_id, face.ignored = assignment.child_id, assignment.ignored
        face.confirmed_by = user.id if face.child_id is not None or face.ignored else None
        face.auto_match_score = face.auto_reference_face_id = None
        if old_reference != face.child_id:
            changed_references.append(face.id)
            if face.child_id is not None:
                index.reference_cursor = 0
        # Released clients submit unchanged, unassigned faces alongside an edited one.
        # Explicit withdrawal or reopening an ignored face must survive the auto pass.
        reopened = before["ignored"] and not face.ignored
        if face.child_id is not None:
            face.auto_link_blocked = False
        elif assignment.rejected_child_id is None:
            face.auto_link_blocked = face.auto_link_blocked or before["child_id"] is not None or reopened
        after = dict(child_id=face.child_id, ignored=face.ignored)
        record_identity(db, mid, "face", str(face.id), {k: v for k, v in before.items() if k != "automatic"}, after,
            automatic=False, evidence=dict(reason="管理员排除候选" if assignment.rejected_child_id else "管理员确认",
                rejected_child_id=assignment.rejected_child_id,
                frame_seconds=float(face.frame_seconds) if face.frame_seconds is not None else None))
        if before != after or assignment.rejected_child_id is not None:
            changes.append(dict(face_id=face.id, before=before, after=after,
                                rejected_child_id=assignment.rejected_child_id))
    sync_face_people(db, index)
    record_change(db, media, {"faces": {
        "before": [dict(face_id=c["face_id"], **c["before"]) for c in changes],
        "after": [dict(face_id=c["face_id"], **c["after"], rejected_child_id=c["rejected_child_id"]) for c in changes],
    }} if changes else {})
    if changed_references:
        queue_reference_dependents(db, changed_references)
    if data.assignments:
        index.match_pending = True
    return dict(matching_queued=bool(data.assignments and settings().face_auto_link_enabled
                                    and preferences(db)["people_enabled"]))


@router.put("/review/confirm-group")
def confirm_face_group(data: ConfirmFaceGroup, db=Depends(get_db), user=Depends(admin)):
    rows = db.execute(select(MediaFace.id, MediaFace.media_id).where(MediaFace.id.in_(data.face_ids))).all()
    if len(rows) != len(data.face_ids):
        raise HTTPException(409, "部分人脸已变化，请刷新后重试")
    grouped = defaultdict(list)
    for face_id, media_id in rows:
        grouped[media_id].append(face_id)
    if len(grouped) != len(data.face_ids):
        raise HTTPException(422, "每份影像只能选一张人脸一起确认")
    queued = False
    for media_id, ids in sorted(grouped.items()):
        media = active_media(db, media_id, user)
        db.execute(select(Media.id).where(Media.id == media_id).with_for_update()).scalar_one()
        current = list(db.scalars(select(MediaFace).where(MediaFace.id.in_(ids))
                                  .with_for_update().execution_options(populate_existing=True)))
        if len(current) != len(ids) or any(face.ignored or (
                face.child_id is not None and (face.child_id != data.child_id or face.confirmed_by != user.id))
                or data.child_id in (face.rejected_child_ids or []) for face in current):
            raise HTTPException(409, "部分人脸已被处理，请刷新后重试")
        assignments = [FaceAssignment(face_id=face.id, child_id=data.child_id) for face in current if face.child_id is None]
        if assignments:
            summary = apply_assignments(db, media, ConfirmFaces(assignments=assignments), user)
            queued = queued or summary["matching_queued"]
    db.commit()
    return dict(confirmed=len(data.face_ids), matching_queued=queued)


@router.delete("/media/{mid}")
def clear_faces(mid: int, db=Depends(get_db), user=Depends(admin)):
    media = active_media(db, mid, user)
    db.execute(select(Media.id).where(Media.id == mid).with_for_update()).scalar_one()
    index = db.scalar(select(MediaFaceIndex).where(MediaFaceIndex.media_id == mid).with_for_update())
    if index:
        reference_ids = list(db.scalars(select(MediaFace.id).where(MediaFace.media_id == mid)))
        queue_reference_dependents(db, reference_ids)
        current = set(db.scalars(select(MediaChild.child_id).where(MediaChild.media_id == mid)))
        set_children(db, mid, current - set(index.managed_child_ids), MediaChild)
        clear_identity_reviews(db, mid, "face")
        db.execute(delete(MediaFace).where(MediaFace.media_id == mid))
        db.delete(index)
        record_change(db, media, {"faces": {"before": "已分析", "after": "已清除"}})
        db.commit()
    return result(db, media)
