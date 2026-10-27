-- =====================================================================
-- Silver Air Cleaning Desk: Supabase setup
-- Paste this whole file into Supabase > SQL Editor > New query, then Run.
-- Safe to run more than once.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;
create schema if not exists private;
revoke all on schema private from public;

-- ---------- tables ----------
create table if not exists public.vendors (
  id   text primary key,
  data jsonb not null default '{}'::jsonb
);
create table if not exists public.fleet (
  tail text primary key,
  data jsonb not null default '{}'::jsonb
);
create table if not exists public.config (
  id   int primary key default 1,
  data jsonb not null default '{}'::jsonb
);
create table if not exists public.jobs (
  id         text primary key default gen_random_uuid()::text,
  vendor_id  text,
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
create table if not exists public.photos (
  id         text primary key default gen_random_uuid()::text,
  job_id     text not null references public.jobs(id) on delete cascade,
  kind       text not null,
  data       text not null,
  created_at timestamptz not null default now()
);
create index if not exists photos_job_idx on public.photos(job_id);
create index if not exists jobs_vendor_idx on public.jobs(vendor_id);

create table if not exists private.codes (
  who        text primary key,          -- 'admin', 'staff' or 'vendor:<vendor id>'
  hash       text not null,
  updated_at timestamptz not null default now()
);

-- Lock every table down. The app only talks to the database through the
-- desk_* functions below, which check the passcode first.
alter table public.vendors enable row level security;
alter table public.fleet   enable row level security;
alter table public.config  enable row level security;
alter table public.jobs    enable row level security;
alter table public.photos  enable row level security;
alter table private.codes  enable row level security;
revoke all on public.vendors, public.fleet, public.config, public.jobs, public.photos from anon, authenticated;
revoke all on private.codes from public;

-- ---------- helpers (private, not reachable from the app) ----------
create or replace function private.pick(obj jsonb, keys text[]) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
  from jsonb_each(coalesce(obj, '{}'::jsonb)) where key = any(keys)
$$;

create or replace function private.last150(a jsonb) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_agg(e order by i), '[]'::jsonb)
  from jsonb_array_elements(coalesce(a, '[]'::jsonb)) with ordinality as t(e, i)
  where i > jsonb_array_length(coalesce(a, '[]'::jsonb)) - 150
$$;

create or replace function private.whoami(p_code text)
returns table (o_role text, o_vendor text, o_must boolean)
language plpgsql security definer set search_path = public, extensions, private as $$
declare r record;
begin
  if p_code is not null and length(p_code) >= 4 then
    for r in select c.who, c.hash from private.codes c loop
      if r.hash = crypt(p_code, r.hash) then
        if r.who like 'vendor:%' then
          if exists (select 1 from public.vendors v where v.id = substr(r.who, 8)) then
            return query select 'vendor'::text, substr(r.who, 8), false;
            return;
          end if;
        else
          return query select r.who, null::text, (r.who = 'admin' and p_code = 'ChangeMe123');
          return;
        end if;
      end if;
    end loop;
  end if;
  perform pg_sleep(0.5);            -- slows down guessing
  raise exception 'bad_code';
end $$;

-- Same as whoami, but refuses the temporary admin code for anything except setting a new one.
create or replace function private.auth(p_code text)
returns table (o_role text, o_vendor text, o_must boolean)
language plpgsql security definer set search_path = public, extensions, private as $$
declare me record;
begin
  select * into me from private.whoami(p_code);
  if me.o_must then raise exception 'must_change'; end if;
  return query select me.o_role, me.o_vendor, me.o_must;
end $$;

create or replace function private.org(p_role text, p_vendor text) returns text
language sql stable security definer set search_path = public as $$
  select case when p_role = 'vendor'
    then coalesce((select v.data->>'name' from public.vendors v where v.id = p_vendor), 'Vendor')
    else 'Silver Air' end
$$;

create or replace function private.act(p_role text, p_vendor text, p_by text, p_type text, p_text text) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object(
    'at', now(),
    'by', nullif(left(trim(coalesce(p_by, '')), 80), ''),
    'as', private.org(p_role, p_vendor),
    'type', case when p_type in ('status','comment','photo','edit') then p_type else 'status' end,
    'text', left(coalesce(p_text, ''), 4000))
$$;

