"""Optional exact-media scope for existing expiring shares (MySQL 5.7 JSON)."""
from alembic import op
import sqlalchemy as sa

revision = "0012"
down_revision = "0011"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("timeline_share", sa.Column("media_ids", sa.JSON(), nullable=True))


def downgrade():
    # Old code would interpret these as date links; revoke before dropping scope.
    op.execute("UPDATE timeline_share SET revoked = 1 WHERE media_ids IS NOT NULL")
    op.drop_column("timeline_share", "media_ids")
