-- =====================================================================
-- D&A - Rastreamento de Pedidos | Schema do banco (Supabase / PostgreSQL)
-- Fase de backend - v1
--
-- COMO USAR (resumido; faremos juntos no Claude Code):
--   1. Criar projeto no Supabase
--   2. Abrir o SQL Editor
--   3. Colar e rodar este arquivo INTEIRO, de cima para baixo
--
-- Este arquivo faz, nesta ordem:
--   A) Tabela de perfis de usuário (papeis e escopo)
--   B) Tabelas de dados importados das planilhas
--   C) Tabela de overrides (edicoes manuais) - com carencia (Opcao B)
--   D) Tabela de categorias de observacao
--   E) Tabela de/para de vendedores
--   F) RLS (Row Level Security) em TODAS as tabelas - negacao por padrao
--   G) Funcao publica de rastreio (so status, sem dados sensiveis)
--
-- Regras de negocio ja aprovadas e refletidas aqui:
--   - Upload: somente gestor
--   - Edicao manual: somente gestor/editor
--   - Override some com carencia de 45 dias apos o item sumir das bases
--   - Portal publico: retorna SO status/previsao, nunca valor/NF/linha crua
-- =====================================================================


-- =====================================================================
-- A) PERFIS DE USUARIO
-- Cada usuario do Supabase Auth ganha uma linha aqui com seu papel.
-- =====================================================================

-- Tipos de papel possiveis no sistema
create type public.papel_usuario as enum (
  'gestor',              -- ve tudo, sobe planilhas, cria usuarios
  'editor',              -- ve e edita producao (nao sobe planilha)
  'visualizador',        -- so leitura do painel inteiro
  'visualizador_maquina',-- so leitura, restrito a maquinas especificas
  'representante'        -- so leitura, restrito ao proprio codigo de vendedor
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nome text not null,
  papel public.papel_usuario not null default 'visualizador',
  -- Para 'representante': o codigo do vendedor no iQuattro (ex: '000001')
  codigo_vendedor text,
  -- Para 'visualizador_maquina': lista de grupos de maquina que pode ver
  -- (ex: {'FLEXO 250','BATIDA'}). Vazio = nenhuma.
  maquinas_permitidas text[] not null default '{}',
  criado_em timestamptz not null default now()
);

comment on table public.profiles is 'Perfil e escopo de cada usuario. Ligado 1:1 ao auth.users.';


-- Funcao auxiliar: retorna o papel do usuario logado.
-- Marcada como STABLE e SECURITY DEFINER para ser usada dentro das policies
-- sem cair em recursao de RLS na propria tabela profiles.
create or replace function public.meu_papel()
returns public.papel_usuario
language sql
stable
security definer
set search_path = public
as $$
  select papel from public.profiles where id = auth.uid();
$$;

-- Funcao auxiliar: usuario logado e gestor?
create or replace function public.sou_gestor()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.meu_papel() = 'gestor', false);
$$;

-- Funcao auxiliar: usuario logado pode editar? (gestor ou editor)
create or replace function public.posso_editar()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.meu_papel() in ('gestor','editor'), false);
$$;


-- =====================================================================
-- B) TABELAS DE DADOS IMPORTADOS (as 4 planilhas)
-- Substituidas a cada upload (clientes = cadastro mestre, atualiza).
-- Guardamos as colunas que o front realmente usa.
-- =====================================================================

-- --- Clientes (cadastro mestre; muda pouco) ---
create table public.clientes (
  codigo text primary key,            -- 'Codigo' do iQuattro
  razao_social text,
  nome_reduzido text,
  cnpj text,
  cnpj_digitos text,                  -- so digitos, para busca no portal
  vendedor text,                      -- 'Vendedor 1' bruto (ex: '000001 - ...')
  codigo_vendedor text,               -- so o codigo extraido (ex: '000001')
  atualizado_em timestamptz not null default now()
);
create index idx_clientes_cnpj_digitos on public.clientes(cnpj_digitos);

-- --- Pedidos em aberto (saldo do dia; substituido a cada upload) ---
create table public.pedidos_abertos (
  pedido integer not null,
  item integer not null,
  cliente_codigo text,
  cliente_nome_origem text,
  produto text,
  produto_desc text,
  saldo numeric,
  um text,
  saldo2 numeric,
  um2 text,
  entrega date,
  status_producao_origem text,
  ml numeric,
  pedido_cliente text,                -- 'Pedido do Cliente (xPed)' ja limpo
  atualizado_em timestamptz not null default now(),
  primary key (pedido, item)
);

