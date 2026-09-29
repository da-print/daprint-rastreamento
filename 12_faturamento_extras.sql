-- =====================================================================
-- D&A - Rastreamento de Pedidos | 12_faturamento_extras.sql
-- Adiciona quantidade faturada, data de emissao da NF e transportadora
-- na tabela faturamento, e recria as funcoes que dependem disso.
--
-- COMO USAR: rodar no SQL Editor, DEPOIS de 10 e 11.
-- =====================================================================

-- 1) novas colunas
alter table public.faturamento add column if not exists qtde numeric;
alter table public.faturamento add column if not exists emissao date;
alter table public.faturamento add column if not exists transportadora text;

-- 2) upload de faturamento preenchendo os novos campos
create or replace function public.upload_faturamento(linhas jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not public.sou_gestor() then raise exception 'Apenas o gestor pode subir planilhas.'; end if;
  delete from public.faturamento where true;
  insert into public.faturamento
    (pedido, item, nf_key, numero_nf, pedido_cliente, cliente_codigo, produto_desc,
     qtde, emissao, transportadora, atualizado_em)
  select
    x.pedido, x.item, x.nf_key, x.numero_nf, x.pedido_cliente, x.cliente_codigo, x.produto_desc,
    x.qtde, x.emissao, x.transportadora, now()
  from jsonb_to_recordset(linhas) as x(
    pedido integer, item integer, nf_key text, numero_nf text, pedido_cliente text,
    cliente_codigo text, produto_desc text, qtde numeric, emissao date, transportadora text
  );
  get diagnostics n = row_count;
  return n;
end; $$;
revoke all on function public.upload_faturamento(jsonb) from anon;
grant execute on function public.upload_faturamento(jsonb) to authenticated;

-- 3) rastreio com os novos campos (qtde, emissao, transportadora, un.)
-- Precisa DROP porque mudamos os campos de retorno (Postgres nao deixa
-- trocar o formato de saida com CREATE OR REPLACE).
drop function if exists public.rastrear_pedido(text);
create function public.rastrear_pedido(termo text)
returns table (
  pedido integer,
  item integer,
  cliente_nome text,
  produto_desc text,
  status text,
  previsao_entrega date,
  pedido_cliente text,
  numero_nf text,
  qtde numeric,
  unidade text,
  data_evento date,
  transportadora text
)
language sql stable security definer set search_path = public
as $$
  with termo_norm as (
    select trim(termo) as t, regexp_replace(coalesce(termo,''), '\D', '', 'g') as t_dig
  ),
  parcelas_abertas as (
    select
      pa.pedido, pa.item, pa.entrega_key, pa.cliente_codigo, pa.cliente_nome_origem,
      pa.produto, pa.produto_desc, pa.entrega, pa.status_producao_origem, pa.pedido_cliente,
      pa.saldo, pa.um,
      (select o.finalizado_em from public.overrides o
        where o.pedido=pa.pedido and o.item=pa.item and o.entrega_key=pa.entrega_key limit 1) as finalizado_em,
      exists (select 1 from public.pcp p where p.pedido=pa.pedido and p.item=pa.item) as em_pcp
    from public.pedidos_abertos pa
  ),
  linhas as (
    select
      pa.pedido, pa.item,
      coalesce(c.nome_reduzido, pa.cliente_nome_origem) as cliente_nome,
      pa.produto_desc,
      case
        when pa.finalizado_em is not null then 'Finalizado, aguardando faturamento'
        when left(coalesce(pa.produto,''),2)='PA' and pa.em_pcp then 'Em produção'
        when left(coalesce(pa.produto,''),2)='PA' and pa.status_producao_origem='FINALIZADA'
             then 'Finalizado, aguardando faturamento'
        else 'Em produção'
      end as status,
      pa.entrega as previsao_entrega,
      nullif(coalesce(pa.pedido_cliente,''),'') as pedido_cliente,
      null::text as numero_nf,
      pa.saldo as qtde,
      pa.um as unidade,
      pa.entrega as data_evento,
      null::text as transportadora,
      c.cnpj_digitos
    from parcelas_abertas pa
    left join public.clientes c on c.codigo = pa.cliente_codigo
    union all
    select
      f.pedido, f.item,
      coalesce(c.nome_reduzido, null) as cliente_nome,
      f.produto_desc,
      'Faturado' as status,
      null::date as previsao_entrega,
      nullif(coalesce(f.pedido_cliente,''),'') as pedido_cliente,
      f.numero_nf,
      f.qtde,
      null::text as unidade,
      f.emissao as data_evento,
      f.transportadora,
      c.cnpj_digitos
    from public.faturamento f
    left join public.clientes c on c.codigo = f.cliente_codigo
  )
  select
    l.pedido, l.item, l.cliente_nome, l.produto_desc, l.status,
    l.previsao_entrega, l.pedido_cliente, l.numero_nf,
    l.qtde, l.unidade, l.data_evento, l.transportadora
  from linhas l, termo_norm tn
  where
    (tn.t ~ '^\d{1,6}$' and l.pedido::text = tn.t)
    or (l.pedido_cliente = tn.t)
    or (tn.t_dig <> '' and regexp_replace(coalesce(l.pedido_cliente,''),'\D','','g') = tn.t_dig)
    or (tn.t_dig <> '' and l.cnpj_digitos = tn.t_dig)
  order by l.pedido, l.item;
$$;
grant execute on function public.rastrear_pedido(text) to anon;

-- =====================================================================
-- FIM DO 12_faturamento_extras.sql
-- =====================================================================