create or replace function private.set_code(p_who text, p_new text) returns void
language plpgsql security definer set search_path = public, extensions, private as $$
declare r record;
begin
  for r in select c.who, c.hash from private.codes c where c.who <> p_who loop
    if r.hash = crypt(p_new, r.hash) then raise exception 'code_in_use'; end if;
  end loop;
  insert into private.codes (who, hash, updated_at) values (p_who, crypt(p_new, gen_salt('bf', 8)), now())
  on conflict (who) do update set hash = excluded.hash, updated_at = now();
end $$;

-- ---------- app functions ----------
create or replace function public.desk_load(p_code text) returns jsonb
language plpgsql security definer set search_path = public, extensions, private as $$
declare me record;
begin
  select * into me from private.whoami(p_code);
  if me.o_must then
    return jsonb_build_object('role', me.o_role, 'mustChange', true);
  end if;
  return jsonb_build_object(
    'role', me.o_role,
    'vendorId', me.o_vendor,
    'mustChange', false,
    'vendors', coalesce((select jsonb_agg(v.data || jsonb_build_object('id', v.id))
                         from vendors v where me.o_role <> 'vendor' or v.id = me.o_vendor), '[]'::jsonb),
    'fleet', coalesce((select jsonb_agg(f.data || jsonb_build_object('tail', f.tail)) from fleet f), '[]'::jsonb),
    'config', coalesce((select c.data from config c where c.id = 1), '{}'::jsonb),
    'jobs', coalesce((select jsonb_agg(j.data || jsonb_build_object('id', j.id, 'vendorId', j.vendor_id))
                      from jobs j where me.o_role <> 'vendor' or j.vendor_id = me.o_vendor), '[]'::jsonb),
    'codes', case when me.o_role = 'admin'
                  then coalesce((select jsonb_agg(c.who) from private.codes c), '[]'::jsonb)
                  else '[]'::jsonb end
  );
end $$;

create or replace function public.desk_job_create(p_code text, p_data jsonb, p_by text) returns text
language plpgsql security definer set search_path = public, extensions, private as $$
declare me record; new_id text := gen_random_uuid()::text; vname text; d jsonb;
begin
  select * into me from private.auth(p_code);
  if me.o_role not in ('admin', 'staff') then raise exception 'not_allowed'; end if;
  select v.data->>'name' into vname from vendors v where v.id = p_data->>'vendorId';
  if vname is null then raise exception 'bad_vendor'; end if;
  d := private.pick(p_data, array['tail','airport','fbo','start','due','notes','services','ref'])
       || jsonb_build_object(
            'status', 'requested', 'createdAt', now(), 'updatedAt', now(),
            'requestedBy', coalesce(nullif(left(trim(coalesce(p_by, '')), 80), ''), 'Silver Air'),
            'photos', '[]'::jsonb,
            'activity', jsonb_build_array(private.act(me.o_role, me.o_vendor, p_by, 'status', 'Requested cleaning from ' || vname)));
  insert into jobs (id, vendor_id, data) values (new_id, p_data->>'vendorId', d);
  return new_id;
end $$;

create or replace function public.desk_job_update(p_code text, p_id text, p_patch jsonb, p_type text, p_text text, p_by text) returns void
language plpgsql security definer set search_path = public, extensions, private as $$
declare me record; j record; allowed text[]; d jsonb; newv text; cur text; st text;
begin
  select * into me from private.auth(p_code);
  select * into j from jobs where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  cur := j.data->>'status';
  st  := p_patch->>'status';
  if me.o_role = 'vendor' then
    if j.vendor_id is distinct from me.o_vendor then raise exception 'not_found'; end if;
    allowed := array['status','quote','acceptedAt','startedAt','completedAt','completionNote','declineReason','invoiceNo','invoiceAmount','invoicedAt'];
    if st is not null and st is distinct from cur and not (
         (cur = 'requested'   and st in ('accepted', 'declined')) or
         (cur = 'accepted'    and st = 'in_progress') or
         (cur = 'in_progress' and st = 'completed') or
         (cur = 'completed'   and st = 'invoiced')) then
      raise exception 'bad_transition';
    end if;
  else
    allowed := array['status','quote','acceptedAt','startedAt','completedAt','completionNote','declineReason','invoiceNo','invoiceAmount','invoicedAt',
                     'tail','airport','fbo','start','due','notes','services','vendorId'];
    if st is not null and st not in ('requested','accepted','in_progress','completed','invoiced','declined','cancelled') then
      raise exception 'bad_transition';
    end if;
  end if;
  d := j.data || private.pick(p_patch, allowed) || jsonb_build_object('updatedAt', now());
  newv := coalesce(d->>'vendorId', j.vendor_id);
  if newv is distinct from j.vendor_id and not exists (select 1 from vendors v where v.id = newv) then
    raise exception 'bad_vendor';
  end if;
  d := d - 'vendorId' - 'id';
  if coalesce(trim(p_text), '') <> '' then
    d := jsonb_set(d, '{activity}', private.last150(coalesce(d->'activity', '[]'::jsonb)
           || jsonb_build_array(private.act(me.o_role, me.o_vendor, p_by, p_type, p_text))));
  end if;
  update jobs set data = d, vendor_id = newv, updated_at = now() where id = p_id;
