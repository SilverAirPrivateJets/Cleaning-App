-- =====================================================================
-- Silver Air Cleaning Desk: vendor email notifications
-- Paste this whole file into Supabase > SQL Editor > New query, then Run.
-- Safe to run more than once. Jobs keep saving normally even if email fails.
-- The real secret is NOT stored in this public repo. It lives in Supabase (Edge Functions > Secrets > DESK_SECRET).
-- Only replace REPLACE_WITH_DESK_SECRET locally when re running this file; never commit the real value.
-- =====================================================================

create extension if not exists pg_net;

create table if not exists private.settings (
  key   text primary key,
  value text not null
);
alter table private.settings enable row level security;
revoke all on private.settings from public;

insert into private.settings (key, value) values
  ('notify_url',    'https://yosioojtuzvchvzdmrpt.supabase.co/functions/v1/notify-vendor'),
  ('notify_secret', 'REPLACE_WITH_DESK_SECRET')
on conflict (key) do update set value = excluded.value;

create or replace function private.job_notify() returns trigger
language plpgsql security definer set search_path = public, private, extensions as $$
declare
  items jsonb := '[]'::jsonb;
  msgs  jsonb := '[]'::jsonb;
  it    jsonb;
  lastn jsonb;
  st    text;
  ost   text;
  v     record;
  ac    text;
  url   text;
  sec   text;
begin
  if tg_op = 'INSERT' then
    if new.vendor_id is not null then
      items := items || jsonb_build_array(jsonb_build_object('kind', 'new', 'vendor', new.vendor_id));
    end if;
  elsif new.vendor_id is distinct from old.vendor_id then
    if new.vendor_id is not null and coalesce(new.data->>'status', '') <> 'cancelled' then
      items := items || jsonb_build_array(jsonb_build_object('kind', 'assigned', 'vendor', new.vendor_id));
    end if;
    if old.vendor_id is not null and coalesce(old.data->>'status', '') in ('requested', 'accepted', 'in_progress') then
      items := items || jsonb_build_array(jsonb_build_object('kind', 'removed', 'vendor', old.vendor_id));
    end if;
  elsif new.vendor_id is not null
        and jsonb_array_length(coalesce(new.data->'activity', '[]'::jsonb)) > 0
        and (new.data->'activity'->-1) is distinct from (old.data->'activity'->-1) then
    lastn := new.data->'activity'->-1;
    if lastn->>'as' = 'Silver Air' then
      st  := coalesce(new.data->>'status', '');
      ost := coalesce(old.data->>'status', '');
      if st = 'cancelled' and ost <> 'cancelled' then
        items := items || jsonb_build_array(jsonb_build_object('kind', 'cancelled', 'vendor', new.vendor_id));
      elsif ost = 'cancelled' and st = 'requested' then
        items := items || jsonb_build_array(jsonb_build_object('kind', 'reopened', 'vendor', new.vendor_id));
      elsif lastn->>'type' = 'edit' then
        items := items || jsonb_build_array(jsonb_build_object('kind', 'changed', 'vendor', new.vendor_id));
      elsif lastn->>'type' = 'comment' then
        items := items || jsonb_build_array(jsonb_build_object('kind', 'comment', 'vendor', new.vendor_id));
      end if;
    end if;
  end if;

  if jsonb_array_length(items) = 0 then return new; end if;

  select s.value into url from private.settings s where s.key = 'notify_url';
  select s.value into sec from private.settings s where s.key = 'notify_secret';
  if url is null or sec is null then return new; end if;

  select f.data->>'type' into ac from public.fleet f where f.tail = new.data->>'tail';

  for it in select * from jsonb_array_elements(items) loop
    select x.id, x.data->>'name' as name, coalesce(x.data->>'email', '') as email
      into v from public.vendors x where x.id = it->>'vendor';
    if v.id is null or trim(v.email) = '' then continue; end if;
    msgs := msgs || jsonb_build_array(jsonb_build_object(
      'kind',        it->>'kind',
      'vendorName',  v.name,
      'emails',      v.email,
      'jobId',       new.id,
      'ref',         new.data->>'ref',
      'tail',        new.data->>'tail',
      'aircraft',    ac,
      'airport',     new.data->>'airport',
      'fbo',         new.data->>'fbo',
      'start',       new.data->>'start',
      'due',         new.data->>'due',
      'services',    coalesce(new.data->'services', '[]'::jsonb),
      'notes',       new.data->>'notes',
      'status',      new.data->>'status',
      'by',          coalesce(new.data->'activity'->-1->>'by', new.data->>'requestedBy'),
      'message',     new.data->'activity'->-1->>'text'
    ));
  end loop;

  if jsonb_array_length(msgs) = 0 then return new; end if;

  perform net.http_post(
    url := url,
    body := jsonb_build_object('messages', msgs),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-desk-secret', sec),
    timeout_milliseconds := 8000
  );
  return new;
exception when others then
  raise warning 'Cleaning Desk email notification skipped: %', sqlerrm;
  return new;
end $$;

revoke execute on function private.job_notify() from public;

drop trigger if exists jobs_notify on public.jobs;
create trigger jobs_notify
  after insert or update on public.jobs
  for each row execute function private.job_notify();
