"""Regenerable, SHA-deduplicated compressed video previews."""

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.mysql import DATETIME

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "video_preview",
        sa.Column("sha256", sa.String(64), primary_key=True),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("object_key", sa.String(191), nullable=False),
        sa.Column("file_size", sa.BigInteger(), nullable=False),
        sa.Column("error", sa.String(255), nullable=False),
        sa.Column("created_at", DATETIME(fsp=3), nullable=False),
        sa.Column("updated_at", DATETIME(fsp=3), nullable=False),
        mysql_engine="InnoDB",
        mysql_charset="utf8mb4",
        mysql_collate="utf8mb4_unicode_ci",
    )


def downgrade():
    op.drop_table("video_preview")
