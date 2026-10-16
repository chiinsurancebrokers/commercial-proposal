-- Commercial Proposal Studio: full database schema.
-- Mirrors the live Ashlar-Proposal-Studio public schema (read-only dump, 2026-10-16),
-- so the clone starts with every table, constraint, index, RPC and private bucket the app uses.
-- Run once in Supabase Dashboard > SQL Editor on the NEW project. Idempotent where possible.

-- ---------------------------------------------------------------- tables
create table if not exists public.provider_documents (
    id text primary key,
    provider text not null,
    product text not null,
    version text not null,
    doc_type text not null,
    original_filename text not null,
    stored_path text not null,
    sha256 text not null,
    effective_from text,
    effective_to text,
    notes text,
    uploaded_at timestamptz not null default now(),
    extracted_text text,
    extracted_at timestamptz,
    extraction_error text,
    constraint provider_documents_unique_source unique (provider, product, version, doc_type, sha256)
);
create index if not exists provider_documents_lookup_idx on public.provider_documents (provider, product, version);

create table if not exists public.analysis_cases (
    id text primary key,
    case_reference text,
    client_name text,
    client_profile text,
    client_priorities text,
    report_language text not null default 'English',
    results_json jsonb not null default '[]'::jsonb,
    case_chat_json jsonb not null default '[]'::jsonb,
    client_analysis_json jsonb,
    provider_count integer not null default 0,
    plan_summary text,
    status text not null default 'analyzed',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    client_sex text,
    client_age integer,
    source text not null default 'manual',
    client_email text,
    client_country text,
    consent_to_retain boolean not null default false,
    second_opinion_requested boolean not null default false,
    uploaded_file_path text,
    uploaded_file_mime text,
    retention_until timestamptz,
    summary_sent_at timestamptz,
    broker_notified_at timestamptz,
    uploaded_wording_path text,
    uploaded_wording_mime text,
    uploaded_invoice_path text,
    uploaded_invoice_mime text,
    household_members_json jsonb not null default '[]'::jsonb,
    constraint analysis_cases_source_chk
        check (source = any (array['website_form','manual','portal','api'])) not valid,
    constraint analysis_cases_website_consent_chk
        check (source <> 'website_form' or consent_to_retain = true) not valid
);
create index if not exists analysis_cases_client_idx on public.analysis_cases (client_name);
create index if not exists analysis_cases_updated_idx on public.analysis_cases (updated_at desc);
create index if not exists analysis_cases_source_idx on public.analysis_cases (source);
create index if not exists analysis_cases_retention_idx on public.analysis_cases (retention_until) where retention_until is not null;

create table if not exists public.analysis_jobs (
    id text primary key,
    case_id text not null references public.analysis_cases(id) on delete cascade,
    job_type text not null
        check (job_type in ('client_report','hal_chat','policy_review','case_analysis')),
    status text not null default 'pending'
        check (status in ('pending','running','completed','failed')),
    progress_stage text,
    request_json jsonb not null default '{}'::jsonb,
    result_json jsonb,
    error_message text,
    attempts integer not null default 0,
    worker_id text,
    locked_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);
create index if not exists analysis_jobs_case_idx on public.analysis_jobs (case_id, created_at desc);
create index if not exists analysis_jobs_status_created_idx on public.analysis_jobs (status, created_at);

create table if not exists public.hal_sessions (
    session_reference text primary key,
    analysis_case_id text references public.analysis_cases(id) on delete set null,
    consent_to_retain boolean not null default false,
    consent_to_transmit boolean not null default false,
    status text not null default 'active' check (status in ('active','submitted','closed')),
    state_json jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    expires_at timestamptz
);
create index if not exists hal_sessions_analysis_case_idx on public.hal_sessions (analysis_case_id);

create table if not exists public.hal_session_messages (
    id bigint generated always as identity primary key,
    session_reference text not null references public.hal_sessions(session_reference) on delete cascade,
    role text not null check (role in ('user','assistant','system')),
    content text not null,
    created_at timestamptz not null default now()
);
create index if not exists hal_session_messages_session_created_idx
    on public.hal_session_messages (session_reference, created_at);

