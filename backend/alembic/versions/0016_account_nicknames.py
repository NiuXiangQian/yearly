"""Optional account nicknames, preserving existing login usernames."""

from alembic import op
import sqlalchemy as sa

revision = "0016"
down_revision = "0015"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "sys_user", sa.Column("nickname", sa.String(80), nullable=False, server_default="")
    )


def downgrade():
    op.drop_column("sys_user", "nickname")
