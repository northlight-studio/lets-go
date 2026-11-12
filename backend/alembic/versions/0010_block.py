"""your block: when a batch was posted, so the block can say what's new

Revision ID: 0010
Revises: 0009
"""

import sqlalchemy as sa

from alembic import op

revision = "0010"
down_revision = "0009"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Batches posted before this read as posted now: they're at most a few days old anyway.
    op.add_column(
        "drops",
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
    )


def downgrade() -> None:
    op.drop_column("drops", "created_at")
