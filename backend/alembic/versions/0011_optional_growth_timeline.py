"""Separate growth timelines from people and pet tagging."""
from alembic import op
import sqlalchemy as sa

revision = "0011"
down_revision = "0010"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "child",
        sa.Column("growth_enabled", sa.Boolean(), nullable=False, server_default="1"),
    )
    op.execute(
        "UPDATE child SET growth_enabled = 0 WHERE profile_type = 'person' AND relationship <> '孩子'"
    )


def downgrade():
    op.drop_column("child", "growth_enabled")
