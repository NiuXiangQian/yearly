"""Name upload batches and organize media by day and manual order."""

from alembic import op
import sqlalchemy as sa

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "media",
        sa.Column("batch_name", sa.String(255), nullable=False, server_default=""),
    )
    op.add_column("media", sa.Column("timeline_date", sa.Date(), nullable=True))
    op.add_column(
        "media",
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="0"),
    )


def downgrade():
    op.drop_column("media", "sort_order")
    op.drop_column("media", "timeline_date")
    op.drop_column("media", "batch_name")
