-- =====================================================================
-- D&A - Rastreamento de Pedidos | 07_rls_operador.sql
-- Restringe o operador (visualizador_maquina) a ver SOMENTE itens EM
-- PRODUCAO nas maquinas dele. Nada de faturamento, carteira ou aguardando.
--
-- Regras:
--   - faturamento: operador NAO ve nada
--   - pcp: ve so ordens cuja maquina efetiva esta nas maquinas dele
--   - pedidos_abertos: ve so itens que tem ordem PCP numa maquina dele
--   - clientes: ve so os clientes desses itens
--   - "maquina efetiva" = override.grupo se houver, senao pcp.grupo,
--      com DIGITAL contando como PRE-IMPRESSAO (regra do fluxo)
--
-- COMO USAR: rodar no SQL Editor, DEPOIS de 01..06.
-- Substitui as policies de leitura por papel das tabelas afetadas.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Funcao: normaliza a maquina efetiva (DIGITAL -> PRE-IMPRESSAO)
-- ---------------------------------------------------------------------
create or replace function public.maquina_efetiva(g text)
returns text
language sql immutable
as $$
  select case when g = 'DIGITAL' then 'PRE-IMPRESSAO' else g end;
$$;

-- ---------------------------------------------------------------------
-- Funcao: o item (pedido,item) esta numa maquina que o operador ve?
-- Considera override (prioridade) e, na ausencia, o PCP.
-- ---------------------------------------------------------------------
create or replace function public.item_na_minha_maquina(ped integer, it integer)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    -- via override manual
    select 1 from public.overrides o
    where o.pedido = ped and o.item = it
      and o.grupo is not null
      and o.grupo = any(public.minhas_maquinas())
  )
  or (
    -- via PCP (so quando NAO ha override de grupo para o item)
    not exists (
      select 1 from public.overrides o2
      where o2.pedido = ped and o2.item = it and o2.grupo is not null
    )
    and exists (
      select 1 from public.pcp p
      where p.pedido = ped and p.item = it
        and public.maquina_efetiva(p.grupo_maquinas) = any(public.minhas_maquinas())
    )
  );
$$;


-- ---------------------------------------------------------------------
-- PCP: operador ve so ordens na(s) maquina(s) dele (considera override
-- do proprio item, se houver)
-- ---------------------------------------------------------------------
drop policy if exists "pcp: leitura por papel" on public.pcp;

create policy "pcp: leitura por papel" on public.pcp
for select using (
  public.ve_tudo()
  or (public.meu_papel() = 'representante'
      and public.cliente_e_meu(cliente_code))
  or (public.meu_papel() = 'visualizador_maquina'
      and (
        -- override manda: se o item foi movido, respeita
        (exists (select 1 from public.overrides o
                 where o.pedido = pcp.pedido and o.item = pcp.item
                   and o.grupo is not null
                   and o.grupo = any(public.minhas_maquinas())))
        or
        -- senao, pela maquina da propria ordem
        (not exists (select 1 from public.overrides o2
                     where o2.pedido = pcp.pedido and o2.item = pcp.item
                       and o2.grupo is not null)
         and public.maquina_efetiva(grupo_maquinas) = any(public.minhas_maquinas()))
      ))
);


-- ---------------------------------------------------------------------
-- PEDIDOS ABERTOS: operador ve so itens em producao na maquina dele
-- (item precisa estar em PCP/override na maquina dele; itens finalizados
-- ou em carteira nao entram porque nao tem ordem ativa na maquina)
-- ---------------------------------------------------------------------
drop policy if exists "pedidos: leitura por papel" on public.pedidos_abertos;

create policy "pedidos: leitura por papel" on public.pedidos_abertos
for select using (
  public.ve_tudo()
  or (public.meu_papel() = 'representante'
      and public.cliente_e_meu(cliente_codigo))
  or (public.meu_papel() = 'visualizador_maquina'
      and public.item_na_minha_maquina(pedido, item))
);


-- ---------------------------------------------------------------------
-- FATURAMENTO: operador NAO ve nada
-- ---------------------------------------------------------------------
drop policy if exists "faturamento: leitura por papel" on public.faturamento;

create policy "faturamento: leitura por papel" on public.faturamento
for select using (
  public.ve_tudo()
  or (public.meu_papel() = 'representante'
      and public.cliente_e_meu(cliente_codigo))
  -- visualizador_maquina: sem acesso a faturamento
);


-- ---------------------------------------------------------------------
-- CLIENTES: operador ve so clientes dos itens que ele enxerga
-- (para exibir o nome). Como e leitura de apoio, liberamos por existencia
-- de ao menos um item visivel daquele cliente.
-- ---------------------------------------------------------------------
drop policy if exists "clientes: leitura por papel" on public.clientes;

create policy "clientes: leitura por papel" on public.clientes
for select using (
  public.ve_tudo()
  or (public.meu_papel() = 'representante'
      and codigo_vendedor = public.meu_codigo_vendedor())
  or (public.meu_papel() = 'visualizador_maquina'
      and exists (
        select 1 from public.pedidos_abertos pa
        where pa.cliente_codigo = clientes.codigo
          and public.item_na_minha_maquina(pa.pedido, pa.item)
      ))
);


-- ---------------------------------------------------------------------
-- OVERRIDES: operador precisa ler os overrides dos itens que ele ve
-- (senao a maquina reclassificada nao aparece). Leitura liberada a
-- autenticados ja cobre; nada a mudar. Escrita continua gestor/editor.
-- ---------------------------------------------------------------------

-- =====================================================================
-- FIM DO 07_rls_operador.sql
-- =====================================================================
