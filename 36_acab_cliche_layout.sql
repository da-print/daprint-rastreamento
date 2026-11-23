-- 36_acab_cliche_layout.sql  (idempotente / reaplicavel)
-- Layout de CLICHE proprio por ACABAMENTO que gera clichê (cold stamping / verniz
-- localizado). Em item digital/sem impressao nao ha clichê de cor, mas o stamping
-- (feito na corte Brotech/Vorei) gera clichê, cujo tamanho depende de quantas imagens
-- rodam lado a lado / ao redor NAQUELE acabamento — pode diferir do layout da impressao.
-- Campos nullable: se vazios, o motor cai p/ a geometria do produto (carreiras/repeticoes/
-- espaco/esqueleto). Aditivo; nao toca producao.

alter table public.produto_acabamentos
  add column if not exists cliche_carreiras  integer,
  add column if not exists cliche_repeticoes integer,
  add column if not exists cliche_espaco     numeric,
  add column if not exists cliche_esqueleto  numeric;

-- =====================================================================
-- FIM DO 36_acab_cliche_layout.sql
-- =====================================================================
