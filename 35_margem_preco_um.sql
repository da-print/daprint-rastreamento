-- 35_margem_preco_um.sql  (idempotente / reaplicavel)
-- O preco de venda do vinculo cliente<->produto passa a ter UNIDADE DE MEDIDA
-- (rolo, milheiro, caixa, un...). A conversao p/ etiquetas usa a chave da ficha
-- (produto_conversoes). Default 'MI' (milheiro). Aditivo; nao toca producao.

alter table public.produto_preco_cliente
  add column if not exists preco_um text not null default 'MI';

-- =====================================================================
-- FIM DO 35_margem_preco_um.sql
-- =====================================================================
