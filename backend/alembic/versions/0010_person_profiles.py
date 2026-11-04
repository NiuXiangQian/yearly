"""Support people of any family relationship alongside child and pet profiles."""
from alembic import op
import sqlalchemy as sa

revision = "0010"
down_revision = "0009"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "child",
        sa.Column("relationship", sa.String(80), nullable=False, server_default=""),
    )
    op.execute("UPDATE child SET relationship = '孩子' WHERE profile_type = 'child'")


def downgrade():
    # Keep profiles and their media links readable by the previous version.
    op.execute("UPDATE child SET profile_type = 'child' WHERE profile_type = 'person'")
    op.drop_column("child", "relationship")
