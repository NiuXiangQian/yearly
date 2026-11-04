"""Expiring, revocable, read-only timeline shares."""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.mysql import DATETIME

revision = "0007"
down_revision = "0006"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "timeline_share",
        sa.Column("id", sa.BigInteger(), primary_key=True),
        sa.Column("token_hash", sa.String(64), nullable=False, unique=True),
        sa.Column(
            "created_by", sa.BigInteger(), sa.ForeignKey("sys_user.id"), nullable=False
        ),
        sa.Column("title", sa.String(120), nullable=False),
        sa.Column("start_date", sa.Date(), nullable=False),
        sa.Column("end_date", sa.Date(), nullable=False),
        sa.Column("exclusions", sa.JSON(), nullable=False),
        sa.Column("expires_at", DATETIME(fsp=3), nullable=False),
        sa.Column("revoked", sa.Boolean(), nullable=False),
        sa.Column("created_at", DATETIME(fsp=3), nullable=False),
        mysql_engine="InnoDB",
        mysql_charset="utf8mb4",
        mysql_collate="utf8mb4_unicode_ci",
    )
    op.create_index("ix_timeline_share_created_by", "timeline_share", ["created_by"])


def downgrade():
    op.drop_table("timeline_share")
