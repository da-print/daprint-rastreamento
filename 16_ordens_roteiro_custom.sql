-- 16_ordens_roteiro_custom.sql  (idempotente / reaplicavel)
-- Marca uma OS cujo roteiro foi customizado pontualmente (ex.: rodou numa maquina
-- fora da ficha). Quando true, a materializacao automatica (salvar ficha / upload)
-- NAO sobrescreve as operacoes daquela OS. Nao afeta a ficha do produto.

alter table public.ordens
  add column if not exists roteiro_custom boolean not null default false;
