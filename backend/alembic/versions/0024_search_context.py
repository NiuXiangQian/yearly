"""Cache semantic search context without replacing visual descriptions."""
from alembic import op
import sqlalchemy as sa

revision = "0024"
down_revision = "0023"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("media_search_index", sa.Column("context_fingerprint", sa.String(64)))
    op.add_column("media_search_index", sa.Column("context_embedding", sa.JSON(none_as_null=True)))


def downgrade():
    op.drop_column("media_search_index", "context_embedding")
    op.drop_column("media_search_index", "context_fingerprint")