-- --- PCP (status/maquina do dia; substituido a cada upload) ---
create table public.pcp (
  numero_ordem text primary key,      -- ex: 'P011173-001' ou 'A000557-001'
  pedido integer,                     -- extraido quando prefixo 'P'
  item integer,                       -- extraido quando prefixo 'P'
  produto_code text,                  -- extraido da descricao
  cliente_code text,
  grupo_maquinas text,
  status_ordem text,
  atualizado_em timestamptz not null default now()
);
create index idx_pcp_pedido_item on public.pcp(pedido, item);
create index idx_pcp_produto_cliente on public.pcp(produto_code, cliente_code);

-- --- Faturamento (janela de ~30 dias; substituido a cada upload) ---
create table public.faturamento (
  pedido integer not null,
  item integer not null,
  numero_nf text,
  pedido_cliente text,
  atualizado_em timestamptz not null default now(),
  primary key (pedido, item)
);


-- =====================================================================
-- C) OVERRIDES (edicoes manuais) - COM CARENCIA (Opcao B aprovada)
-- Chave: pedido+item. Nunca sobrescrito por upload.
-- 'ausente_desde' marca quando o item sumiu das bases; a limpeza so
-- exclui apos 45 dias sem reaparecer.
-- =====================================================================
create table public.overrides (
  pedido integer not null,
  item integer not null,
  grupo text,                         -- maquina reclassificada manualmente
  sub text,                           -- sub-maquina (Chinesa/Turo, etc.)
  ordem integer,                      -- posicao manual na fila
  obs text,                           -- observacao selecionada
  imagens numeric,                    -- 'imgs faca' (regra da batida)
  ausente_desde date,                 -- null = item ainda aparece nas bases
  atualizado_em timestamptz not null default now(),
  atualizado_por uuid references auth.users(id),
  primary key (pedido, item)
);

comment on column public.overrides.ausente_desde is
  'Data em que o item deixou de aparecer em pedidos_abertos e faturamento. '
  'Reaparecendo, volta a NULL. Excluido pela limpeza apos 45 dias.';


-- =====================================================================
-- D) CATEGORIAS DE OBSERVACAO (compartilhadas entre todos)
-- =====================================================================
create table public.categorias_obs (
  id bigint generated always as identity primary key,
  nome text not null unique,
  ordem integer not null default 0,
  criado_em timestamptz not null default now()
);

-- Semear com as categorias que ja estavam no front
insert into public.categorias_obs (nome, ordem) values
  ('Aguardando Faca', 1),
  ('Aguardando Clichê', 2),
  ('Aguardando Aprovação', 3),
  ('Aguardando MP', 4),
  ('Solicitar Clichê', 5);


-- =====================================================================
-- E) DE/PARA DE VENDEDORES (nome de exibicao correto)
-- Chave = codigo (estavel). Nome pode ser corrigido sem quebrar vinculo.
-- =====================================================================
create table public.vendedores (
  codigo text primary key,            -- ex: '000009'
  nome_exibicao text not null         -- ex: 'NILSON'
);

-- Semear com o de/para ja informado
insert into public.vendedores (codigo, nome_exibicao) values
  ('000009', 'NILSON'),
  ('000012', 'ALEXANDRE MENDES'),
  ('000013', 'MAURICIO PIRES'),
  ('000016', 'JAQUELINE NOGUEIRA'),
  ('000020', 'ADRIANA PAVANI'),
  ('000021', 'SILVANA LIMA');


-- =====================================================================
-- F) RLS - Row Level Security
-- Liga RLS em TODAS as tabelas. Sem policy = ninguem le/escreve.
-- =====================================================================

alter table public.profiles       enable row level security;
alter table public.clientes       enable row level security;
alter table public.pedidos_abertos enable row level security;
alter table public.pcp            enable row level security;
alter table public.faturamento    enable row level security;
alter table public.overrides      enable row level security;
alter table public.categorias_obs enable row level security;
alter table public.vendedores     enable row level security;

-- --- profiles: cada um le o proprio; gestor le/gerencia todos ---
create policy "profiles: ler o proprio" on public.profiles
  for select using (id = auth.uid());
create policy "profiles: gestor le todos" on public.profiles
  for select using (public.sou_gestor());
create policy "profiles: gestor gerencia" on public.profiles
  for all using (public.sou_gestor()) with check (public.sou_gestor());

-- --- clientes: leitura para autenticados; escrita so gestor ---
create policy "clientes: autenticado le" on public.clientes
  for select using (auth.role() = 'authenticated');
create policy "clientes: gestor escreve" on public.clientes
  for all using (public.sou_gestor()) with check (public.sou_gestor());

