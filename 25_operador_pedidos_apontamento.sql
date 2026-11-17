-- 25_operador_pedidos_apontamento.sql  (idempotente / reaplicavel)
-- O operador (visualizador_maquina) nao via os itens COM FICHA da maquina dele.
--
-- CAUSA RAIZ: a policy de leitura de public.pedidos_abertos libera o item ao operador
-- so quando item_na_minha_maquina(pedido,item) = true. Essa funcao olhava APENAS a
-- camada LEGADA (override manual + pcp.grupo_maquinas) e NAO considerava o apontamento.
-- Logo, um item com ficha cujo pcp esta numa etapa anterior (ex.: DIGITAL) retorna
-- false -> o operador nao le o item em pedidos_abertos -> ele nem entra na lista base
-- do painel, mesmo com APONT_ESTADO montado e a etapa atual sendo a maquina dele.
--
-- CORRECAO: estende item_na_minha_maquina para TAMBEM liberar o item quando a ETAPA
-- ATUAL do apontamento (1a operacao NAO finalizada da OS, por etapa_idx) estiver numa
-- maquina do operador. Mantem as duas regras antigas (override/pcp) intactas. Regra do
-- usuario: o operador ve/aponta o item apenas quando ele esta na etapa dele.
--
-- Depende de: 13_ (ordens/ordem_operacoes), funcoes minhas_maquinas()/maquina_efetiva().
-- SECURITY DEFINER: le ordens/ordem_operacoes sem recursao de RLS.
-- Reversivel: basta recriar a versao anterior da funcao (abaixo, nas duas 1as regras).

create or replace function public.item_na_minha_maquina(ped integer, it integer)
returns boolean
language sql
stable security definer
set search_path to 'public'
as $function$
  select exists (
    -- (1) via override manual
    select 1 from public.overrides o
    where o.pedido = ped and o.item = it
      and o.grupo is not null
      and o.grupo = any(public.minhas_maquinas())
  )
  or (
    -- (2) via PCP (so quando NAO ha override de grupo para o item)
    not exists (
      select 1 from public.overrides o2
      where o2.pedido = ped and o2.item = it and o2.grupo is not null
    )
    and exists (
      select 1 from public.pcp p
      where p.pedido = ped and p.item = it
        and public.maquina_efetiva(p.grupo_maquinas) = any(public.minhas_maquinas())
    )
  )
  or exists (
    -- (3) NOVO: via APONTAMENTO — a etapa ATUAL (1a nao finalizada) da OS esta numa
    --     maquina do operador. Cobre itens com ficha, independentemente do pcp legado.
    select 1 from public.ordens o3
    where o3.pedido = ped and o3.item = it
      and (
        select oo.grupo
        from public.ordem_operacoes oo
        where oo.ordem_id = o3.id and oo.status <> 'finalizada'
        order by oo.etapa_idx
        limit 1
      ) = any(public.minhas_maquinas())
  );
$function$;

-- =====================================================================
-- FIM DO 25_operador_pedidos_apontamento.sql
-- =====================================================================
