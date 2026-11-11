"""Optional person scope for existing and new timeline shares."""

from alembic import op
import sqlalchemy as sa

revision = "0017"
down_revision = "0016"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("timeline_share", sa.Column("profile_id", sa.BigInteger(), nullable=True))
    op.create_foreign_key("fk_share_profile", "timeline_share", "child", ["profile_id"], ["id"])


def downgrade():
    op.drop_constraint("fk_share_profile", "timeline_share", type_="foreignkey")
    op.drop_column("timeline_share", "profile_id")
