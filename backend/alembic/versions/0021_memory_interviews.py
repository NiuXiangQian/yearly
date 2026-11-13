"""Persist administrator memory interview drafts and accepted progress."""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.mysql import DATETIME

revision = "0021"
down_revision = "0020"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table("media_interview",
        sa.Column("media_id", sa.BigInteger(), sa.ForeignKey("media.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("messages", sa.JSON(), nullable=False),
        sa.Column("suggestions", sa.JSON(), nullable=False),
        sa.Column("source_fingerprint", sa.String(64), nullable=False),
        sa.Column("applied_message_count", sa.Integer(), nullable=False),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("updated_by", sa.BigInteger(), sa.ForeignKey("sys_user.id")),
        sa.Column("created_at", DATETIME(fsp=3), nullable=False),
        sa.Column("updated_at", DATETIME(fsp=3), nullable=False),
        mysql_engine="InnoDB", mysql_charset="utf8mb4")
    op.create_index("ix_media_interview_status", "media_interview", ["status"])


def downgrade():
    op.drop_table("media_interview")
