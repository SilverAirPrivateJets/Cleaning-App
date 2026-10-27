-- =====================================================================
-- Silver Air Cleaning Desk: update 03
--   * invoice uploads (PDF or photo) after a job is completed
--   * billing question to ASM (owner or client) and the answer emailed back
--   * "new" and "updated" tracking for in app alerts
-- Run AFTER 01-setup.sql and 02-notifications.sql.
-- Paste into Supabase > SQL Editor > New query, then Run. Safe to run more than once.
-- =====================================================================

-- ---------- tables ----------
create table if not exists public.invoices (
  id         text primary key default gen_random_uuid()::text,
  job_id     text not null references public.jobs(id) on delete cascade,
  name       text not null,
  mime       text not null,
  data       text not null,
  created_at timestamptz not null default now()
);
create index if not exists invoices_job_idx on public.invoices(job_id);
alter table public.invoices enable row level security;
revoke all on public.invoices from anon, authenticated;

-- One private link per job for ASM to answer "who should be charged".
create table if not exists private.charge_tokens (
  token      text primary key,
  job_id     text not null references public.jobs(id) on delete cascade,
  created_at timestamptz not null default now(),
  used_at    timestamptz
);
create index if not exists charge_tokens_job_idx on private.charge_tokens(job_id);
alter table private.charge_tokens enable row level security;
revoke all on private.charge_tokens from public;

-- Who gets the billing emails. Change them later in the app under Settings.
insert into private.settings (key, value) values
  ('billing_email',       'asm@silverair.com'),
  ('charge_notify_email', 'austin.razor@silverair.com')
on conflict (key) do nothing;

-- ---------- helpers ----------
create or replace function private.act(p_role text, p_vendor text, p_by text, p_type text, p_text text) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select jsonb_build_object(
    'at', now(),
    'by', nullif(left(trim(coalesce(p_by, '')), 80), ''),
    'as', private.org(p_role, p_vendor),
    'type', case when p_type in ('status','comment','photo','edit','invoice','charge') then p_type else 'status' end,
    'text', left(coalesce(p_text, ''), 4000))
$$;

create or replace function private.setting(p_key text) returns text
language sql stable security definer set search_path = private as $$
  select s.value from private.settings s where s.key = p_key
$$;

create or replace function private.money(n numeric) returns text
language sql immutable as $$
  select '$' || to_char(coalesce(n, 0), 'FM999,999,990.00')
$$;

-- Vendors never see the billing decision.
create or replace function private.for_vendor(d jsonb) returns jsonb
language sql immutable as $$
  select (d - 'charge' - 'chargeRequestedAt') || jsonb_build_object('activity',
    coalesce((select jsonb_agg(a order by i)
                from jsonb_array_elements(coalesce(d->'activity', '[]'::jsonb)) with ordinality as t(a, i)
               where a->>'type' is distinct from 'charge'), '[]'::jsonb))
$$;

create or replace function private.new_charge_token(p_job text) returns text
language plpgsql security definer set search_path = public, extensions, private as $$
declare t text := encode(extensions.gen_random_bytes(24), 'hex');
begin
  delete from private.charge_tokens where job_id = p_job;
  insert into private.charge_tokens (token, job_id) values (t, p_job);
  return t;
end $$;

create or replace function private.charge_job(p_token text) returns text
language plpgsql security definer set search_path = public, private as $$
declare jid text;
begin
  select c.job_id into jid from private.charge_tokens c
   where c.token = p_token and c.created_at > now() - interval '120 days';
  if jid is null then
    perform pg_sleep(0.5);
    raise exception 'bad_link';
  end if;
  return jid;
end $$;

