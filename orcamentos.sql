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

alter table public.produtos add column if not exists tipo text not null default 'medida';  -- pronta | medida
alter table public.produtos add column if not exists cores text;
alter table public.produtos add column if not exists tamanhos jsonb;   -- linha pronta: [{"l":900,"a":2100,"preco":1475}] (mm)

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
drop function if exists public.catalogo_publico();
create or replace function public.catalogo_publico()
returns table (id uuid, tipo text, categoria text, modelo text, descricao text, foto_url text, cores text, tamanhos jsonb, ordem integer)
language sql stable security definer set search_path = public
as $$
  select id, tipo, categoria, modelo, descricao, foto_url, cores,
         (select jsonb_agg(jsonb_build_object('l', t->'l', 'a', t->'a')) from jsonb_array_elements(coalesce(p.tamanhos,'[]'::jsonb)) t),
         ordem
  from public.produtos p where ativo order by tipo, categoria, ordem, modelo;
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

-- 9) Linha pronta (catálogo Slim Modular da Pelé, preços do PDF) ------
insert into public.produtos (tipo, categoria, modelo, cores, foto_url, tamanhos, ordem)
select * from (values
  ('pronta','Porta de giro','Lambril com puxador','Branco e preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-02.jpg','[{"l": 900, "a": 2100, "preco": 1475}, {"l": 1000, "a": 2100, "preco": 1660}]'::jsonb,1),
  ('pronta','Veneziana','3 folhas com grade','Branco e preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-03.jpg','[{"l": 1000, "a": 1000, "preco": 640}, {"l": 1200, "a": 1000, "preco": 720}, {"l": 1500, "a": 1000, "preco": 810}]'::jsonb,2),
  ('pronta','Porta de correr','2 folhas móveis com persiana integrada automatizada','Branco e preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-04.jpg','[{"l": 1600, "a": 2200, "preco": 4585}, {"l": 2000, "a": 2200, "preco": 5160}]'::jsonb,3),
  ('pronta','Janela com persiana','2 folhas móveis com persiana integrada manual','Apenas preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-05.jpg','[{"l": 1200, "a": 1200, "preco": 1835}, {"l": 1500, "a": 1200, "preco": 2065}]'::jsonb,4),
  ('pronta','Maxim-ar','Com grade','Branco e preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-06.jpg','[{"l": 500, "a": 500, "preco": 260}, {"l": 600, "a": 600, "preco": 305}, {"l": 800, "a": 600, "preco": 273}]'::jsonb,5),
  ('pronta','Janela de correr','2 folhas sem grade','Branco e preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-07.jpg','[{"l": 1000, "a": 1000, "preco": 324}, {"l": 1200, "a": 1000, "preco": 353}, {"l": 1500, "a": 1000, "preco": 405}]'::jsonb,6),
  ('pronta','Maxim-ar','Sem grade','Branco e preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-08.jpg','[{"l": 500, "a": 500, "preco": 231}, {"l": 600, "a": 600, "preco": 268}, {"l": 800, "a": 600, "preco": 305}]'::jsonb,7),
  ('pronta','Veneziana','6 folhas com grade','Branco e preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-09.jpg','[{"l": 1200, "a": 1000, "preco": 880}, {"l": 1500, "a": 1000, "preco": 985}]'::jsonb,8),
  ('pronta','Veneziana','3 folhas sem grade','Branco e preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-10.jpg','[{"l": 1000, "a": 1000, "preco": 580}, {"l": 1200, "a": 1000, "preco": 650}, {"l": 1500, "a": 1000, "preco": 735}]'::jsonb,9),
  ('pronta','Veneziana','6 folhas sem grade','Branco e preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-11.jpg','[{"l": 1200, "a": 1000, "preco": 805}, {"l": 1500, "a": 1000, "preco": 900}]'::jsonb,10),
  ('pronta','Porta balcão','3 folhas móveis com veneziana','Branco e preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-12.jpg','[{"l": 1600, "a": 2100, "preco": 2530}]'::jsonb,11),
  ('pronta','Porta de correr','3 folhas móveis · vidro temperado','Branco e preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-13.jpg','[{"l": 1600, "a": 2100, "preco": 1955}, {"l": 2000, "a": 2100, "preco": 2335}]'::jsonb,12),
  ('pronta','Porta de giro','Postigo','Branco e preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-14.jpg','[{"l": 800, "a": 2100, "preco": 965}, {"l": 900, "a": 2100, "preco": 1080}]'::jsonb,13),
  ('pronta','Alçapão','Slim alumínio','Apenas preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-15.jpg','[{"l": 600, "a": 800, "preco": 268}]'::jsonb,14),
  ('pronta','Janela de correr','4 folhas sem grade','Branco e preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-16.jpg','[{"l": 1200, "a": 1000, "preco": 460}, {"l": 1500, "a": 1000, "preco": 510}]'::jsonb,15),
  ('pronta','Porta de giro','Lambril','Preto (branco só em 80 e 90 cm)','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-17.jpg','[{"l": 700, "a": 2100, "preco": 1185}, {"l": 800, "a": 2100, "preco": 1305}, {"l": 900, "a": 2100, "preco": 1425}, {"l": 1000, "a": 2100, "preco": 1570}]'::jsonb,16),
  ('pronta','Porta pivotante','Sem guarnição','Branco e preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-18.jpg','[{"l": 1050, "a": 2150, "preco": 3310}, {"l": 1150, "a": 2150, "preco": 3500}, {"l": 1250, "a": 2150, "preco": 3685}, {"l": 1086, "a": 2177, "preco": 3680}, {"l": 1186, "a": 2177, "preco": 3890}, {"l": 1286, "a": 2177, "preco": 4085}]'::jsonb,17),
  ('pronta','Veneziana','3 folhas móveis (linha 25)','Branco e preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-19.jpg','[{"l": 1500, "a": 1000, "preco": 1325}, {"l": 2000, "a": 1000, "preco": 1555}]'::jsonb,18),
  ('pronta','Porta de correr','2 folhas móveis · vidro temperado','Branco e preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-20.jpg','[{"l": 1600, "a": 2100, "preco": 1750}]'::jsonb,19),
  ('pronta','Porta de giro','Lambril com puxador e friso','Branco e preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-21.jpg','[{"l": 900, "a": 2100, "preco": 1630}, {"l": 1000, "a": 2100, "preco": 1760}]'::jsonb,20),
  ('pronta','Porta pivotante','Com friso, sem guarnição','Branco e preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-22.jpg','[{"l": 1050, "a": 2150, "preco": 3525}, {"l": 1150, "a": 2150, "preco": 3740}, {"l": 1250, "a": 2150, "preco": 3952}, {"l": 1086, "a": 2177, "preco": 3910}, {"l": 1186, "a": 2177, "preco": 4130}, {"l": 1286, "a": 2177, "preco": 4355}]'::jsonb,21),
  ('pronta','Porta de giro','Palheta total','Branco e preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-23.jpg','[{"l": 600, "a": 2100, "preco": 690}, {"l": 700, "a": 2100, "preco": 730}, {"l": 800, "a": 2100, "preco": 810}, {"l": 900, "a": 2100, "preco": 870}]'::jsonb,22),
  ('pronta','Janela de correr','2 folhas com grade','Branco e preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-24.jpg','[{"l": 1000, "a": 1000, "preco": 420}, {"l": 1200, "a": 1000, "preco": 470}, {"l": 1500, "a": 1000, "preco": 535}]'::jsonb,23),
  ('pronta','Porta de correr','4 folhas · vidro temperado','Branco e preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-25.jpg','[{"l": 2000, "a": 2100, "preco": 2105}]'::jsonb,24),
  ('pronta','Janela de correr','2 folhas móveis (linha 25)','Branco e preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-26.jpg','[{"l": 1000, "a": 1000, "preco": 790}, {"l": 1500, "a": 1000, "preco": 895}]'::jsonb,25),
  ('pronta','Janela de correr','4 folhas com grade','Branco e preto','https://mkticasas.github.io/crm-pele-esquadrias/assets/catalogo/linha-pronta-27.jpg','[{"l": 1200, "a": 1000, "preco": 575}, {"l": 1500, "a": 1000, "preco": 650}]'::jsonb,26)
) v(tipo, categoria, modelo, cores, foto_url, tamanhos, ordem)
where not exists (select 1 from public.produtos where tipo = 'pronta');

-- 10) Sob medida (cobrado por m² — o Pelé coloca preço, foto e ajusta a lista) --
insert into public.produtos (tipo, categoria, modelo, ordem)
select * from (values
  ('medida','Porta de entrada','Ripada',1), ('medida','Porta de entrada','Lisa',2), ('medida','Porta de entrada','Pivotante',3),
  ('medida','Porta de garagem','Basculante de lambril',1), ('medida','Porta de garagem','De correr de lambril',2),
  ('medida','Porta de correr','Gourmet (4 ou 5 folhas)',1),
  ('medida','Janela','De correr',1), ('medida','Janela','Maxim-ar',2), ('medida','Janela','Veneziana',3),
  ('medida','Box','Frontal de correr',1), ('medida','Box','De canto',2),
  ('medida','Fachada','Vidro incolor',1), ('medida','Fachada','Vidro espelhado',2), ('medida','Fachada','Pele de vidro',3)
) v(tipo, categoria, modelo, ordem)
where not exists (select 1 from public.produtos where tipo = 'medida');

-- Conferência
select (select count(*) from public.produtos where tipo='pronta') as linha_pronta,
       (select count(*) from public.produtos where tipo='medida') as sob_medida,
       (select count(*) from public.orcamentos) as orcamentos;
