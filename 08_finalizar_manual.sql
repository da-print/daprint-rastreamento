-- =====================================================================
-- D&A - Rastreamento de Pedidos | 08_finalizar_manual.sql
-- Adiciona a marcacao de "finalizado manualmente" no override.
-- Quando o usuario finaliza um item na ultima etapa, ele sai da maquina
-- e passa a contar como "Aguardando faturamento", mesmo que a planilha do
-- ERP ainda o traga como em producao (a marcacao manual vence).
--
-- COMO USAR: rodar no SQL Editor, DEPOIS de 01..07.
-- =====================================================================

-- Coluna que marca finalizacao manual (data em que foi finalizado)
alter table public.overrides
  add column if not exists finalizado_em date;

comment on column public.overrides.finalizado_em is
  'Data em que o item foi finalizado manualmente pelo usuario. '
  'Quando preenchido, o item conta como Aguardando Faturamento e sai da '
  'maquina, mesmo que a planilha ainda o traga em producao. '
  'E descartado quando o item aparece no faturamento (limpeza por carencia).';

-- =====================================================================
-- FIM DO 08_finalizar_manual.sql
-- =====================================================================
