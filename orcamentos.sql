-- =====================================================================
-- CRM Pelé Esquadrias — módulo de ORÇAMENTOS
-- Rodar no SQL Editor do Supabase da Pelé (depois do schema.sql).
-- Pode rodar de novo sem duplicar nada.
-- =====================================================================

-- 1) Catálogo de produtos (o que aparece no orçamento e no site) -------
create table if not exists public.produtos (
  id         uuid primary key default gen_random_uuid(),
  categoria  text not null,                 -- ex.: Porta de entrada
  modelo     text not null,                 -- ex.: Ripada
  descricao  text,
  foto_url   text,
  preco_m2   numeric,                       -- preço por m² (opcional)
  preco_un   numeric,                       -- preço por unidade (opcional)
  ativo      boolean not null default true,
  ordem      integer not null default 0,
  created_at timestamptz not null default now()
);

-- 2) Orçamentos ---------------------------------------------------------
create table if not exists public.orcamentos (
  id                    uuid primary key default gen_random_uuid(),
  numero                serial,
  lead_id               uuid references public.leads(id) on delete set null,
  cliente_nome          text not null,
  cliente_telefone      text,
  cliente_email         text,
  cidade                text,
  etapa_obra            text,
  status                text not null default 'rascunho',  -- aguardando | rascunho | enviado | aprovado | recusado
  origem                text not null default 'crm',       -- crm | site
  desconto              numeric not null default 0,
  ajuste_aproveitamento numeric not null default 0,
  ajuste_obs            text,
  condicoes_pagamento   text,
  prazo_entrega         text,
  validade_dias         integer not null default 15,
  observacoes           text,
  total                 numeric not null default 0,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
alter table public.orcamentos add column if not exists desconto_tipo text not null default 'valor';  -- valor | pct
alter table public.orcamentos add column if not exists mostrar_valor_item boolean not null default true;
create index if not exists orcamentos_lead_idx   on public.orcamentos(lead_id);
create index if not exists orcamentos_status_idx on public.orcamentos(status);

-- 3) Itens do orçamento -------------------------------------------------
create table if not exists public.orcamento_itens (
  id           uuid primary key default gen_random_uuid(),
  orcamento_id uuid not null references public.orcamentos(id) on delete cascade,
  produto_id   uuid references public.produtos(id) on delete set null,
  categoria    text,
  modelo       text,
  foto_url     text,
  largura      numeric,          -- metros
  altura       numeric,          -- metros
  quantidade   integer not null default 1,
  vidro        text,
  obs          text,
  modo_preco   text not null default 'm2',  -- m2 | un
  preco        numeric,                     -- preço do m² ou da unidade
  ordem        integer not null default 0
);
create index if not exists orcamento_itens_orc_idx on public.orcamento_itens(orcamento_id);

-- 4) Segurança: só admin e vendedores ativos ----------------------------
alter table public.produtos        enable row level security;
alter table public.orcamentos      enable row level security;
alter table public.orcamento_itens enable row level security;

drop policy if exists "membros produtos" on public.produtos;
create policy "membros produtos" on public.produtos for all to authenticated
  using (public.crm_eh_membro()) with check (public.crm_eh_membro());

-- o site de auto-orçamento lê só o catálogo ativo (sem preço — ver view abaixo)
drop policy if exists "membros orcamentos" on public.orcamentos;
create policy "membros orcamentos" on public.orcamentos for all to authenticated
  using (public.crm_eh_membro()) with check (public.crm_eh_membro());

drop policy if exists "membros orcamento_itens" on public.orcamento_itens;
create policy "membros orcamento_itens" on public.orcamento_itens for all to authenticated
  using (public.crm_eh_membro()) with check (public.crm_eh_membro());

-- 5) Catálogo público para o site (sem preços) --------------------------
create or replace function public.catalogo_publico()
returns table (id uuid, categoria text, modelo text, descricao text, foto_url text, ordem integer)
language sql stable security definer set search_path = public
as $$
  select id, categoria, modelo, descricao, foto_url, ordem
  from public.produtos where ativo order by categoria, ordem, modelo;
$$;
revoke all on function public.catalogo_publico() from public;
grant execute on function public.catalogo_publico() to anon, authenticated;

-- 6) Pedido vindo do site: cria lead + orçamento + itens de uma vez -----
-- O site só consegue isso: não lê nem altera mais nada do CRM.
create or replace function public.criar_pedido_orcamento(p jsonb)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_nome   text := left(trim(coalesce(p->>'nome','')), 120);
  v_tel    text := left(regexp_replace(coalesce(p->>'telefone',''), '\D', '', 'g'), 20);
  v_itens  jsonb := coalesce(p->'itens','[]'::jsonb);
  v_seller uuid;
  v_lead   uuid;
  v_orc    uuid;
  v_num    integer;
  v_resumo text;
  it       jsonb;
  i        integer := 0;
