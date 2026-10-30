-- migration_profile_self_edit.sql  (2026-10-30)
--
-- My Profile: an employee can correct their own mobile, email, designation,
-- department and unit. These two columns record WHICH fields they edited, so
-- the quarterly HR import (UserImportRunner) keeps the employee's value
-- instead of overwriting it with the file.
--
-- Safe to run more than once. Until it is run, profile edits still save, but
-- the app warns that the next import may replace them.

alter table app_users add column if not exists self_edited_fields text;
alter table app_users add column if not exists self_edited_at     timestamptz;

-- Rollback (loses only the "keep my edit" markers, not the values):
--   alter table app_users drop column if exists self_edited_fields;
--   alter table app_users drop column if exists self_edited_at;
