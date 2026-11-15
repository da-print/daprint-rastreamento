-- 20_materias_primas.sql  (idempotente / reaplicavel)
-- Cadastro de materias-primas (dado-mestre) + vinculo na ficha do produto +
-- view auxiliar p/ os KPIs de m2 por materia-prima.
--
-- Conceitos:
--  * valor_m2  = valor BRUTO por m2 (o que o usuario digita).
--  * icms_pct / ipi_pct = aliquotas; o "quanto gastou" de cada imposto e
--    calculado no FRONT sobre o custo bruto consumido (m2 x valor_m2).
--  * largura: a largura EFETIVA usada na conversao linear<->m2 continua sendo a
--    do PRODUTO (produtos.larg_substrato). A MP guarda a largura so como PADRAO
--    (a ficha preenche larg_substrato a partir dela ao selecionar; editavel).
--
-- Depende de: 13_producao_apontamentos.sql (tabelas produtos/ordens, helpers
--             posso_editar()/sou_gestor()).

-- =====================================================================
-- A) TABELA materias_primas
-- =====================================================================
create table if not exists public.materias_primas (
  id            bigint generated always as identity primary key,
  nome          text not null unique,
  largura_mm    numeric,                         -- largura padrao do substrato (mm)
  valor_m2      numeric not null default 0,      -- valor BRUTO por m2
  icms_pct      numeric not null default 0,      -- aliquota ICMS (%)
  ipi_pct       numeric not null default 0,      -- aliquota IPI (%)
  ativo         boolean not null default true,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
comment on table public.materias_primas is 'Materias-primas (dado-mestre). valor_m2 = bruto; icms/ipi = aliquotas (% aplicado sobre o bruto no front).';

-- =====================================================================
-- B) VINCULO NA FICHA DO PRODUTO (soft; nao quebra produtos sem MP)
-- =====================================================================
alter table public.produtos
  add column if not exists materia_prima_id bigint;

-- FK com ON DELETE SET NULL: excluir uma MP so desvincula, nao apaga produto.
do $$ begin
  if not exists (
    select 1 from pg_constraint where conname = 'produtos_materia_prima_id_fkey'
  ) then
    alter table public.produtos
      add constraint produtos_materia_prima_id_fkey
      foreign key (materia_prima_id)
      references public.materias_primas(id) on delete set null;
  end if;
end $$;

-- =====================================================================
-- C) RLS: leitura p/ todos autenticados; escrita p/ gestor/editor
-- =====================================================================
alter table public.materias_primas enable row level security;

drop policy if exists mp_select on public.materias_primas;
create policy mp_select on public.materias_primas
  for select to authenticated using (true);

drop policy if exists mp_write on public.materias_primas;
create policy mp_write on public.materias_primas
  for all to authenticated using (posso_editar()) with check (posso_editar());

-- =====================================================================
-- D) VIEW auxiliar p/ KPI: materia-prima por OS (pedido+item)
--    Exposta por OS para o front cruzar com a v_operacao_kpi (chave pedido+item).
--    largura_mm = largura EFETIVA do produto (larg_substrato) usada no m2;
--    cai p/ a largura padrao da MP so quando o produto nao tem larg_substrato.
-- =====================================================================
create or replace view public.v_ordem_materia with (security_invoker = true) as
select
  o.pedido,
  o.item,
  o.produto_codigo,
  coalesce(pr.larg_substrato, mp.largura_mm)      as largura_mm,
  pr.materia_prima_id,
  mp.nome        as mp_nome,
  mp.valor_m2    as mp_valor_m2,
  mp.icms_pct    as mp_icms_pct,
  mp.ipi_pct     as mp_ipi_pct
from public.ordens o
left join public.produtos pr on pr.codigo_pa = o.produto_codigo
left join public.materias_primas mp on mp.id = pr.materia_prima_id;

grant select on public.v_ordem_materia to authenticated;