begin
  if v_nome = '' or length(v_tel) < 10 then raise exception 'Nome e WhatsApp são obrigatórios'; end if;
  if jsonb_typeof(v_itens) <> 'array' or jsonb_array_length(v_itens) = 0 then raise exception 'Escolha pelo menos um item'; end if;
  if jsonb_array_length(v_itens) > 60 then raise exception 'Itens demais'; end if;

  select id into v_seller from public.sellers where status = 'active' order by created_at limit 1;

  select string_agg(coalesce(x->>'quantidade','1') || 'x ' || coalesce(x->>'categoria','') || ' ' || coalesce(x->>'modelo','')
                    || ' (' || coalesce(x->>'largura','?') || ' x ' || coalesce(x->>'altura','?') || ' m)', E'\n')
    into v_resumo from jsonb_array_elements(v_itens) x;

  insert into public.leads (name, phone, email, source, origin, seller_id, stage, notes)
  values (v_nome, v_tel, nullif(left(p->>'email',120),''), 'Site · Monte seu orçamento', 'Site', v_seller, 'new',
          'Pedido pelo site' || coalesce(' · Etapa da obra: ' || nullif(p->>'etapa_obra',''), '')
          || coalesce(' · ' || nullif(p->>'cidade',''), '') || E'\n' || coalesce(v_resumo,''))
  returning id into v_lead;

  insert into public.orcamentos (lead_id, cliente_nome, cliente_telefone, cliente_email, cidade, etapa_obra, status, origem, observacoes)
  values (v_lead, v_nome, v_tel, nullif(left(p->>'email',120),''), left(p->>'cidade',120), left(p->>'etapa_obra',80),
          'aguardando', 'site', left(p->>'observacoes',1000))
  returning id, numero into v_orc, v_num;

  for it in select * from jsonb_array_elements(v_itens) loop
    i := i + 1;
    insert into public.orcamento_itens (orcamento_id, produto_id, categoria, modelo, foto_url, largura, altura, quantidade, vidro, obs, ordem)
    values (v_orc,
            case when (it->>'produto_id') ~ '^[0-9a-f-]{36}$' then (it->>'produto_id')::uuid end,
            left(it->>'categoria',80), left(it->>'modelo',80), left(it->>'foto_url',500),
            nullif(replace(it->>'largura',',','.'),'')::numeric, nullif(replace(it->>'altura',',','.'),'')::numeric,
            greatest(1, least(99, coalesce(nullif(it->>'quantidade','')::int, 1))),
            left(it->>'vidro',80), left(it->>'obs',300), i);
  end loop;

  return v_num;
end $$;
revoke all on function public.criar_pedido_orcamento(jsonb) from public;
grant execute on function public.criar_pedido_orcamento(jsonb) to anon, authenticated;

-- 7) Fotos do catálogo (bucket público, só membros enviam) --------------
insert into storage.buckets (id, name, public) values ('catalogo', 'catalogo', true)
on conflict (id) do nothing;
drop policy if exists "membros enviam fotos do catalogo" on storage.objects;
create policy "membros enviam fotos do catalogo" on storage.objects for all to authenticated
  using (bucket_id = 'catalogo' and public.crm_eh_membro())
  with check (bucket_id = 'catalogo' and public.crm_eh_membro());

-- 8) Atualização em tempo real da aba Orçamentos ------------------------
do $$ begin
  alter publication supabase_realtime add table public.orcamentos;
exception when duplicate_object then null; end $$;

-- 9) Catálogo inicial de exemplo (o Pelé troca pelos modelos dele) ------
insert into public.produtos (categoria, modelo, ordem)
select * from (values
  ('Porta de entrada','Ripada',1), ('Porta de entrada','Lisa',2), ('Porta de entrada','Pivotante',3),
  ('Porta de garagem','Basculante de lambril',1), ('Porta de garagem','De correr de lambril',2),
  ('Porta de correr','2 folhas',1), ('Porta de correr','4 folhas',2), ('Porta de correr','5 folhas (gourmet)',3),
  ('Janela','De correr 2 folhas',1), ('Janela','Maxim-ar (banheiro)',2), ('Janela','Veneziana (quarto)',3),
  ('Box','Frontal de correr',1), ('Box','De canto',2),
  ('Fachada','Vidro incolor',1), ('Fachada','Vidro espelhado',2), ('Fachada','Pele de vidro',3)
) v(categoria, modelo, ordem)
where not exists (select 1 from public.produtos);

-- Conferência
select (select count(*) from public.produtos) as produtos,
       (select count(*) from public.orcamentos) as orcamentos;
