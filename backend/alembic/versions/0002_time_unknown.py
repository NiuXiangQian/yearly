"""Allow an explicit unknown-time override without losing source metadata."""

from alembic import op
import sqlalchemy as sa

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "media",
        sa.Column(
            "time_unknown", sa.Boolean(), nullable=False, server_default=sa.text("0")
        ),
    )


def downgrade():
    op.drop_column("media", "time_unknown")
