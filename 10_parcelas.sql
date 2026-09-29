-- =====================================================================
-- D&A - Rastreamento de Pedidos | 10_parcelas.sql
-- Muda a granularidade de ITEM para PARCELA, tratando:
--   - pedidos com entrega parcelada (mesmo pedido+item, varias datas)
--   - faturamento parcial (mesmo pedido+item, varias NFs)
--
-- Novas chaves:
--   pedidos_abertos: (pedido, item, entrega_key)
--     entrega_key = entrega como texto 'YYYY-MM-DD', ou 'SEM-DATA' quando nula
--   faturamento: (pedido, item, nf_key)
--     nf_key = numero_nf, ou 'SEM-NF' quando nulo
--   overrides: (pedido, item, entrega_key)  -> override POR PARCELA
--
-- COMO USAR: rodar no SQL Editor, DEPOIS de 01..09.
-- Este arquivo recria as tabelas afetadas e suas funcoes. Como os dados
-- sao reenviados por upload diariamente, recriar as tabelas nao perde nada
-- que nao seja reposto no proximo upload. Os OVERRIDES sao preservados
-- (migramos a tabela adicionando a coluna, sem apagar).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) PEDIDOS ABERTOS: nova chave com entrega_key
-- ---------------------------------------------------------------------
drop table if exists public.pedidos_abertos cascade;
create table public.pedidos_abertos (
  pedido integer not null,
  item integer not null,
  entrega_key text not null default 'SEM-DATA',
  cliente_codigo text,
  cliente_nome_origem text,
  produto text,
  produto_desc text,
  saldo numeric,
  um text,
  saldo2 numeric,
  um2 text,
  entrega date,
  status_producao_origem text,
  ml numeric,
  pedido_cliente text,
  atualizado_em timestamptz not null default now(),
  primary key (pedido, item, entrega_key)
);

-- ---------------------------------------------------------------------
-- 2) FATURAMENTO: nova chave com nf_key
-- ---------------------------------------------------------------------
drop table if exists public.faturamento cascade;
create table public.faturamento (
  pedido integer not null,
  item integer not null,
  nf_key text not null default 'SEM-NF',
  numero_nf text,
  pedido_cliente text,
  cliente_codigo text,
  produto_desc text,
  atualizado_em timestamptz not null default now(),
  primary key (pedido, item, nf_key)
);

-- ---------------------------------------------------------------------
-- 3) OVERRIDES: adicionar entrega_key a chave (override POR PARCELA)
--    Preservamos os overrides existentes: os antigos ficam com
--    entrega_key = 'SEM-DATA'. Recriamos a PK.
-- ---------------------------------------------------------------------
alter table public.overrides
  add column if not exists entrega_key text not null default 'SEM-DATA';

alter table public.overrides drop constraint if exists overrides_pkey;
alter table public.overrides add primary key (pedido, item, entrega_key);

-- ---------------------------------------------------------------------
-- 4) Reindexar
-- ---------------------------------------------------------------------
create index if not exists idx_pedidos_pi on public.pedidos_abertos(pedido, item);
create index if not exists idx_fat_pi on public.faturamento(pedido, item);
create index if not exists idx_fat_cliente on public.faturamento(cliente_codigo);

-- ---------------------------------------------------------------------
-- 5) RLS nas tabelas recriadas (reaplicar politicas por papel)
-- ---------------------------------------------------------------------
alter table public.pedidos_abertos enable row level security;
alter table public.faturamento enable row level security;

-- pedidos: leitura por papel (mesma logica do 03/07, agora por parcela)
create policy "pedidos: leitura por papel" on public.pedidos_abertos
for select using (
  public.ve_tudo()
  or (public.meu_papel() = 'representante' and public.cliente_e_meu(cliente_codigo))
  or (public.meu_papel() = 'visualizador_maquina' and public.item_na_minha_maquina(pedido, item))
);
create policy "pedidos: gestor escreve" on public.pedidos_abertos
  for all using (public.sou_gestor()) with check (public.sou_gestor());

