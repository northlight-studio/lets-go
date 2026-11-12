"""supper club: suppers, seats and reviews both ways

Revision ID: 0010
Revises: 0009
"""

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision = "0010"
down_revision = "0009"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "suppers",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("host_id", sa.UUID(), nullable=False),
        sa.Column("kitchen_id", sa.UUID(), nullable=False),
        sa.Column("title", sa.String(length=80), nullable=False),
        sa.Column("starts_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ends_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("seats", sa.Integer(), nullable=False),
        sa.Column("price_cents", sa.Integer(), nullable=False),
        sa.Column("menu", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("tags", sa.ARRAY(sa.String(length=30)), nullable=False),
        sa.Column("house_notes", sa.Text(), nullable=False),
        sa.Column("photo_id", sa.UUID(), nullable=True),
        sa.Column("canceled_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.CheckConstraint("ends_at > starts_at", name="supper_ends_after_start"),
        sa.CheckConstraint("price_cents > 0", name="supper_price_positive"),
        sa.CheckConstraint("seats BETWEEN 1 AND 20", name="supper_seats_range"),
        sa.ForeignKeyConstraint(["host_id"], ["users.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["kitchen_id"], ["kitchens.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["photo_id"], ["photos.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_suppers_ends_at"), "suppers", ["ends_at"], unique=False)
    op.create_index(op.f("ix_suppers_host_id"), "suppers", ["host_id"], unique=False)
    op.create_table(
        "supper_reviews",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("supper_id", sa.UUID(), nullable=False),
        sa.Column("author_id", sa.UUID(), nullable=False),
        sa.Column("subject_id", sa.UUID(), nullable=False),
        sa.Column("stars", sa.Integer(), nullable=False),
        sa.Column("text", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.CheckConstraint("author_id <> subject_id", name="supper_review_not_self"),
        sa.CheckConstraint("stars BETWEEN 1 AND 5", name="supper_review_stars_range"),
        sa.ForeignKeyConstraint(["author_id"], ["users.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["subject_id"], ["users.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["supper_id"], ["suppers.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("supper_id", "author_id", "subject_id", name="supper_review_once"),
    )
    op.create_index(op.f("ix_supper_reviews_subject_id"), "supper_reviews", ["subject_id"], unique=False)
    op.create_table(
        "supper_seats",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("supper_id", sa.UUID(), nullable=False),
        sa.Column("guest_id", sa.UUID(), nullable=False),
        sa.Column("note", sa.String(length=200), nullable=False),
        sa.Column("status", sa.String(length=12), nullable=False),
        sa.Column("payment", sa.String(length=12), nullable=False),
        sa.Column("price_cents", sa.Integer(), nullable=False),
        sa.Column("service_cents", sa.Integer(), nullable=False),
        sa.Column("payment_intent_id", sa.String(length=64), nullable=True),
        sa.Column("paid_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("decided_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("ended_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(["guest_id"], ["users.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["supper_id"], ["suppers.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("payment_intent_id"),
        sa.UniqueConstraint("supper_id", "guest_id", name="supper_seat_once"),
    )
    op.create_index(op.f("ix_supper_seats_guest_id"), "supper_seats", ["guest_id"], unique=False)
    op.create_index(op.f("ix_supper_seats_supper_id"), "supper_seats", ["supper_id"], unique=False)


def downgrade() -> None:
    op.drop_index(op.f("ix_supper_seats_supper_id"), table_name="supper_seats")
    op.drop_index(op.f("ix_supper_seats_guest_id"), table_name="supper_seats")
    op.drop_table("supper_seats")
    op.drop_index(op.f("ix_supper_reviews_subject_id"), table_name="supper_reviews")
    op.drop_table("supper_reviews")
    op.drop_index(op.f("ix_suppers_host_id"), table_name="suppers")
    op.drop_index(op.f("ix_suppers_ends_at"), table_name="suppers")
    op.drop_table("suppers")