create table if not exists public.hal_fact_finds (
    session_reference text primary key references public.hal_sessions(session_reference) on delete cascade,
    facts_json jsonb not null default '{}'::jsonb,
    review_status text not null default 'needs_review'
        check (review_status in ('needs_review','reviewed','submitted')),
    reviewed_at timestamptz,
    updated_at timestamptz not null default now()
);

create table if not exists public.hal_household_members (
    id bigint generated always as identity primary key,
    session_reference text not null references public.hal_sessions(session_reference) on delete cascade,
    member_id text not null,
    relationship text not null check (relationship in ('primary','spouse','partner','child','other')),
    age integer check (age >= 0 and age <= 120),
    sex text check (sex in ('female','male','unspecified')),
    requirements_json jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (session_reference, member_id)
);
create index if not exists hal_household_members_session_idx on public.hal_household_members (session_reference);

create table if not exists public.hal_saved_quotes (
    reference text primary key check (reference ~ '^HAL-[0-9]{8}-[A-Z0-9]{8}$'),
    created_at timestamptz not null default now(),
    valid_until timestamptz not null,
    status text not null default 'saved'
        check (status in ('saved','proposal_requested','expired','deleted')),
    language text not null default 'en' check (language in ('en','el')),
    journey text not null default 'ipmi',
    applicant_name text,
    email text not null,
    dob_hash text not null,
    consent_to_retain boolean not null default false check (consent_to_retain),
    state_json jsonb not null default '{}'::jsonb,
    quote_json jsonb not null default '{}'::jsonb,
    total_premium numeric(12,2),
    currency text,
    lead_reference text,
    retrieve_count integer not null default 0,
    failed_attempts integer not null default 0,
    locked_until timestamptz,
    last_retrieved_at timestamptz,
    followup_consent boolean not null default false,
    unsubscribed_at timestamptz,
    residency_purpose boolean not null default false
);
create index if not exists hal_saved_quotes_email_idx on public.hal_saved_quotes (lower(email));
comment on table public.hal_saved_quotes is
    'HAL quotes saved with client consent; retrieved by reference + date of birth (stored only as a salted hash). Server-side access only.';

create table if not exists public.hal_followups (
    id bigint generated always as identity primary key,
    reference text not null references public.hal_saved_quotes(reference) on delete cascade,
    kind text not null check (kind in ('checkin','expiry','annual_review')),
    scheduled_for timestamptz not null,
    status text not null default 'scheduled'
        check (status in ('scheduled','sending','sent','cancelled','failed','skipped')),
    attempts integer not null default 0,
    claimed_at timestamptz,
    sent_at timestamptz,
    message_id text,
    subject text,
    writer text,
    error text,
    created_at timestamptz not null default now(),
    unique (reference, kind)
);
create index if not exists hal_followups_due_idx on public.hal_followups (scheduled_for) where status = 'scheduled';

create table if not exists public.hal_leads (
    id uuid primary key default gen_random_uuid(),
    reference text not null unique,
    kind text not null check (kind in ('proposal','comparison')),
    created_at timestamptz not null default now(),
    email text not null,
    name text,
    phone text,
    insurance_interest text,
    payload jsonb not null default '{}'::jsonb,
    delivery_status text not null default 'pending' check (delivery_status in ('pending','sent','failed')),
    delivery_error text,
    transport text,
    delivered_at timestamptz
);
create index if not exists hal_leads_created_at_idx on public.hal_leads (created_at desc);
create index if not exists hal_leads_undelivered_idx on public.hal_leads (delivery_status) where delivery_status <> 'sent';
comment on table public.hal_leads is
    'HAL proposal/comparison requests, saved before email delivery. delivery_status <> ''sent'' means the adviser email failed: follow up manually. Server-side access only.';

