"""Store sharing permission on content, instead of selecting files per link."""
from alembic import op
import sqlalchemy as sa

revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None


def upgrade():
    for table in ("media", "timeline_folder", "timeline_event"):
        op.add_column(
            table,
            sa.Column(
                "share_allowed", sa.Boolean(), nullable=False, server_default="1"
            ),
        )
    op.create_table(
        "timeline_day",
        sa.Column("timeline_date", sa.Date(), primary_key=True),
        sa.Column("share_allowed", sa.Boolean(), nullable=False, server_default="1"),
        mysql_engine="InnoDB",
        mysql_charset="utf8mb4",
        mysql_collate="utf8mb4_unicode_ci",
    )
    # Do not broaden previously restricted links when removing their private selections.
    op.execute(
        """UPDATE timeline_share SET revoked = 1
        WHERE JSON_LENGTH(JSON_EXTRACT(exclusions, '$.days')) > 0
           OR JSON_LENGTH(JSON_EXTRACT(exclusions, '$.folders')) > 0
           OR JSON_LENGTH(JSON_EXTRACT(exclusions, '$.media')) > 0
           OR JSON_LENGTH(JSON_EXTRACT(exclusions, '$.events')) > 0"""
    )
    op.drop_column("timeline_share", "exclusions")


def downgrade():
    # A downgrade cannot represent global content permissions; retire existing links.
    op.execute("UPDATE timeline_share SET revoked = 1")
    op.add_column("timeline_share", sa.Column("exclusions", sa.JSON(), nullable=True))
    op.execute(
        """UPDATE timeline_share SET exclusions = JSON_OBJECT(
        'days', JSON_ARRAY(), 'folders', JSON_ARRAY(), 'media', JSON_ARRAY(), 'events', JSON_ARRAY())"""
    )
    op.alter_column(
        "timeline_share", "exclusions", existing_type=sa.JSON(), nullable=False
    )
    op.drop_table("timeline_day")
    for table in ("media", "timeline_folder", "timeline_event"):
        op.drop_column(table, "share_allowed")
