"""Separate profile avatars from timeline memories."""

from alembic import op
import sqlalchemy as sa

revision = "0006"
down_revision = "0005"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "media",
        sa.Column("purpose", sa.String(16), nullable=False, server_default="memory"),
    )


def downgrade():
    op.drop_column("media", "purpose")
