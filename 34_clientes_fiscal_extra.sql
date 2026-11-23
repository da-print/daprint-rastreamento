-- 34_clientes_fiscal_extra.sql  (idempotente / reaplicavel)
-- Amplia a base fiscal de clientes com os campos extras da planilha do usuario:
-- nome reduzido, familia de cliente e CNPJ. (nome=Razao Social, uf e vendedor ja
-- existem do 32_/33_.) Tudo aditivo e nullable; nao toca producao/painel.

alter table public.clientes_fiscal
  add column if not exists nome_reduzido text,
  add column if not exists familia       text,
  add column if not exists cnpj          text;

-- =====================================================================
-- FIM DO 34_clientes_fiscal_extra.sql
-- =====================================================================