-- ---------- app functions (replaced or new) ----------
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
    'jobs', coalesce((select jsonb_agg(
                        (case when me.o_role = 'vendor' then private.for_vendor(j.data) else j.data end)
                        || jsonb_build_object('id', j.id, 'vendorId', j.vendor_id))
                      from jobs j where me.o_role <> 'vendor' or j.vendor_id = me.o_vendor), '[]'::jsonb),
    'codes', case when me.o_role = 'admin'
                  then coalesce((select jsonb_agg(c.who) from private.codes c), '[]'::jsonb)
                  else '[]'::jsonb end,
    'settings', case when me.o_role = 'admin'
                  then jsonb_build_object('billingEmail', private.setting('billing_email'),
                                          'chargeNotifyEmail', private.setting('charge_notify_email'))
                  else '{}'::jsonb end
  );
end $$;

-- Invoices now go through desk_invoice_add, so vendors can no longer jump to "invoiced" without a file.
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
    if p_type in ('invoice', 'charge') then raise exception 'not_allowed'; end if;
    allowed := array['status','quote','acceptedAt','startedAt','completedAt','completionNote','declineReason'];
    if st is not null and st is distinct from cur and not (
         (cur = 'requested'   and st in ('accepted', 'declined')) or
         (cur = 'accepted'    and st = 'in_progress') or
         (cur = 'in_progress' and st = 'completed')) then
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

-- Mark a job as seen by the caller's side (vendor or Silver Air). Used for "New" and "Updated" tags.
create or replace function public.desk_job_seen(p_code text, p_id text) returns void
language plpgsql security definer set search_path = public, extensions, private as $$
declare me record; side text;
begin
  select * into me from private.auth(p_code);
  side := case when me.o_role = 'vendor' then 'vendor' else 'silverair' end;
  update jobs
     set data = data || jsonb_build_object('seen', coalesce(data->'seen', '{}'::jsonb) || jsonb_build_object(side, now()))
   where id = p_id and (me.o_role <> 'vendor' or vendor_id = me.o_vendor);
end $$;

create or replace function public.desk_invoice_add(p_code text, p_job text, p_no text, p_amount numeric,
                                                   p_name text, p_mime text, p_data text, p_by text) returns text
language plpgsql security definer set search_path = public, extensions, private as $$
declare me record; j record; new_id text := gen_random_uuid()::text; d jsonb; replacing boolean;
begin
  select * into me from private.auth(p_code);
  select * into j from jobs where id = p_job for update;
  if not found or (me.o_role = 'vendor' and j.vendor_id is distinct from me.o_vendor) then raise exception 'not_found'; end if;
  if coalesce(j.data->>'status', '') not in ('completed', 'invoiced') then raise exception 'not_completed'; end if;
  if j.data->'charge'->>'to' is not null then raise exception 'already_billed'; end if;
  if coalesce(trim(p_no), '') = '' then raise exception 'invoice_no_missing'; end if;
  if p_amount is null or p_amount < 0 or p_amount > 10000000 then raise exception 'invoice_amount_bad'; end if;
  if p_mime not in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp') then raise exception 'invoice_type_bad'; end if;
  if p_data is null or p_data not like 'data:' || p_mime || ';base64,%' then raise exception 'invoice_type_bad'; end if;
  if length(p_data) > 11500000 then raise exception 'invoice_too_big'; end if;

  replacing := j.data ? 'invoiceFile';
  delete from invoices where job_id = p_job;
  insert into invoices (id, job_id, name, mime, data)
  values (new_id, p_job, left(coalesce(nullif(trim(p_name), ''), 'invoice'), 120), p_mime, p_data);

  d := j.data || jsonb_build_object(
    'status', 'invoiced',
    'invoiceNo', left(trim(p_no), 60),
    'invoiceAmount', p_amount,
    'invoicedAt', now(),
    'updatedAt', now(),
    'chargeRequestedAt', now(),
    'invoiceFile', jsonb_build_object('id', new_id, 'name', left(coalesce(nullif(trim(p_name), ''), 'invoice'), 120),
                                      'mime', p_mime, 'size', (length(p_data) * 3 / 4),
                                      'at', now(), 'by', nullif(left(trim(coalesce(p_by, '')), 80), '')));
  d := jsonb_set(d, '{activity}', private.last150(coalesce(d->'activity', '[]'::jsonb)
         || jsonb_build_array(private.act(me.o_role, me.o_vendor, p_by, 'invoice',
              (case when replacing then 'Replaced invoice with #' else 'Uploaded invoice #' end) || left(trim(p_no), 60) || ' · ' || private.money(p_amount)))));
  perform private.new_charge_token(p_job);
  update jobs set data = d, updated_at = now() where id = p_job;
  return new_id;
