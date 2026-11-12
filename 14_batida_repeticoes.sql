-- 14_batida_repeticoes.sql
-- Repeticoes da faca por etapa (usado SO nas etapas de batida / modo "unidade").
-- Numero de imagens da faca = carreiras x repeticoes.
-- Numero de batidas a rodar = etiquetas / imagens  (ex.: 1000 et, 2 carreiras x 2 rep = 4 imagens -> 250 batidas).
-- A velocidade do grupo BATIDA ja esta em batidas/hora (golpes/h).
-- Idempotente / reaplicavel. NAO altera os demais grupos.

alter table public.produto_etapas
  add column if not exists repeticoes integer not null default 1;

-- Garante valor minimo valido em linhas existentes (default ja cobre, mas por seguranca):
update public.produto_etapas set repeticoes = 1 where repeticoes is null or repeticoes < 1;
