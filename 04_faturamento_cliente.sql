-- =====================================================================
-- D&A - Rastreamento de Pedidos | 04_faturamento_cliente.sql (v2)
-- Adiciona cliente_codigo E produto_desc na tabela faturamento, para que:
--   - o RLS do representante filtre por vendedor (via cliente_codigo)
--   - o painel exiba cliente e produto dos itens que ja sairam de
--     pedidos_abertos (itens 100% faturados)
--
-- COMO USAR: rodar INTEIRO no SQL Editor, DEPOIS de 01 e 02.
-- Seguro rodar de novo (idempotente): usa IF NOT EXISTS e OR REPLACE.
-- =====================================================================

-- 1) novas colunas
alter table public.faturamento
  add column if not exists cliente_codigo text;
alter table public.faturamento
  add column if not exists produto_desc text;

-- 2) upload de faturamento preenchendo cliente e produto
create or replace function public.upload_faturamento(linhas jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  if not public.sou_gestor() then
    raise exception 'Apenas o gestor pode subir planilhas.';
  end if;

  delete from public.faturamento where true;

  insert into public.faturamento
    (pedido, item, numero_nf, pedido_cliente, cliente_codigo, produto_desc, atualizado_em)
  select
    x.pedido, x.item, x.numero_nf, x.pedido_cliente, x.cliente_codigo,
    x.produto_desc, now()
  from jsonb_to_recordset(linhas) as x(
    pedido integer, item integer, numero_nf text, pedido_cliente text,
    cliente_codigo text, produto_desc text
  );

  get diagnostics n = row_count;
  return n;
end;
$$;

revoke all on function public.upload_faturamento(jsonb) from anon;
grant execute on function public.upload_faturamento(jsonb) to authenticated;

-- =====================================================================
-- FIM DO 04_faturamento_cliente.sql (v2)
-- =====================================================================
