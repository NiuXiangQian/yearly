"""Transaction-local organization decisions; automatic identities never seed references."""
from sqlalchemy import select
from .db import now
from .models import OrganizationSettings, OrganizationReview


def preferences(db):
    if "organization_preferences" not in db.info:
        row = db.get(OrganizationSettings, 1)
        db.info["organization_preferences"] = dict(tags_enabled=False, people_enabled=True, tag_rules={}, person_rules={}, face_excluded_child_ids=[]) | (row.options if row else {})
    return db.info["organization_preferences"]


def review_event(db, action, value):
    actor = db.info.get("actor")
    return dict(action=action, value=value, at=now().isoformat(),
                actor_id=actor.id if actor else None, actor_name=actor.display_name if actor and action not in {"automatic", "applied"} else "自动整理")


def record_identity(db, media_id, kind, target_id, before, after, *, automatic, evidence):
    for old in db.scalars(select(OrganizationReview).where(OrganizationReview.target_id == target_id,
            OrganizationReview.media_id == media_id, OrganizationReview.kind == kind, OrganizationReview.status.in_(["pending", "automatic"]))):
        old.status = "approved" if not automatic and old.current_value == after else "superseded"
        old.events = [*old.events, review_event(db, old.status, after)]
    if before == after:
        return
    mode = preferences(db)["person_rules"].get(str(after.get("child_id")), "default")
    status = "automatic" if automatic and mode == "automatic" else "pending" if automatic else "approved"
    if automatic and after.get("ignored"):
        status = "automatic"
    elif after.get("child_id") is None and automatic:
        status = "superseded"
    db.add(OrganizationReview(media_id=media_id, kind=kind, target_id=target_id, automatic=automatic,
        status=status, before_value=before, proposed_value=after, current_value=after, evidence=evidence,
        events=[review_event(db, ("automatic" if status == "automatic" else "applied") if automatic else "confirmed", after)]))


def clear_identity_reviews(db, media_id, kind):
    for row in db.scalars(select(OrganizationReview).where(OrganizationReview.media_id == media_id,
            OrganizationReview.kind == kind)):
        row.status = "superseded"
        row.events = [*row.events, review_event(db, "superseded", dict(child_id=None, reason="识别样本已清除"))]
