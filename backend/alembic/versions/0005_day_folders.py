"""Named folders inside a timeline day."""

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.mysql import DATETIME

revision = "0005"
down_revision = "0004"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "timeline_folder",
        sa.Column("id", sa.BigInteger(), primary_key=True),
        sa.Column("name", sa.String(255), nullable=False),
        sa.Column("timeline_date", sa.Date(), nullable=False),
        sa.Column("sort_order", sa.Integer(), nullable=False),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("created_at", DATETIME(fsp=3), nullable=False),
        sa.Column("updated_at", DATETIME(fsp=3), nullable=False),
        mysql_engine="InnoDB",
        mysql_charset="utf8mb4",
        mysql_collate="utf8mb4_unicode_ci",
    )
    op.create_index(
        "ix_timeline_folder_timeline_date", "timeline_folder", ["timeline_date"]
    )
    op.add_column("media", sa.Column("folder_id", sa.BigInteger(), nullable=True))
    op.create_index("ix_media_folder_id", "media", ["folder_id"])
    op.create_foreign_key(
        "fk_media_folder", "media", "timeline_folder", ["folder_id"], ["id"]
    )


def downgrade():
    op.drop_constraint("fk_media_folder", "media", type_="foreignkey")
    op.drop_index("ix_media_folder_id", table_name="media")
    op.drop_column("media", "folder_id")
    op.drop_table("timeline_folder")
