-- =====================================================================
-- iMarcas · CRM do cliente — estrutura do banco
-- Rodar no SQL Editor do Supabase NOVO do cliente (1 projeto por cliente).
-- Antes de rodar: troque pele@teste.com.br (seção 5) pelo e-mail de quem administra o CRM.
-- Pode rodar de novo sem duplicar nada.
-- =====================================================================

-- 1) Vendedores (login pelo Supabase Auth) ------------------------------
create table if not exists public.sellers (
  id                uuid primary key default gen_random_uuid(),
  auth_user_id      uuid unique references auth.users(id) on delete set null,
  name              text not null,
  nickname          text,
  phone             text,
  email             text,
  role              text default 'Vendedor',
  goal              numeric,
  color             text default '#3d7eff',
  status            text not null default 'active',
  can_see_all_leads boolean not null default false,
  created_at        timestamptz not null default now()
);

-- 2) Captação: links que recebem leads de formulário/anúncio -----------
create table if not exists public.webhooks (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  origin          text,
  distribution    text not null default 'roundrobin',   -- roundrobin | fixed
  fixed_seller_id uuid references public.sellers(id) on delete set null,
  active          boolean not null default true,
  token           text not null unique default replace(gen_random_uuid()::text,'-',''),
  field_map       jsonb,
  leads_count     integer not null default 0,
  last_seller_id  uuid,
  created_at      timestamptz not null default now()
);

-- 3) Leads -------------------------------------------------------------
create table if not exists public.leads (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  phone         text,
  email         text,
  source        text,
  origin        text,
  campaign      text,
  seller_id     uuid references public.sellers(id) on delete set null,
  stage         text not null default 'new',
  value         numeric,
  temperature   text,
  notes         text,
  reminder_date timestamptz,
  reminder_note text,
  webhook_token text,
  created_at    timestamptz not null default now()
);
create index if not exists leads_seller_idx on public.leads(seller_id);
create index if not exists leads_stage_idx  on public.leads(stage);

-- 4) Chat de suporte (fica desligado no modelo iMarcas; tabela mantida) --
create table if not exists public.support_messages (
  id          uuid primary key default gen_random_uuid(),
  sender      text,
  sender_name text,
  message     text,
  created_at  timestamptz not null default now()
);

-- 5) Segurança: só o admin e vendedores ATIVOS leem e gravam ----------
-- (qualquer outro login criado com a chave pública não enxerga nada)
create table if not exists public.crm_config (
  id          integer primary key default 1 check (id = 1),
  admin_email text not null
);
insert into public.crm_config (id, admin_email) values (1, lower('pele@teste.com.br'))
on conflict (id) do update set admin_email = excluded.admin_email;

create or replace function public.crm_eh_membro()
returns boolean
language sql stable security definer set search_path = public
as $$
  select lower(coalesce(auth.jwt()->>'email','')) = (select admin_email from public.crm_config where id = 1)
      or exists (select 1 from public.sellers where auth_user_id = auth.uid() and status = 'active');
$$;

alter table public.crm_config       enable row level security;
alter table public.sellers          enable row level security;
alter table public.webhooks         enable row level security;
alter table public.leads            enable row level security;
alter table public.support_messages enable row level security;

drop policy if exists "logados sellers" on public.sellers;
drop policy if exists "membros sellers" on public.sellers;
create policy "membros sellers" on public.sellers for all to authenticated
  using (public.crm_eh_membro() or auth_user_id = auth.uid())
  with check (public.crm_eh_membro());

drop policy if exists "logados webhooks" on public.webhooks;
drop policy if exists "membros webhooks" on public.webhooks;
create policy "membros webhooks" on public.webhooks for all to authenticated
  using (public.crm_eh_membro()) with check (public.crm_eh_membro());

drop policy if exists "logados leads" on public.leads;
drop policy if exists "membros leads" on public.leads;
create policy "membros leads" on public.leads for all to authenticated
  using (public.crm_eh_membro()) with check (public.crm_eh_membro());

drop policy if exists "logados suporte" on public.support_messages;
drop policy if exists "membros suporte" on public.support_messages;
create policy "membros suporte" on public.support_messages for all to authenticated
  using (public.crm_eh_membro()) with check (public.crm_eh_membro());

-- 6) Pipeline atualiza sozinho (sem F5) --------------------------------
do $$
begin
  alter publication supabase_realtime add table public.leads;
exception when duplicate_object then null;
end $$;

-- Conferência: deve listar as 4 tabelas
select table_name from information_schema.tables
where table_schema = 'public' and table_name in ('sellers','webhooks','leads','support_messages')
order by table_name;