-- faturamento: leitura por papel
create policy "faturamento: leitura por papel" on public.faturamento
for select using (
  public.ve_tudo()
  or (public.meu_papel() = 'representante' and public.cliente_e_meu(cliente_codigo))
);
create policy "faturamento: gestor escreve" on public.faturamento
  for all using (public.sou_gestor()) with check (public.sou_gestor());

-- ---------------------------------------------------------------------
-- 6) Funcoes de upload atualizadas (por parcela)
-- ---------------------------------------------------------------------
create or replace function public.upload_pedidos_abertos(linhas jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not public.sou_gestor() then raise exception 'Apenas o gestor pode subir planilhas.'; end if;
  delete from public.pedidos_abertos where true;
  insert into public.pedidos_abertos
    (pedido, item, entrega_key, cliente_codigo, cliente_nome_origem, produto, produto_desc,
     saldo, um, saldo2, um2, entrega, status_producao_origem, ml, pedido_cliente, atualizado_em)
  select
    x.pedido, x.item, x.entrega_key, x.cliente_codigo, x.cliente_nome_origem, x.produto,
    x.produto_desc, x.saldo, x.um, x.saldo2, x.um2, x.entrega,
    x.status_producao_origem, x.ml, x.pedido_cliente, now()
  from jsonb_to_recordset(linhas) as x(
    pedido integer, item integer, entrega_key text, cliente_codigo text, cliente_nome_origem text,
    produto text, produto_desc text, saldo numeric, um text, saldo2 numeric,
    um2 text, entrega date, status_producao_origem text, ml numeric, pedido_cliente text
  );
  get diagnostics n = row_count;
  return n;
end; $$;
revoke all on function public.upload_pedidos_abertos(jsonb) from anon;
grant execute on function public.upload_pedidos_abertos(jsonb) to authenticated;

create or replace function public.upload_faturamento(linhas jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not public.sou_gestor() then raise exception 'Apenas o gestor pode subir planilhas.'; end if;
  delete from public.faturamento where true;
  insert into public.faturamento
    (pedido, item, nf_key, numero_nf, pedido_cliente, cliente_codigo, produto_desc, atualizado_em)
  select
    x.pedido, x.item, x.nf_key, x.numero_nf, x.pedido_cliente, x.cliente_codigo, x.produto_desc, now()
  from jsonb_to_recordset(linhas) as x(
    pedido integer, item integer, nf_key text, numero_nf text, pedido_cliente text,
    cliente_codigo text, produto_desc text
  );
  get diagnostics n = row_count;
  return n;
end; $$;
revoke all on function public.upload_faturamento(jsonb) from anon;
grant execute on function public.upload_faturamento(jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- 7) Limpeza de overrides (agora por parcela: pedido+item+entrega_key)
-- ---------------------------------------------------------------------
create or replace function public.limpar_overrides()
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not public.sou_gestor() then raise exception 'Apenas o gestor pode executar a limpeza.'; end if;

  -- reapareceu: zera ausencia (parcela existe em pedidos ou item faturado)
  update public.overrides o set ausente_desde = null
  where o.ausente_desde is not null
    and (
      exists (select 1 from public.pedidos_abertos p
              where p.pedido=o.pedido and p.item=o.item and p.entrega_key=o.entrega_key)
      or exists (select 1 from public.faturamento f
              where f.pedido=o.pedido and f.item=o.item)
    );

  -- sumiu agora: marca a data
  update public.overrides o set ausente_desde = current_date
  where o.ausente_desde is null
    and not exists (select 1 from public.pedidos_abertos p
              where p.pedido=o.pedido and p.item=o.item and p.entrega_key=o.entrega_key)
    and not exists (select 1 from public.faturamento f
              where f.pedido=o.pedido and f.item=o.item);

  -- ausente ha mais de 45 dias: exclui
  delete from public.overrides o
  where o.ausente_desde is not null
    and o.ausente_desde < current_date - interval '45 days';

  get diagnostics n = row_count;
  return n;
end; $$;
revoke all on function public.limpar_overrides() from anon;
grant execute on function public.limpar_overrides() to authenticated;

-- =====================================================================
-- FIM DO 10_parcelas.sql
-- A funcao rastrear_pedido e recriada no 11 (por parcela).
-- =====================================================================
