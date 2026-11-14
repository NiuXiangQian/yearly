"""Confirm generated tags automatically and finish the existing tag review queue."""
from datetime import datetime, timezone
from alembic import op
import sqlalchemy as sa

revision = "0026"
down_revision = "0025"
branch_labels = None
depends_on = None


def confirm_pending_tags(connection):
    metadata = sa.MetaData()
    settings = sa.Table("ai_organization_settings", metadata, autoload_with=connection)
    reviews = sa.Table("ai_organization_review", metadata, autoload_with=connection)
    media = sa.Table("media", metadata, autoload_with=connection)
    children = sa.Table("child", metadata, autoload_with=connection)
    stamp = datetime.now(timezone.utc).replace(tzinfo=None)
    options_row = connection.execute(sa.select(settings).where(settings.c.id == 1).with_for_update()).mappings().first()
    options = dict(options_row["options"]) if options_row else {}
    rules = {key: dict(value) for key, value in options.get("tag_rules", {}).items()}
    for rule in rules.values():
        if rule["mode"] == "manual":
            rule["mode"] = "automatic"
    if options_row:
        options["tag_rules"] = rules
        connection.execute(settings.update().where(settings.c.id == 1).values(options=options, updated_at=stamp))
    names = {name for row in connection.execute(sa.select(children.c.name, children.c.nickname).where(children.c.status != "deleted")) for name in row if name}
    count = 0
    # Keyset batches avoid loading the entire family history at once.
    last = 0
    while True:
        rows = connection.execute(sa.select(reviews).where(reviews.c.kind == "tags", reviews.c.status == "pending", reviews.c.id > last).order_by(reviews.c.id).limit(200).with_for_update()).mappings().all()
        if not rows:
            break
        for row in rows:
            last = row["id"]
            item = connection.execute(sa.select(media).where(media.c.id == row["media_id"]).with_for_update()).mappings().one()
            tags = list(item["tags"])
            applied_before = row["current_value"].get("tags", [])
            proposed = row["proposed_value"].get("tags", [])
            added = []
            if item["status"] == "active" and item["purpose"] == "memory":
                for tag in proposed:
                    # Do not restore a tag already applied then removed by a later edit.
                    if tag in tags or tag in applied_before or tag in names or len(tags) >= 30:
                        continue
                    evidence = next((t for t in row["evidence"].get("tags", []) if t["name"] == tag), {})
                    rule = rules.get(evidence.get("source_name", tag), {})
                    if rule.get("mode") == "skip":
                        continue
                    tags.append(tag)
                    added.append(tag)
            if added:
                connection.execute(media.update().where(media.c.id == item["id"]).values(tags=tags, updated_at=stamp))
            applied = [t for t in proposed if t in tags and (t in applied_before or t in added)]
            current = dict(tags=applied, decisions={t: t if t in applied else None for t in proposed})
            event = dict(action="automatic", value=current, at=stamp.isoformat(), actor_id=None, actor_name="自动整理")
            connection.execute(reviews.update().where(reviews.c.id == row["id"]).values(status="automatic", current_value=current, events=[*row["events"], event], updated_at=stamp))
            count += 1
    return count


def upgrade():
    confirm_pending_tags(op.get_bind())


def downgrade():
    # Saved tags and audit history are user data; reverting code must not remove them.
    pass
