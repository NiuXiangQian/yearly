"""Record caption model without changing existing media or API contracts."""
from alembic import op
import sqlalchemy as sa

revision = "0019"
down_revision = "0018"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("media_search_index", sa.Column("analysis_model", sa.String(64), nullable=False, server_default="gpt-4.1-mini"))


def downgrade():
    op.drop_column("media_search_index", "analysis_model")
