-- =====================================================================
-- D&A - Rastreamento de Pedidos | 11_rastreio_parcelas.sql
-- Recria rastrear_pedido para o modelo por PARCELA.
-- Cada parcela (pedido+item+entrega) e cada NF aparece como uma linha,
-- com seu proprio status. Assim o cliente ve "parte faturada, parte em
-- producao".
--
-- COMO USAR: rodar no SQL Editor, DEPOIS de 10_parcelas.sql.
-- =====================================================================

create or replace function public.rastrear_pedido(termo text)
returns table (
  pedido integer,
  item integer,
  cliente_nome text,
  produto_desc text,
  status text,
  previsao_entrega date,
  pedido_cliente text,
  numero_nf text
)
language sql stable security definer set search_path = public
as $$
  with termo_norm as (
    select trim(termo) as t, regexp_replace(coalesce(termo,''), '\D', '', 'g') as t_dig
  ),
  -- parcelas em aberto (cada linha de pedidos_abertos e uma parcela)
  parcelas_abertas as (
    select
      pa.pedido, pa.item, pa.entrega_key, pa.cliente_codigo, pa.cliente_nome_origem,
      pa.produto, pa.produto_desc, pa.entrega, pa.status_producao_origem, pa.pedido_cliente,
      -- override desta parcela (se houver)
      (select o.grupo from public.overrides o
        where o.pedido=pa.pedido and o.item=pa.item and o.entrega_key=pa.entrega_key
          and o.grupo is not null limit 1) as grupo_override,
      (select o.finalizado_em from public.overrides o
        where o.pedido=pa.pedido and o.item=pa.item and o.entrega_key=pa.entrega_key limit 1) as finalizado_em,
      exists (select 1 from public.pcp p where p.pedido=pa.pedido and p.item=pa.item) as em_pcp
    from public.pedidos_abertos pa
  ),
  -- NFs faturadas (cada linha de faturamento e uma NF)
  nfs as (
    select f.pedido, f.item, f.numero_nf, f.cliente_codigo, f.produto_desc, f.pedido_cliente
    from public.faturamento f
  ),
  -- linhas de exibicao: parcelas abertas + NFs
  linhas as (
    -- parcelas ainda em aberto
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
      c.cnpj_digitos
    from parcelas_abertas pa
    left join public.clientes c on c.codigo = pa.cliente_codigo
    union all
    -- NFs faturadas
    select
      nfs.pedido, nfs.item,
      coalesce(c.nome_reduzido, null) as cliente_nome,
      nfs.produto_desc,
      'Faturado' as status,
      null::date as previsao_entrega,
      nullif(coalesce(nfs.pedido_cliente,''),'') as pedido_cliente,
      nfs.numero_nf,
      c.cnpj_digitos
    from nfs
    left join public.clientes c on c.codigo = nfs.cliente_codigo
  )
  select
    l.pedido, l.item, l.cliente_nome, l.produto_desc, l.status,
    l.previsao_entrega, l.pedido_cliente, l.numero_nf
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
-- FIM DO 11_rastreio_parcelas.sql
-- =====================================================================
