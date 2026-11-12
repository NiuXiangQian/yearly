"""Optional visual search index; existing media and client contracts stay intact."""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.mysql import DATETIME

revision = "0018"
down_revision = "0017"
branch_labels = None
depends_on = None


def upgrade():
    options = dict(mysql_engine="InnoDB", mysql_charset="utf8mb4", mysql_collate="utf8mb4_unicode_ci")
    op.create_table(
        "media_search_index",
        sa.Column("media_id", sa.BigInteger(), sa.ForeignKey("media.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("description", sa.Text(), nullable=False),
        sa.Column("embedding", sa.JSON(), nullable=False),
        sa.Column("frame_seconds", sa.JSON(), nullable=False),
        sa.Column("error", sa.String(255), nullable=False),
        sa.Column("created_at", DATETIME(fsp=3), nullable=False),
        sa.Column("updated_at", DATETIME(fsp=3), nullable=False),
        **options,
    )
    op.create_index("ix_media_search_index_status", "media_search_index", ["status"])
    op.create_table("ai_spend", sa.Column("month", sa.String(7), primary_key=True),
                    sa.Column("amount", sa.Numeric(12, 6), nullable=False), **options)


def downgrade():
    op.drop_table("media_search_index")
    op.drop_table("ai_spend")
