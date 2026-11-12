"""up for something: what you're up for, and meet-ups when someone's in

Revision ID: 0008
Revises: 0007
"""

import sqlalchemy as sa

from alembic import op

revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "porch_lights", sa.Column("activity", sa.String(length=20), server_default="", nullable=False)
    )
    op.create_table(
        "meetups",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("host_id", sa.UUID(), nullable=False),
        sa.Column("guest_id", sa.UUID(), nullable=False),
        sa.Column("activity", sa.String(length=20), nullable=False),
        sa.Column("words", sa.String(length=80), nullable=False),
        sa.Column("host_lat", sa.Float(), nullable=True),
        sa.Column("host_lon", sa.Float(), nullable=True),
        sa.Column("guest_lat", sa.Float(), nullable=True),
        sa.Column("guest_lon", sa.Float(), nullable=True),
        sa.Column("host_on_way_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("guest_on_way_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("host_says", sa.String(length=40), nullable=False),
        sa.Column("guest_says", sa.String(length=40), nullable=False),
        sa.Column("spot_name", sa.String(length=120), nullable=True),
        sa.Column("spot_lat", sa.Float(), nullable=True),
        sa.Column("spot_lon", sa.Float(), nullable=True),
        sa.Column("meet_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ends_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("done_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.CheckConstraint("host_id <> guest_id", name="meetup_not_self"),
        sa.ForeignKeyConstraint(["guest_id"], ["users.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["host_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_meetups_guest_id"), "meetups", ["guest_id"], unique=False)
    op.create_index(op.f("ix_meetups_host_id"), "meetups", ["host_id"], unique=False)


def downgrade() -> None:
    op.drop_index(op.f("ix_meetups_host_id"), table_name="meetups")
    op.drop_index(op.f("ix_meetups_guest_id"), table_name="meetups")
    op.drop_table("meetups")
    op.drop_column("porch_lights", "activity")
