-- A form the poller cannot open has no event yet: we cannot read its responses, so we know
-- neither its date nor its attendees. Before this change forms.event_id was NOT NULL, so the
-- ingest function's unreadable-form path could never insert its row at all — the write failed and
-- the error was discarded, meaning the single most likely way an officer breaks ingestion (making
-- a form under a personal account instead of the shared Gmail) was invisible on Needs attention.
-- See docs/DESIGN.md verification #10, which requires that case to fail loudly.
--
-- The alternative, inventing a placeholder event so the column could stay NOT NULL, was rejected:
-- it would put an untyped event with no attendance on Needs attention and invite an officer to tap
-- a type on an event that will never have attendees.
alter table public.forms alter column event_id drop not null;

-- The officer-facing name of the form. Needs attention previously had only the Drive file ID to
-- show for an unreadable form, which a non-technical VP cannot act on without pasting it into a
-- Drive URL. The poller already sends the title on every form, readable or not.
alter table public.forms add column if not exists title text;

comment on column public.forms.event_id is
  'Null only while a form has never been readable. Set on first successful poll, when the event is created.';
comment on column public.forms.title is
  'Form title as seen in Drive, recorded so Needs attention can name an unreadable form.';
