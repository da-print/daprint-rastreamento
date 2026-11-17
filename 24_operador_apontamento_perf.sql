-- 24_operador_apontamento_perf.sql  (idempotente / reaplicavel)
-- CORRIGE o desempenho do RLS do operador introduzido no 23_.
--
-- O 23_ usa funcoes POR-LINHA (os_toca_minha_maquina/apont_os_toca_minha) no SELECT
-- de ordem_operacoes/apontamentos. Para o OPERADOR (sem ve_tudo), elas rodam uma
-- subconsulta para CADA linha; a leitura completa feita pelo app via PostgREST estoura
-- o statement_timeout -> o app recebe erro -> APONT_ESTADO fica vazio -> os itens com
-- ficha nao recebem status de producao e SOMEM para o operador (so aparecem os sem
-- ficha, que vem da camada antiga/pcp). O gestor nao sente porque ve_tudo() curto-
-- circuita antes de qualquer funcao por-linha.
--
-- CORRECAO: trocar as funcoes por-linha por CONJUNTOS calculados UMA vez (funcoes
-- set-returning security definer) usados com `id in (select ...)`. O planner avalia
-- o conjunto uma unica vez (subplan hasheado) -> rapido. Security definer evita
-- recursao de RLS ao ler ordem_operacoes dentro da propria policy.
--
-- Depende de: 13_ e 23_. Reversivel: reaplicar o 23_ volta ao estado anterior.

-- =====================================================================
-- A) CONJUNTOS (uma vez por consulta; definer p/ nao recursar no RLS)
-- =====================================================================
create or replace function public.minhas_ordens_ids()
returns setof uuid
language sql stable security definer set search_path = public
as $$
  select distinct oo.ordem_id
  from public.ordem_operacoes oo
  where oo.grupo = any(public.minhas_maquinas());
$$;

create or replace function public.minhas_operacoes_ids()
returns setof uuid
language sql stable security definer set search_path = public
as $$
  select oo.id
  from public.ordem_operacoes oo
  where oo.ordem_id in (select public.minhas_ordens_ids());
$$;

-- =====================================================================
-- B) POLICIES de leitura reescritas (conjunto no lugar de funcao por-linha)
--    Escrita/insert seguem INALTERADAS (protecao real nao muda).
-- =====================================================================
drop policy if exists "operacoes: leitura por papel" on public.ordem_operacoes;
create policy "operacoes: leitura por papel" on public.ordem_operacoes
  for select using (
    public.ve_tudo()
    or public.grupo_na_minha_maquina(grupo)
    or ordem_id in (select public.minhas_ordens_ids())
  );

drop policy if exists "apont: leitura por papel" on public.apontamentos;
create policy "apont: leitura por papel" on public.apontamentos
  for select using (
    public.ve_tudo()
    or operacao_id in (select public.minhas_operacoes_ids())
  );

-- ordens: tambem por conjunto (evita o EXISTS por-linha do 13_)
drop policy if exists "ordens: leitura por papel" on public.ordens;
create policy "ordens: leitura por papel" on public.ordens
  for select using (
    public.ve_tudo()
    or id in (select public.minhas_ordens_ids())
  );

-- =====================================================================
-- C) Remove os helpers por-linha do 23_ (nao mais referenciados)
-- =====================================================================
drop function if exists public.os_toca_minha_maquina(uuid);
drop function if exists public.apont_os_toca_minha(uuid);

-- =====================================================================
-- FIM DO 24_operador_apontamento_perf.sql
-- =====================================================================
