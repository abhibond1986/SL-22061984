-- ═══════════════════════════════════════════════════════════════════════════
--  Safety Lens — closing loop: action photo, verifier and case history
--  (2026-10-16). Run ONCE in the Supabase SQL editor. Safe to re-run.
-- ═══════════════════════════════════════════════════════════════════════════
--
--  The app now records, on every Near Miss / MAMR case:
--    action_by         who submitted the corrective action ("Name (P.No x)")
--    action_image_url  the optional "after" photo (Storage object act_<id>.jpg)
--    action_image_at   when that photo was attached
--    verified_at / verified_by   the reporter's verification
--    sent_back_reason  why the reporter returned the action, if they did
--    action_log        jsonb list: the dated history printed in the PDF
--
--  Until this runs, upsertIncident drops these columns and retries, so cases
--  still sync, but the history and photo stay on the device that made them.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.incidents add column if not exists action_by        text;
alter table public.incidents add column if not exists action_image_url text;
alter table public.incidents add column if not exists action_image_at  text;
alter table public.incidents add column if not exists verified_at      text;
alter table public.incidents add column if not exists verified_by      text;
alter table public.incidents add column if not exists sent_back_reason text;
alter table public.incidents add column if not exists action_log       jsonb;

notify pgrst, 'reload schema';

-- ── Verify ── should list all seven columns.
select column_name, data_type
from information_schema.columns
where table_schema = 'public' and table_name = 'incidents'
  and column_name in ('action_by','action_image_url','action_image_at',
    'verified_at','verified_by','sent_back_reason','action_log')
order by column_name;