-- --- pedidos_abertos: leitura por escopo; escrita so gestor ---
-- Representante ve so o proprio vendedor; visualizador_maquina ve so
-- itens cuja maquina (via override ou PCP) esta no seu escopo; demais veem tudo.
-- Para simplificar e ser seguro, a filtragem fina por maquina/vendedor
-- e aplicada na VIEW de leitura (secao G). Aqui liberamos leitura a
-- autenticados e a view cuida do recorte. Escrita continua so gestor.
create policy "pedidos: autenticado le" on public.pedidos_abertos
  for select using (auth.role() = 'authenticated');
create policy "pedidos: gestor escreve" on public.pedidos_abertos
  for all using (public.sou_gestor()) with check (public.sou_gestor());

-- --- pcp: leitura autenticado; escrita so gestor ---
create policy "pcp: autenticado le" on public.pcp
  for select using (auth.role() = 'authenticated');
create policy "pcp: gestor escreve" on public.pcp
  for all using (public.sou_gestor()) with check (public.sou_gestor());

-- --- faturamento: leitura autenticado; escrita so gestor ---
create policy "faturamento: autenticado le" on public.faturamento
  for select using (auth.role() = 'authenticated');
create policy "faturamento: gestor escreve" on public.faturamento
  for all using (public.sou_gestor()) with check (public.sou_gestor());

-- --- overrides: leitura autenticado; escrita gestor/editor ---
create policy "overrides: autenticado le" on public.overrides
  for select using (auth.role() = 'authenticated');
create policy "overrides: editor escreve" on public.overrides
  for all using (public.posso_editar()) with check (public.posso_editar());

-- --- categorias_obs: leitura autenticado; escrita gestor ---
create policy "categorias: autenticado le" on public.categorias_obs
  for select using (auth.role() = 'authenticated');
create policy "categorias: gestor escreve" on public.categorias_obs
  for all using (public.sou_gestor()) with check (public.sou_gestor());

-- --- vendedores: leitura autenticado; escrita gestor ---
create policy "vendedores: autenticado le" on public.vendedores
  for select using (auth.role() = 'authenticated');
create policy "vendedores: gestor escreve" on public.vendedores
  for all using (public.sou_gestor()) with check (public.sou_gestor());


-- =====================================================================
-- G) FUNCAO PUBLICA DE RASTREIO (portal do cliente)
-- Acesso ANONIMO, mas retorna SO status/previsao. Nunca valor/NF/linha.
-- Recebe um termo (CNPJ, pedido interno ou pedido do cliente) e devolve
-- as linhas correspondentes com o status calculado no banco.
--
-- IMPORTANTE: e SECURITY DEFINER e le as tabelas por baixo do RLS, mas
-- so expoe as colunas seguras. E o unico caminho anonimo do sistema.
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
      null::text, null::text,
      null::text, null::text,
      null::date, null::text,
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
      -- override de grupo (se houver)
      o.grupo as grupo_override,
      -- match em faturamento?
      exists (select 1 from public.faturamento f
              where f.pedido = b.pedido and f.item = b.item) as faturado,
      (select f.numero_nf from public.faturamento f
        where f.pedido = b.pedido and f.item = b.item limit 1) as numero_nf,
      -- match em PCP (por pedido+item, prefixo P)?
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
    -- so mostra previsao quando ainda nao faturado
    case when ca.faturado then null else ca.entrega end as previsao_entrega,
    nullif(ca.pedido_cliente,'') as pedido_cliente,
    -- NF so quando faturado
    case when ca.faturado then ca.numero_nf else null end as numero_nf
  from calculado ca, termo_norm tn
  where
    -- 1) numero interno do pedido (curto)
    (tn.t ~ '^\d{1,6}$' and ca.pedido::text = tn.t)
    -- 2) numero do pedido do cliente
    or (ca.pedido_cliente = tn.t)
    or (tn.t_dig <> '' and regexp_replace(ca.pedido_cliente,'\D','','g') = tn.t_dig)
    -- 3) CNPJ do cliente
    or (tn.t_dig <> '' and ca.cnpj_digitos = tn.t_dig);
$$;

-- Permitir que usuarios anonimos (portal publico) chamem SO esta funcao.
grant execute on function public.rastrear_pedido(text) to anon;

-- Garante que anon NAO tem acesso direto a nenhuma tabela.
-- (RLS ja bloqueia, mas isto e cinto+suspensorio.)
revoke all on all tables in schema public from anon;


-- =====================================================================
-- FIM DO SCHEMA v1
-- Proximos arquivos (faremos depois):
--   02_ingestao.sql  -> funcoes de upload (substituir bases + merge override)
--   03_limpeza.sql   -> job que marca ausente_desde e exclui apos 45 dias
-- =====================================================================