end $$;

create or replace function public.desk_invoice_get(p_code text, p_job text) returns jsonb
language plpgsql security definer set search_path = public, extensions, private as $$
declare me record; r record;
begin
  select * into me from private.auth(p_code);
  select i.name, i.mime, i.data into r from invoices i join jobs j on j.id = i.job_id
   where i.job_id = p_job and (me.o_role <> 'vendor' or j.vendor_id = me.o_vendor);
  if r.data is null then raise exception 'not_found'; end if;
  return jsonb_build_object('name', r.name, 'mime', r.mime, 'data', r.data);
end $$;

-- Silver Air sets or changes the charge from inside the app.
create or replace function public.desk_charge_set(p_code text, p_id text, p_to text, p_note text, p_by text) returns void
language plpgsql security definer set search_path = public, extensions, private as $$
declare me record; j record; d jsonb;
begin
  select * into me from private.auth(p_code);
  if me.o_role not in ('admin', 'staff') then raise exception 'not_allowed'; end if;
  if p_to not in ('owner', 'client') then raise exception 'bad_choice'; end if;
  select * into j from jobs where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  if not (j.data ? 'invoiceFile') then raise exception 'not_invoiced'; end if;
  d := j.data || jsonb_build_object('charge', jsonb_build_object(
         'to', p_to, 'note', nullif(left(trim(coalesce(p_note, '')), 1000), ''),
         'by', nullif(left(trim(coalesce(p_by, '')), 80), ''), 'at', now(), 'via', 'app'),
         'updatedAt', now());
  d := jsonb_set(d, '{activity}', private.last150(coalesce(d->'activity', '[]'::jsonb)
         || jsonb_build_array(private.act(me.o_role, me.o_vendor, p_by, 'charge',
              'Charge to ' || initcap(p_to) || coalesce('. ' || nullif(trim(coalesce(p_note, '')), ''), '')))));
  update private.charge_tokens set used_at = coalesce(used_at, now()) where job_id = p_id;
  update jobs set data = d, updated_at = now() where id = p_id;
end $$;

-- Ask ASM again (new link, new email). Only while nobody has decided yet.
create or replace function public.desk_charge_request(p_code text, p_id text, p_by text) returns void
language plpgsql security definer set search_path = public, extensions, private as $$
declare me record; j record; d jsonb;
begin
  select * into me from private.auth(p_code);
  if me.o_role not in ('admin', 'staff') then raise exception 'not_allowed'; end if;
  select * into j from jobs where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  if not (j.data ? 'invoiceFile') then raise exception 'not_invoiced'; end if;
  if j.data->'charge'->>'to' is not null then raise exception 'already_decided'; end if;
  perform private.new_charge_token(p_id);
  d := j.data || jsonb_build_object('chargeRequestedAt', now(), 'updatedAt', now());
  d := jsonb_set(d, '{activity}', private.last150(coalesce(d->'activity', '[]'::jsonb)
         || jsonb_build_array(private.act(me.o_role, me.o_vendor, p_by, 'charge', 'Sent the billing question to ASM again'))));
  update jobs set data = d, updated_at = now() where id = p_id;
end $$;