-- ---------------------------------------------------------------- RLS + grants (server-side service_role only)
do $$
declare t text;
begin
  foreach t in array array['provider_documents','analysis_cases','analysis_jobs','hal_sessions',
      'hal_session_messages','hal_fact_finds','hal_household_members','hal_saved_quotes',
      'hal_followups','hal_leads']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('grant all on table public.%I to service_role', t);
    execute format('revoke all on table public.%I from anon, authenticated', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- functions
create or replace function public.claim_analysis_job(p_worker_id text)
returns setof public.analysis_jobs
language plpgsql security definer set search_path to 'public' as $function$
declare
    v_id text;
begin
    select id into v_id
    from public.analysis_jobs
    where status = 'pending'
    order by created_at asc
    for update skip locked
    limit 1;

    if v_id is null then
        return;
    end if;

    return query
    update public.analysis_jobs
       set status = 'running',
           worker_id = p_worker_id,
           locked_at = now(),
           attempts = attempts + 1,
           progress_stage = 'Worker started',
           updated_at = now()
     where id = v_id
     returning *;
end;
$function$;

create or replace function public.claim_hal_followups(p_limit integer default 20)
returns setof public.hal_followups
language sql set search_path to 'public' as $function$
  update public.hal_followups f
     set status = 'sending', attempts = f.attempts + 1, claimed_at = now()
   where f.id in (
     select id from public.hal_followups
      where (status = 'scheduled' and scheduled_for <= now())
         or (status = 'sending' and claimed_at < now() - interval '30 minutes' and attempts < 3)
      order by scheduled_for
      limit greatest(1, least(p_limit, 100))
      for update skip locked)
  returning f.*;
$function$;

create or replace function public.hal_create_session(
    p_session_reference text, p_consent_to_retain boolean default false, p_consent_to_transmit boolean default false)
returns public.hal_sessions
language plpgsql security definer set search_path to 'public' as $function$
declare v_row public.hal_sessions;
begin
  insert into public.hal_sessions(session_reference, consent_to_retain, consent_to_transmit)
  values (p_session_reference, p_consent_to_retain, p_consent_to_transmit)
  returning * into v_row;
  return v_row;
end;
$function$;

create or replace function public.hal_delete_session(p_session_reference text)
returns boolean
language plpgsql security definer set search_path to 'public' as $function$
begin
  delete from public.hal_sessions where session_reference=p_session_reference;
  return found;
end;
$function$;

create or replace function public.hal_get_session(p_session_reference text)
returns table(session_reference text, consent_to_retain boolean, consent_to_transmit boolean,
              created_at timestamptz, updated_at timestamptz, state_json jsonb, transcript jsonb)
language sql security definer set search_path to 'public' as $function$
  select s.session_reference, s.consent_to_retain, s.consent_to_transmit, s.created_at, s.updated_at, s.state_json,
         coalesce((select jsonb_agg(jsonb_build_object('role',m.role,'content',m.content,'created_at',m.created_at) order by m.created_at,m.id)
                   from public.hal_session_messages m where m.session_reference=s.session_reference), '[]'::jsonb)
  from public.hal_sessions s where s.session_reference=p_session_reference and s.consent_to_retain=true;
$function$;

create or replace function public.hal_save_turn(
    p_session_reference text, p_state jsonb, p_user_message text, p_assistant_message text)
returns public.hal_sessions
language plpgsql security definer set search_path to 'public' as $function$
declare v_row public.hal_sessions;
begin
  update public.hal_sessions
     set state_json = coalesce(p_state, '{}'::jsonb), updated_at = now()
   where session_reference = p_session_reference and consent_to_retain = true
   returning * into v_row;
  if not found then raise exception 'Session is not retained or does not exist.' using errcode='P0002'; end if;

  insert into public.hal_session_messages(session_reference, role, content)
  values (p_session_reference, 'user', left(p_user_message,4000));
  if coalesce(p_assistant_message,'') <> '' then
    insert into public.hal_session_messages(session_reference, role, content)
    values (p_session_reference, 'assistant', left(p_assistant_message,8000));
  end if;
  return v_row;
end;
$function$;

do $$
declare f text;
begin
  foreach f in array array[
      'claim_analysis_job(text)','claim_hal_followups(integer)',
      'hal_create_session(text,boolean,boolean)','hal_delete_session(text)',
      'hal_get_session(text)','hal_save_turn(text,jsonb,text,text)']
  loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

-- ---------------------------------------------------------------- private storage buckets
insert into storage.buckets (id, name, public)
values ('provider-library','provider-library', false),
       ('client-policy-uploads','client-policy-uploads', false)
on conflict (id) do nothing;
