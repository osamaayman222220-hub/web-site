-- ============================================================
-- رعايه | CareNest - Migration V3 (small fixes)
-- Run AFTER: schema.sql, migration_v2_complete.sql, migration_fix_bookings_and_nurses.sql
-- Safe to run more than once. Does not delete data.
-- ============================================================

-- The booking trigger (validate_and_sync_booking) reads NEW.price and NEW.start_time,
-- but no earlier script ever created those columns on public.bookings. Without them,
-- every booking insert fails with: record "new" has no field "price".
alter table public.bookings
  add column if not exists price numeric(10,2) default 0.00,
  add column if not exists start_time time;
