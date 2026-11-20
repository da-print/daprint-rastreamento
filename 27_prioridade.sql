-- 27_prioridade.sql  (idempotente / reaplicavel)
-- Prioridade do item na fila do painel. Flag por item (pedido+item+entrega), na
-- mesma tabela 'overrides' onde ja fica a ordem do arraste. Itens com prioridade
-- vao para o TOPO da fila da maquina; entre eles, a ordem do arraste vale.
-- Marcacao so no app p/ gestor/editor (a escrita de overrides ja e posso_editar()).
--
-- Depende de: tabela overrides (camada manual/foto).

alter table public.overrides
  add column if not exists prioridade boolean not null default false;
comment on column public.overrides.prioridade is 'Item marcado como prioridade na fila (vai para o topo da maquina dele). Gestor/editor.';

-- =====================================================================
-- FIM DO 27_prioridade.sql
-- =====================================================================