end $$;

create or replace function public.desk_job_delete(p_code text, p_id text) returns void
language plpgsql security definer set search_path = public, extensions, private as $$
declare me record;
begin
  select * into me from private.auth(p_code);
  if me.o_role <> 'admin' then raise exception 'not_allowed'; end if;
  delete from jobs where id = p_id;
end $$;

create or replace function public.desk_photo_add(p_code text, p_job text, p_kind text, p_data text, p_by text) returns text
language plpgsql security definer set search_path = public, extensions, private as $$
declare me record; j record; new_id text := gen_random_uuid()::text; d jsonb;
begin
  select * into me from private.auth(p_code);
  select * into j from jobs where id = p_job for update;
  if not found or (me.o_role = 'vendor' and j.vendor_id is distinct from me.o_vendor) then raise exception 'not_found'; end if;
  if j.data->>'status' = 'cancelled' then raise exception 'not_allowed'; end if;
  if p_kind not in ('before', 'after') then raise exception 'not_allowed'; end if;
  if p_data is null or p_data not like 'data:image/%' then raise exception 'not_allowed'; end if;
  if length(p_data) > 2500000 then raise exception 'photo_too_big'; end if;
  insert into photos (id, job_id, kind, data) values (new_id, p_job, p_kind, p_data);
  d := jsonb_set(j.data, '{photos}', coalesce(j.data->'photos', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
         'id', new_id, 'kind', p_kind, 'at', now(), 'by', nullif(left(trim(coalesce(p_by, '')), 80), ''))));
  d := jsonb_set(d, '{activity}', private.last150(coalesce(d->'activity', '[]'::jsonb)
         || jsonb_build_array(private.act(me.o_role, me.o_vendor, p_by, 'photo', 'Added a ' || p_kind || ' photo'))));
  update jobs set data = d || jsonb_build_object('updatedAt', now()), updated_at = now() where id = p_job;
  return new_id;
end $$;

create or replace function public.desk_photo_get(p_code text, p_id text) returns text
language plpgsql security definer set search_path = public, extensions, private as $$
declare me record; res text;
begin
  select * into me from private.auth(p_code);
  select p.data into res from photos p join jobs j on j.id = p.job_id
   where p.id = p_id and (me.o_role <> 'vendor' or j.vendor_id = me.o_vendor);
  if res is null then raise exception 'not_found'; end if;
  return res;
end $$;

create or replace function public.desk_fleet_save(p_code text, p_tail text, p_data jsonb) returns void
language plpgsql security definer set search_path = public, extensions, private as $$
declare me record; t text := upper(trim(coalesce(p_tail, '')));
begin
  select * into me from private.auth(p_code);
  if me.o_role <> 'admin' then raise exception 'not_allowed'; end if;
  if t !~ '^N[0-9A-Z]{1,5}$' then raise exception 'bad_tail'; end if;
  insert into fleet (tail, data)
  values (t, private.pick(p_data, array['type','model','year','serial','size','homeBase','notes','order']))
  on conflict (tail) do update set data = fleet.data || excluded.data;
end $$;

create or replace function public.desk_fleet_delete(p_code text, p_tail text) returns void
language plpgsql security definer set search_path = public, extensions, private as $$
declare me record;
begin
  select * into me from private.auth(p_code);
  if me.o_role <> 'admin' then raise exception 'not_allowed'; end if;
  delete from fleet where tail = p_tail;
end $$;

