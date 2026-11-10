"""Per-client visit counters for public shares."""
from alembic import op
import sqlalchemy as sa

revision = "0014"
down_revision = "0013"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "share_visit",
        sa.Column("share_id", sa.BigInteger(), sa.ForeignKey("timeline_share.id"), primary_key=True),
        sa.Column("client_hash", sa.String(64), primary_key=True),
        sa.Column("visit_count", sa.BigInteger(), nullable=False, server_default="1"),
        mysql_engine="InnoDB",
        mysql_charset="utf8mb4",
        mysql_collate="utf8mb4_unicode_ci",
    )


def downgrade():
    op.drop_table("share_visit")
