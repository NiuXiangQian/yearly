"""Automatic organization preferences and reviewable decision history."""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.mysql import DATETIME

revision = "0023"
down_revision = "0022"
branch_labels = None
depends_on = None


def upgrade():
    common = dict(mysql_engine="InnoDB", mysql_charset="utf8mb4")
    op.create_table("ai_organization_settings",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("options", sa.JSON(), nullable=False),
        sa.Column("updated_by", sa.BigInteger(), sa.ForeignKey("sys_user.id")),
        sa.Column("created_at", DATETIME(fsp=3), nullable=False),
        sa.Column("updated_at", DATETIME(fsp=3), nullable=False), **common)
    op.create_table("media_organization",
        sa.Column("media_id", sa.BigInteger(), sa.ForeignKey("media.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("source_updated_at", DATETIME(fsp=3), nullable=False),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("error", sa.String(255), nullable=False),
        sa.Column("created_at", DATETIME(fsp=3), nullable=False),
        sa.Column("updated_at", DATETIME(fsp=3), nullable=False), **common)
    op.create_table("ai_organization_review",
        sa.Column("id", sa.BigInteger(), primary_key=True),
        sa.Column("media_id", sa.BigInteger(), sa.ForeignKey("media.id", ondelete="CASCADE"), nullable=False),
        sa.Column("kind", sa.String(16), nullable=False),
        sa.Column("target_id", sa.String(80), nullable=False),
        sa.Column("automatic", sa.Boolean(), nullable=False),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("before_value", sa.JSON(), nullable=False),
        sa.Column("proposed_value", sa.JSON(), nullable=False),
        sa.Column("current_value", sa.JSON(), nullable=False),
        sa.Column("evidence", sa.JSON(), nullable=False),
        sa.Column("events", sa.JSON(), nullable=False),
        sa.Column("created_at", DATETIME(fsp=3), nullable=False),
        sa.Column("updated_at", DATETIME(fsp=3), nullable=False), **common)
    for column in ["media_id", "kind", "target_id", "status"]:
        op.create_index("ix_ai_organization_review_" + column, "ai_organization_review", [column])


def downgrade():
    for name in ["ai_organization_review", "media_organization", "ai_organization_settings"]:
        op.drop_table(name)
