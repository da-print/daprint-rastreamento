-- 33_margem_impostos.sql  (idempotente / reaplicavel)
-- Impostos/taxas CONFIGURAVEIS (inseriveis) por posicao + comissao no cliente-produto
-- + vendedor no cliente fiscal. Complementa o 32_margem.sql.
--
-- Margem (com nota):
--   subtotal1 = custo / (1 - Sigma aliquotas "apos custos")      (ex.: PIS/COFINS)
--   resultado = subtotal1 / (1 - Sigma aliquotas "no final")     (ICMS[UF] + IRRF + comissao + ...)
--   margem (lucro) = preco_cliente - resultado
--   IPI fica FORA (repassado). "Sem nota" zera os IMPOSTOS; a COMISSAO continua.
--
-- Depende de: 32_ (produto_preco_cliente, clientes_fiscal), 31_ (custo).

-- =====================================================================
-- A) IMPOSTO_TAXA: lista configuravel de impostos/taxas fixos (%), por posicao.
--    O ICMS NAO entra aqui (vem por UF do cliente, tabela imposto_uf, posicao "final").
-- =====================================================================
create table if not exists public.imposto_taxa (
  id            bigint generated always as identity primary key,
  nome          text not null,
  aliquota      numeric not null default 0,         -- %
  posicao       text not null default 'final',       -- 'apos' (apos custos) | 'final'
  ativo         boolean not null default true,
  ordem         integer not null default 1,
  atualizado_em timestamptz not null default now()
);

-- =====================================================================
-- B) COMISSAO no vinculo cliente-produto (entra no bloco "no final").
-- =====================================================================
alter table public.produto_preco_cliente add column if not exists comissao_pct numeric not null default 0;

-- =====================================================================
-- C) VENDEDOR na base de clientes fiscais.
-- =====================================================================
alter table public.clientes_fiscal add column if not exists vendedor text;

-- =====================================================================
-- D) RLS: sensivel -> leitura/escrita gestor/editor.
-- =====================================================================
alter table public.imposto_taxa enable row level security;
drop policy if exists it_select on public.imposto_taxa;
drop policy if exists it_write  on public.imposto_taxa;
create policy it_select on public.imposto_taxa for select to authenticated using (posso_editar());
create policy it_write  on public.imposto_taxa for all    to authenticated using (posso_editar()) with check (posso_editar());

-- =====================================================================
-- FIM DO 33_margem_impostos.sql
-- =====================================================================
