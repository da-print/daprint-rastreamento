-- =====================================================================
-- D&A - Rastreamento de Pedidos | 05_fix_rastreio_faturado.sql
-- Corrige a funcao rastrear_pedido para itens que ja sairam de
-- pedidos_abertos (100% faturados): agora puxa cliente e produto da
-- propria tabela faturamento (que passou a ter cliente_codigo e produto_desc).
--
-- COMO USAR: rodar INTEIRO no SQL Editor, DEPOIS de 01, 02, 03 e 04.
-- Seguro rodar de novo (create or replace).
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
language sql
stable
security definer
set search_path = public
as $$
  with termo_norm as (
    select
      trim(termo) as t,
      regexp_replace(coalesce(termo,''), '\D', '', 'g') as t_dig
  ),
  -- universo = pedidos abertos + itens so no faturamento (ja faturados)
  base as (
    select
      pa.pedido, pa.item, pa.cliente_codigo, pa.cliente_nome_origem,
      pa.produto, pa.produto_desc, pa.entrega, pa.status_producao_origem,
      pa.pedido_cliente
    from public.pedidos_abertos pa
    union
    select
      f.pedido, f.item,
      f.cliente_codigo,               -- agora traz o cliente do faturamento
      null::text,                     -- cliente_nome_origem (resolvido via clientes)
      null::text,                     -- produto (codigo) nao usado aqui
      f.produto_desc,                 -- agora traz a descricao do faturamento
      null::date,                     -- entrega (faturado nao mostra previsao)
      null::text,                     -- status_producao_origem
      f.pedido_cliente
    from public.faturamento f
    where not exists (
      select 1 from public.pedidos_abertos pa2
      where pa2.pedido = f.pedido and pa2.item = f.item
    )
  ),
  enriquecido as (
    select
      b.pedido, b.item,
      coalesce(c.nome_reduzido, b.cliente_nome_origem) as cliente_nome,
      b.produto, b.produto_desc,
      b.entrega,
      b.status_producao_origem,
      coalesce(b.pedido_cliente, '') as pedido_cliente,
      c.cnpj_digitos,
      o.grupo as grupo_override,
      exists (select 1 from public.faturamento f
              where f.pedido = b.pedido and f.item = b.item) as faturado,
      (select f.numero_nf from public.faturamento f
        where f.pedido = b.pedido and f.item = b.item limit 1) as numero_nf,
      exists (select 1 from public.pcp p
              where p.pedido = b.pedido and p.item = b.item) as em_pcp
    from base b
    left join public.clientes c on c.codigo = b.cliente_codigo
    left join public.overrides o on o.pedido = b.pedido and o.item = b.item
  ),
  calculado as (
    select
      e.pedido, e.item, e.cliente_nome, e.produto_desc, e.entrega,
      e.pedido_cliente, e.cnpj_digitos, e.faturado, e.numero_nf,
      case
        when e.faturado then 'Faturado'
        when left(coalesce(e.produto,''),2) = 'PA' and e.em_pcp then 'Em produção'
        when left(coalesce(e.produto,''),2) = 'PA'
             and e.status_producao_origem = 'FINALIZADA'
             then 'Finalizado, aguardando faturamento'
        else 'Em produção'
      end as status
    from enriquecido e
  )
  select
    ca.pedido, ca.item, ca.cliente_nome, ca.produto_desc,
    ca.status,
    case when ca.faturado then null else ca.entrega end as previsao_entrega,
    nullif(ca.pedido_cliente,'') as pedido_cliente,
    case when ca.faturado then ca.numero_nf else null end as numero_nf
  from calculado ca, termo_norm tn
  where
    (tn.t ~ '^\d{1,6}$' and ca.pedido::text = tn.t)
    or (ca.pedido_cliente = tn.t)
    or (tn.t_dig <> '' and regexp_replace(ca.pedido_cliente,'\D','','g') = tn.t_dig)
    or (tn.t_dig <> '' and ca.cnpj_digitos = tn.t_dig);
$$;

grant execute on function public.rastrear_pedido(text) to anon;

-- =====================================================================
-- FIM DO 05_fix_rastreio_faturado.sql
-- =====================================================================
