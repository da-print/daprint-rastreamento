-- 23_operador_apontamento.sql  (idempotente / reaplicavel)
-- OPERADOR (visualizador_maquina) enxerga e aponta os itens da maquina dele,
-- inclusive os que estao com FICHA NOVA (camada de apontamento).
--
-- PROBLEMA: hoje o operador so LE as ordem_operacoes/apontamentos do PROPRIO grupo
-- (policy grupo_na_minha_maquina). Para uma OS com roteiro (pre-impressao -> flexo ->
-- troquel -> revisora), o app recebe so a etapa do operador e monta a fila (APONT_ESTADO)
-- com o roteiro INCOMPLETO — a etapa atual/encadeamento sai errado e o item "some".
--
-- CORRECAO: o operador passa a LER o roteiro INTEIRO das OS que TOCAM a maquina dele
-- (qualquer etapa de uma OS que tenha ao menos uma etapa no grupo dele). Assim o app
-- calcula a fila certa. A ESCRITA (insert de apontamento) CONTINUA restrita ao grupo
-- dele — a protecao real nao muda. O recorte visual por maquina e feito na interface.
--
-- Depende de: 13_producao_apontamentos.sql (tabelas/policies + minhas_maquinas,
--             grupo_na_minha_maquina, ve_tudo). So altera 2 policies de SELECT + helpers.
-- Reversivel: reaplicar o 13_ volta ao comportamento anterior.

-- =====================================================================
-- A) HELPERS (security definer: enxergam o roteiro sem recursao de RLS)
-- =====================================================================
-- Limpa variantes antigas (assinatura bigint) de uma tentativa anterior, se houver.
drop function if exists public.os_toca_minha_maquina(bigint);
drop function if exists public.apont_os_toca_minha(bigint);

-- A OS (por id) tem ALGUMA etapa numa maquina do operador logado?
-- IDs sao UUID (ordens.id, ordem_operacoes.id/ordem_id, apontamentos.operacao_id).
create or replace function public.os_toca_minha_maquina(p_ordem uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.ordem_operacoes oo
    where oo.ordem_id = p_ordem
      and oo.grupo = any(public.minhas_maquinas())
  );
$$;

-- O apontamento (por operacao) pertence a uma OS que toca a maquina do operador?
create or replace function public.apont_os_toca_minha(p_operacao uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.ordem_operacoes oo
    where oo.id = p_operacao
      and public.os_toca_minha_maquina(oo.ordem_id)
  );
$$;

-- =====================================================================
-- B) LEITURA DE ordem_operacoes: ve_tudo OU a OS toca a maquina do operador
--    (antes: so a etapa do proprio grupo). A ESCRITA segue so gestor/editor.
-- =====================================================================
drop policy if exists "operacoes: leitura por papel" on public.ordem_operacoes;
create policy "operacoes: leitura por papel" on public.ordem_operacoes
  for select using (
    public.ve_tudo()
    or public.grupo_na_minha_maquina(grupo)
    or public.os_toca_minha_maquina(ordem_id)
  );

-- =====================================================================
-- C) LEITURA DE apontamentos: idem — todos os apontamentos das OS que tocam
--    a maquina do operador (necessario p/ timers e p/ o encadeamento parcial).
--    O INSERT continua restrito ao grupo do operador (policy "apont: insere").
-- =====================================================================
drop policy if exists "apont: leitura por papel" on public.apontamentos;
create policy "apont: leitura por papel" on public.apontamentos
  for select using (
    public.ve_tudo()
    or public.apont_os_toca_minha(operacao_id)
  );

-- =====================================================================
-- FIM DO 23_operador_apontamento.sql
-- =====================================================================