-- ---------- billing link functions (no passcode, the private link is the key) ----------
create or replace function public.desk_charge_info(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions, private as $$
declare jid text; j record;
begin
  jid := private.charge_job(p_token);
  select * into j from jobs where id = jid;
  return jsonb_build_object(
    'ref', j.data->>'ref', 'tail', j.data->>'tail',
    'aircraft', (select f.data->>'type' from fleet f where f.tail = j.data->>'tail'),
    'airport', j.data->>'airport', 'fbo', j.data->>'fbo',
    'start', j.data->>'start', 'due', j.data->>'due',
    'services', coalesce(j.data->'services', '[]'::jsonb),
    'vendor', (select v.data->>'name' from vendors v where v.id = j.vendor_id),
    'invoiceNo', j.data->>'invoiceNo', 'invoiceAmount', j.data->'invoiceAmount',
    'invoiceFile', (j.data->'invoiceFile') - 'by',
    'charge', j.data->'charge');
end $$;

create or replace function public.desk_charge_invoice(p_token text) returns jsonb
language plpgsql security definer set search_path = public, extensions, private as $$
declare jid text; r record;
begin
  jid := private.charge_job(p_token);
  select i.name, i.mime, i.data into r from invoices i where i.job_id = jid;
  if r.data is null then raise exception 'not_found'; end if;
  return jsonb_build_object('name', r.name, 'mime', r.mime, 'data', r.data);
end $$;

create or replace function public.desk_charge_decide(p_token text, p_to text, p_note text, p_by text) returns jsonb
language plpgsql security definer set search_path = public, extensions, private as $$
declare jid text; j record; d jsonb; who text;
begin
  jid := private.charge_job(p_token);
  if p_to not in ('owner', 'client') then raise exception 'bad_choice'; end if;
  who := nullif(left(trim(coalesce(p_by, '')), 80), '');
  if who is null then raise exception 'name_missing'; end if;
  select * into j from jobs where id = jid for update;
  if j.data->'charge'->>'to' is not null then raise exception 'already_decided'; end if;
  d := j.data || jsonb_build_object('charge', jsonb_build_object(
         'to', p_to, 'note', nullif(left(trim(coalesce(p_note, '')), 1000), ''),
         'by', who, 'at', now(), 'via', 'email'),
         'updatedAt', now());
  d := jsonb_set(d, '{activity}', private.last150(coalesce(d->'activity', '[]'::jsonb)
         || jsonb_build_array(private.act('staff', null, who || ' (ASM)', 'charge',
              'Charge to ' || initcap(p_to) || coalesce('. ' || nullif(trim(coalesce(p_note, '')), ''), '')))));
  update private.charge_tokens set used_at = now() where token = p_token;
  update jobs set data = d, updated_at = now() where id = jid;
  return d->'charge';
end $$;

-- ---------- settings ----------
create or replace function public.desk_settings_save(p_code text, p_billing text, p_notify text) returns void
language plpgsql security definer set search_path = public, extensions, private as $$
declare me record;
begin
  select * into me from private.auth(p_code);
  if me.o_role <> 'admin' then raise exception 'not_allowed'; end if;
  if coalesce(p_billing, '') !~ '^\s*[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+(\s*[,;]\s*[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+)*\s*$'
     or coalesce(p_notify, '') !~ '^\s*[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+(\s*[,;]\s*[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+)*\s*$' then
    raise exception 'bad_email';
  end if;
  insert into private.settings (key, value) values ('billing_email', trim(p_billing)), ('charge_notify_email', trim(p_notify))
  on conflict (key) do update set value = excluded.value;
end $$;

-- ---------- used by the email sender to attach the invoice (checks the shared secret) ----------
create or replace function public.desk_notify_invoice(p_secret text, p_job text) returns jsonb
language plpgsql security definer set search_path = public, extensions, private as $$
declare r record;
begin
  if p_secret is null or p_secret is distinct from private.setting('notify_secret') then
    perform pg_sleep(0.5);
    raise exception 'not_allowed';
  end if;
  select i.name, i.mime, i.data into r from invoices i where i.job_id = p_job;
  if r.data is null then return null; end if;
  return jsonb_build_object('name', r.name, 'mime', r.mime, 'data', r.data);
end $$;

-- ---------- email trigger: vendors, plus ASM and the billing contact ----------
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
  vname text;
  dest  text;
  tok   text;
begin
  -- vendor emails (unchanged rules)
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

  -- billing emails
  if tg_op = 'UPDATE' then
    if new.data->>'chargeRequestedAt' is not null
       and (new.data->>'chargeRequestedAt') is distinct from (old.data->>'chargeRequestedAt') then
      items := items || jsonb_build_array(jsonb_build_object('kind', 'invoice', 'to', 'billing_email'));
    end if;
    if new.data->'charge'->>'to' is not null
       and (new.data->'charge') is distinct from (old.data->'charge') then
      items := items || jsonb_build_array(jsonb_build_object('kind', 'charge', 'to', 'charge_notify_email'));
    end if;
  end if;

  if jsonb_array_length(items) = 0 then return new; end if;

  url := private.setting('notify_url');
  sec := private.setting('notify_secret');
  if url is null or sec is null then return new; end if;

  select f.data->>'type' into ac from public.fleet f where f.tail = new.data->>'tail';
  select x.data->>'name' into vname from public.vendors x where x.id = new.vendor_id;

  for it in select * from jsonb_array_elements(items) loop
    tok := null;
    if it ? 'vendor' then
      select x.id, x.data->>'name' as name, coalesce(x.data->>'email', '') as email
        into v from public.vendors x where x.id = it->>'vendor';
      if v.id is null then continue; end if;
      dest := v.email;
      vname := coalesce(vname, v.name);
    else
      dest := coalesce(private.setting(it->>'to'), '');
      if it->>'kind' = 'invoice' then
        select c.token into tok from private.charge_tokens c where c.job_id = new.id order by c.created_at desc limit 1;
      end if;
    end if;
    if trim(coalesce(dest, '')) = '' then continue; end if;
    msgs := msgs || jsonb_build_array(jsonb_build_object(
      'kind',          it->>'kind',
      'vendorName',    case when it ? 'vendor' then v.name else (select x.data->>'name' from public.vendors x where x.id = new.vendor_id) end,
      'emails',        dest,
      'jobId',         new.id,
      'ref',           new.data->>'ref',
      'tail',          new.data->>'tail',
      'aircraft',      ac,
      'airport',       new.data->>'airport',
      'fbo',           new.data->>'fbo',
      'start',         new.data->>'start',
      'due',           new.data->>'due',
      'services',      coalesce(new.data->'services', '[]'::jsonb),
      'notes',         new.data->>'notes',
      'status',        new.data->>'status',
      'by',            coalesce(new.data->'activity'->-1->>'by', new.data->>'requestedBy'),
      'message',       new.data->'activity'->-1->>'text',
      'invoiceNo',     new.data->>'invoiceNo',
      'invoiceAmount', new.data->'invoiceAmount',
      'invoiceName',   new.data->'invoiceFile'->>'name',
      'hasInvoice',    (new.data ? 'invoiceFile'),
      'token',         tok,
      'charge',        new.data->'charge'
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

-- ---------- permissions ----------
revoke execute on all functions in schema private from public;
revoke execute on function
  public.desk_job_seen(text, text),
  public.desk_invoice_add(text, text, text, numeric, text, text, text, text), public.desk_invoice_get(text, text),
  public.desk_charge_set(text, text, text, text, text), public.desk_charge_request(text, text, text),
  public.desk_charge_info(text), public.desk_charge_invoice(text), public.desk_charge_decide(text, text, text, text),
  public.desk_settings_save(text, text, text), public.desk_notify_invoice(text, text)
from public;
grant execute on function
  public.desk_job_seen(text, text),
  public.desk_invoice_add(text, text, text, numeric, text, text, text, text), public.desk_invoice_get(text, text),
  public.desk_charge_set(text, text, text, text, text), public.desk_charge_request(text, text, text),
  public.desk_charge_info(text), public.desk_charge_invoice(text), public.desk_charge_decide(text, text, text, text),
  public.desk_settings_save(text, text, text), public.desk_notify_invoice(text, text)
to anon, authenticated;