create or replace function public.desk_vendor_save(p_code text, p_id text, p_data jsonb) returns void
language plpgsql security definer set search_path = public, extensions, private as $$
declare me record;
begin
  select * into me from private.auth(p_code);
  if me.o_role <> 'admin' then raise exception 'not_allowed'; end if;
  if coalesce(p_id, '') !~ '^[a-z0-9-]{1,60}$' then raise exception 'bad_vendor'; end if;
  if coalesce(trim(p_data->>'name'), '') = '' then raise exception 'bad_vendor'; end if;
  insert into vendors (id, data)
  values (p_id, private.pick(p_data, array['name','legalName','contact','phone','email','address','airports']))
  on conflict (id) do update set data = vendors.data || excluded.data;
end $$;

create or replace function public.desk_vendor_delete(p_code text, p_id text) returns void
language plpgsql security definer set search_path = public, extensions, private as $$
declare me record;
begin
  select * into me from private.auth(p_code);
  if me.o_role <> 'admin' then raise exception 'not_allowed'; end if;
  delete from vendors where id = p_id;
  delete from private.codes where who = 'vendor:' || p_id;
end $$;

create or replace function public.desk_config_save(p_code text, p_data jsonb) returns void
language plpgsql security definer set search_path = public, extensions, private as $$
declare me record;
begin
  select * into me from private.auth(p_code);
  if me.o_role <> 'admin' then raise exception 'not_allowed'; end if;
  insert into config (id, data) values (1, private.pick(p_data, array['services','airports']))
  on conflict (id) do update set data = config.data || excluded.data;
end $$;

create or replace function public.desk_code_set(p_code text, p_who text, p_new text) returns void
language plpgsql security definer set search_path = public, extensions, private as $$
declare me record;
begin
  select * into me from private.whoami(p_code);
  if me.o_role <> 'admin' then raise exception 'not_allowed'; end if;
  if me.o_must and p_who <> 'admin' then raise exception 'must_change'; end if;
  if p_who not in ('admin', 'staff')
     and not (p_who like 'vendor:%' and exists (select 1 from vendors v where v.id = substr(p_who, 8))) then
    raise exception 'bad_vendor';
  end if;
  if length(coalesce(p_new, '')) < 6 then raise exception 'code_too_short'; end if;
  if p_new = 'ChangeMe123' then raise exception 'code_in_use'; end if;
  perform private.set_code(p_who, p_new);
end $$;

create or replace function public.desk_code_clear(p_code text, p_who text) returns void
language plpgsql security definer set search_path = public, extensions, private as $$
declare me record;
begin
  select * into me from private.auth(p_code);
  if me.o_role <> 'admin' then raise exception 'not_allowed'; end if;
  if p_who = 'admin' then raise exception 'not_allowed'; end if;
  delete from private.codes where who = p_who;
end $$;

-- Only the desk_* functions are callable from the app.
revoke execute on all functions in schema private from public;
revoke execute on function
  public.desk_load(text), public.desk_job_create(text, jsonb, text),
  public.desk_job_update(text, text, jsonb, text, text, text), public.desk_job_delete(text, text),
  public.desk_photo_add(text, text, text, text, text), public.desk_photo_get(text, text),
  public.desk_fleet_save(text, text, jsonb), public.desk_fleet_delete(text, text),
  public.desk_vendor_save(text, text, jsonb), public.desk_vendor_delete(text, text),
  public.desk_config_save(text, jsonb), public.desk_code_set(text, text, text), public.desk_code_clear(text, text)
from public;
grant execute on function
  public.desk_load(text), public.desk_job_create(text, jsonb, text),
  public.desk_job_update(text, text, jsonb, text, text, text), public.desk_job_delete(text, text),
  public.desk_photo_add(text, text, text, text, text), public.desk_photo_get(text, text),
  public.desk_fleet_save(text, text, jsonb), public.desk_fleet_delete(text, text),
  public.desk_vendor_save(text, text, jsonb), public.desk_vendor_delete(text, text),
  public.desk_config_save(text, jsonb), public.desk_code_set(text, text, text), public.desk_code_clear(text, text)
to anon, authenticated;

-- ---------- starting data ----------
-- Vendors, fleet and the first job were loaded once from the old claude.ai version and are not kept here (this repo is public).
-- Temporary admin passcode. The app makes you replace it the first time you sign in.
insert into private.codes (who, hash) values ('admin', extensions.crypt('ChangeMe123', extensions.gen_salt('bf', 8)))
on conflict (who) do nothing;
