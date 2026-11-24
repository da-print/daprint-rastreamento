-- 37_pedidos_preco_margem.sql  (idempotente / reaplicavel)
-- MARGEM REAL fase 1 — a planilha de pedidos passa a trazer PRECO UNITARIO, COMISSAO
-- e EMISSAO por pedido+item.
--
-- SEGURANCA: preco e comissao sao SENSIVEIS (como todo o custo/preco, restrito a
-- gestor/editor). `pedidos_abertos` e lida por TODOS os papeis (operador/visualizador),
-- entao estes dados NAO ficam la — ficam em tabela PROPRIA `pedidos_precos` com RLS
-- `posso_editar()`. Preenchida no upload por uma RPC ADITIVA; a RPC critica
-- `upload_pedidos_abertos` fica INTOCADA. Aditivo; nao toca producao/apontamento.

create table if not exists public.pedidos_precos (
  pedido        integer not null,
  item          integer not null,
  preco_un      numeric,
  comissao_pct  numeric,
  emissao       date,
  uf            text,           -- UF de destino (estado do cliente) p/ o ICMS do pedido
  atualizado_em timestamptz not null default now(),
  primary key (pedido, item)
);
alter table public.pedidos_precos add column if not exists uf text;

alter table public.pedidos_precos enable row level security;
drop policy if exists pp_select on public.pedidos_precos;
drop policy if exists pp_write  on public.pedidos_precos;
create policy pp_select on public.pedidos_precos for select to authenticated using (posso_editar());
create policy pp_write  on public.pedidos_precos for all    to authenticated using (posso_editar()) with check (posso_editar());

-- Substitui o conteudo (foto a cada upload) por pedido+item. So gestor.
create or replace function public.atualizar_pedidos_extra(linhas jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare n integer;
begin
  if not public.sou_gestor() then
    raise exception 'Apenas o gestor pode subir planilhas.';
  end if;
  delete from public.pedidos_precos where true;
  insert into public.pedidos_precos (pedido, item, preco_un, comissao_pct, emissao, uf, atualizado_em)
  select x.pedido, x.item, x.preco_un, x.comissao_pct, x.emissao, x.uf, now()
  from jsonb_to_recordset(linhas) as x(
    pedido integer, item integer, preco_un numeric, comissao_pct numeric, emissao date, uf text
  )
  on conflict (pedido, item) do update
    set preco_un=excluded.preco_un, comissao_pct=excluded.comissao_pct,
        emissao=excluded.emissao, uf=excluded.uf, atualizado_em=now();
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public.atualizar_pedidos_extra(jsonb) from anon;
grant execute on function public.atualizar_pedidos_extra(jsonb) to authenticated;

-- =====================================================================
-- FIM DO 37_pedidos_preco_margem.sql
-- =====================================================================
