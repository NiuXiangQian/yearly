"""Allow pets to share the existing profile and timeline relationships."""
from alembic import op
import sqlalchemy as sa

revision = "0009"
down_revision = "0008"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "child",
        sa.Column(
            "profile_type", sa.String(16), nullable=False, server_default="child"
        ),
    )
    op.add_column(
        "child", sa.Column("species", sa.String(80), nullable=False, server_default="")
    )
    op.add_column(
        "child", sa.Column("breed", sa.String(80), nullable=False, server_default="")
    )
    op.alter_column("child", "birthday", existing_type=sa.Date(), nullable=True)


def downgrade():
    # A missing birthday cannot be represented in the old schema. Keep data intact
    # and let MySQL reject the downgrade until those birthdays have been filled in.
    op.alter_column("child", "birthday", existing_type=sa.Date(), nullable=False)
    for column in ("breed", "species", "profile_type"):
        op.drop_column("child", column)
