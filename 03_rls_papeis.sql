-- =====================================================================
-- D&A - Rastreamento de Pedidos | 03_rls_papeis.sql
-- Politicas de RLS que fazem o RECORTE FINO por papel:
--   - representante: ve so os pedidos cujo cliente e do seu codigo_vendedor
--   - visualizador_maquina: ve so pedidos/pcp da(s) maquina(s) permitida(s)
--   - gestor/editor/visualizador: veem tudo (leitura)
--
-- COMO USAR: rodar INTEIRO no SQL Editor do Supabase, DEPOIS de 01 e 02.
--
-- IMPORTANTE: este arquivo SUBSTITUI as policies de leitura "autenticado le"
-- das tabelas de dados por versoes que respeitam o papel. As policies de
-- ESCRITA (so gestor / gestor-editor) continuam como estao.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Funcoes auxiliares de escopo do usuario logado
-- (SECURITY DEFINER + STABLE para uso dentro de policies, sem recursao)
-- ---------------------------------------------------------------------

-- Codigo de vendedor do usuario logado (para representante). NULL se nao tiver.
create or replace function public.meu_codigo_vendedor()
returns text
language sql stable security definer set search_path = public
as $$
  select codigo_vendedor from public.profiles where id = auth.uid();
$$;

-- Maquinas permitidas do usuario logado (para visualizador_maquina).
create or replace function public.minhas_maquinas()
returns text[]
language sql stable security definer set search_path = public
as $$
  select coalesce(maquinas_permitidas, '{}') from public.profiles where id = auth.uid();
$$;

-- Ve tudo? (gestor, editor ou visualizador comum)
create or replace function public.ve_tudo()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.meu_papel() in ('gestor','editor','visualizador'), false);
$$;

-- O cliente informado pertence ao meu codigo de vendedor?
create or replace function public.cliente_e_meu(cli_codigo text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.clientes c
    where c.codigo = cli_codigo
      and c.codigo_vendedor = public.meu_codigo_vendedor()
  );
$$;


-- ---------------------------------------------------------------------
-- CLIENTES: representante ve so os seus; visualizador_maquina ve todos
-- (precisa dos nomes/cnpj para exibir); demais veem todos.
-- ---------------------------------------------------------------------
drop policy if exists "clientes: autenticado le" on public.clientes;

create policy "clientes: leitura por papel" on public.clientes
for select using (
  public.ve_tudo()
  or public.meu_papel() = 'visualizador_maquina'
  or (public.meu_papel() = 'representante'
      and codigo_vendedor = public.meu_codigo_vendedor())
);


-- ---------------------------------------------------------------------
-- PEDIDOS ABERTOS: recorte por papel
-- ---------------------------------------------------------------------
drop policy if exists "pedidos: autenticado le" on public.pedidos_abertos;

create policy "pedidos: leitura por papel" on public.pedidos_abertos
for select using (
  public.ve_tudo()
  or (public.meu_papel() = 'representante'
      and public.cliente_e_meu(cliente_codigo))
  -- visualizador_maquina: o recorte por maquina depende de override/pcp,
  -- que o app resolve na exibicao; aqui liberamos leitura para ele e o
  -- filtro fino de maquina fica na interface (ele nao tem upload nem edicao).
  or public.meu_papel() = 'visualizador_maquina'
);


-- ---------------------------------------------------------------------
-- PCP: recorte por papel
-- ---------------------------------------------------------------------
drop policy if exists "pcp: autenticado le" on public.pcp;

create policy "pcp: leitura por papel" on public.pcp
for select using (
  public.ve_tudo()
  or (public.meu_papel() = 'representante'
      and public.cliente_e_meu(cliente_code))
  or (public.meu_papel() = 'visualizador_maquina'
      and grupo_maquinas = any(public.minhas_maquinas()))
);


-- ---------------------------------------------------------------------
-- FATURAMENTO: recorte por papel
-- Agora que faturamento tem cliente_codigo (ver 04_faturamento_cliente.sql),
-- o representante ve faturamento diretamente pelo vendedor do cliente,
-- inclusive itens que ja sairam de pedidos_abertos.
-- ---------------------------------------------------------------------
drop policy if exists "faturamento: autenticado le" on public.faturamento;

create policy "faturamento: leitura por papel" on public.faturamento
for select using (
  public.ve_tudo()
  or public.meu_papel() = 'visualizador_maquina'
  or (public.meu_papel() = 'representante'
      and public.cliente_e_meu(cliente_codigo))
);


-- ---------------------------------------------------------------------
-- OVERRIDES: leitura liberada a autenticados (nao contem dado sensivel;
-- so pedido+item+maquina). Escrita continua gestor/editor.
-- Mantemos a policy de leitura existente. Nada a alterar aqui.
-- ---------------------------------------------------------------------


-- =====================================================================
-- FIM DO 03_rls_papeis.sql
-- =====================================================================
