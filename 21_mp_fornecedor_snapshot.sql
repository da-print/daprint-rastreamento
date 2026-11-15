-- 21_mp_fornecedor_snapshot.sql  (idempotente / reaplicavel)
-- (1) Fornecedor no cadastro de materia-prima (mesma MP com fornecedores/precos diferentes).
-- (2) SNAPSHOT do custo de MP na OS (ordens): "ciclo fechado" — a OS congela valor/ICMS/IPI/
--     fornecedor/largura quando a MP e DEFINIDA; mudar o cadastro depois so vale p/ OS novas,
--     e OS finalizada nunca muda (nada re-copia).
-- (3) v_ordem_materia passa a LER o snapshot da OS, caindo p/ o cadastro atual nas OS antigas
--     (sem snapshot).
-- Depende de: 20_materias_primas.sql.

-- =====================================================================
-- A) FORNECEDOR + unicidade por (nome, fornecedor)
-- =====================================================================
alter table public.materias_primas
  add column if not exists fornecedor text;

-- a unicidade deixa de ser so por nome e passa a ser (nome, fornecedor):
alter table public.materias_primas drop constraint if exists materias_primas_nome_key;
create unique index if not exists materias_primas_nome_forn_uidx
  on public.materias_primas (nome, coalesce(fornecedor, ''));

-- =====================================================================
-- B) SNAPSHOT de MP na OS (congelado; preenchido pelo app ao definir a MP)
-- =====================================================================
alter table public.ordens
  add column if not exists mp_id          bigint,
  add column if not exists mp_nome        text,
  add column if not exists mp_fornecedor  text,
  add column if not exists mp_valor_m2    numeric,
  add column if not exists mp_icms_pct    numeric,
  add column if not exists mp_ipi_pct     numeric,
  add column if not exists mp_largura_mm  numeric;   -- largura usada no m2 (override por OS)

-- =====================================================================
-- C) VIEW: snapshot da OS com fallback p/ o cadastro atual (OS antigas)
-- =====================================================================
-- DROP antes de recriar: a nova view insere a coluna mp_fornecedor no meio da
-- lista que o 20_ ja criou, e CREATE OR REPLACE nao permite reordenar/renomear
-- colunas (ERRO 42P16). O drop e seguro: nenhuma outra view depende desta.
drop view if exists public.v_ordem_materia;
create view public.v_ordem_materia with (security_invoker = true) as
select
  o.pedido,
  o.item,
  o.produto_codigo,
  coalesce(o.mp_largura_mm, pr.larg_substrato, mp.largura_mm) as largura_mm,
  coalesce(o.mp_id, pr.materia_prima_id)                      as materia_prima_id,
  coalesce(o.mp_nome, mp.nome)                                as mp_nome,
  coalesce(o.mp_fornecedor, mp.fornecedor)                    as mp_fornecedor,
  coalesce(o.mp_valor_m2, mp.valor_m2)                        as mp_valor_m2,
  coalesce(o.mp_icms_pct, mp.icms_pct)                        as mp_icms_pct,
  coalesce(o.mp_ipi_pct, mp.ipi_pct)                          as mp_ipi_pct
from public.ordens o
left join public.produtos pr on pr.codigo_pa = o.produto_codigo
left join public.materias_primas mp on mp.id = coalesce(o.mp_id, pr.materia_prima_id);

grant select on public.v_ordem_materia to authenticated;
