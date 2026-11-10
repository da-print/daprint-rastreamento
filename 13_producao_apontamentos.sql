-- =====================================================================
-- D&A - PCP | 13_producao_apontamentos.sql
-- Camada de MONITORAMENTO DE PRODUCAO (ficha tecnica + apontamentos + KPIs)
--
-- Esta e a camada PERMANENTE que convive com a camada-foto atual
-- (pedidos_abertos/pcp/faturamento, substituidas a cada upload).
-- Nada aqui e apagado por upload. A chave de ligacao e pedido+item.
--
-- RASCUNHO PARA REVISAO. NAO aplicado no banco.
-- Depende de 01..09 (perfis, papeis, funcoes de escopo, maquinas).
-- Reutiliza: meu_papel(), sou_gestor(), posso_editar(), ve_tudo(),
--            minhas_maquinas().
--
-- Ordem das secoes:
--   A) Enriquecimento das maquinas (modo de calculo + acabamento)
--   B) Produtos / ficha tecnica (produtos, conversoes, etapas do roteiro)
--   C) Ordens de producao (OS persistente) e suas operacoes
--   D) Apontamentos (log append-only) e motivos de parada
--   E) RLS em todas as tabelas novas
--   F) Funcoes e VIEWS de KPI (tempos reais, estimado x real)
-- =====================================================================


-- =====================================================================
-- A) MAQUINAS - enriquecimento (ALTER no que ja existe em 09_maquinas.sql)
-- Mantem setup_min / desperdicio_m existentes (viram a base do modo "fixo").
-- maquinas_sub.velocidade ja existe (velocidade por maquina fisica).
-- =====================================================================

-- Modo de calculo do grupo:
--   por_cor   -> setup e desperdicio de setup POR COR (impressao). Metros.
--   fixo      -> setup e desperdicio fixos (digital, troquel, corte...). Metros.
--   unidade   -> setup em min + desperdicio em unidades (batida). Unidades.
--   validacao -> etapa de analise (ex: pre-impressao). Sem tempo/metragem.
do $$ begin
  if not exists (select 1 from pg_type where typname = 'modo_maquina') then
    create type public.modo_maquina as enum ('por_cor','fixo','unidade','validacao');
  end if;
end $$;

alter table public.maquinas_grupos
  add column if not exists modo            public.modo_maquina not null default 'fixo',
  add column if not exists desp_prod_pct   numeric not null default 0,  -- % desperdicio produtivo
  add column if not exists setup_min_cor   numeric not null default 0,  -- modo por_cor: min por cor
  add column if not exists desp_m_cor      numeric not null default 0,  -- modo por_cor: m por cor
  add column if not exists desp_un         numeric not null default 0,  -- modo unidade: desperdicio setup (un)
  add column if not exists aplica_verniz   boolean not null default false,
  add column if not exists aplica_laminacao boolean not null default false,
  add column if not exists acab_min        numeric not null default 0,  -- min por acabamento aplicado
  add column if not exists acab_desp       numeric not null default 0,  -- desperdicio por acabamento (m/un)
  add column if not exists velocidade      numeric not null default 0,  -- nominal do grupo (p/ estimativa)
  add column if not exists apontamento_ativo boolean not null default false; -- CHAVE do rollout hibrido
-- Semeia os grupos da 1a fase de apontamento SO na primeira aplicacao (quando
-- nenhum grupo esta ligado ainda), p/ nao sobrescrever as chaves que o gestor
-- ligar/desligar depois na aba Maquinas.
do $$ begin
  if not exists (select 1 from public.maquinas_grupos where apontamento_ativo) then
    update public.maquinas_grupos set apontamento_ativo = true
     where nome in ('PRE-IMPRESSAO','DIGITAL','CORTE BROTECH / VOREY');
  end if;
end $$;

-- Semeia MODO (estrutural) e parametros de EXEMPLO para os grupos padrao, SEM
-- sobrescrever ajustes ja feitos (so preenche o que ainda esta no default).
-- Ajuste os numeros reais depois (velocidade, setup por cor, % desperdicio).
update public.maquinas_grupos set modo='validacao' where nome='PRE-IMPRESSAO' and modo='fixo';
update public.maquinas_grupos set modo='unidade' where nome='BATIDA' and modo='fixo';
update public.maquinas_grupos set modo='por_cor' where nome in ('FLEXO 250','FLEXO 350') and modo='fixo';
update public.maquinas_grupos set
  velocidade    = coalesce(nullif(velocidade,0), 1800),
  setup_min_cor = coalesce(nullif(setup_min_cor,0), 30),
  desp_m_cor    = coalesce(nullif(desp_m_cor,0), 30),
  desp_prod_pct = coalesce(nullif(desp_prod_pct,0), 10),
  aplica_verniz = true, aplica_laminacao = true,
  acab_min      = coalesce(nullif(acab_min,0), 30),
  acab_desp     = coalesce(nullif(acab_desp,0), 30)
  where nome in ('FLEXO 250','FLEXO 350');
update public.maquinas_grupos set velocidade = 2400 where nome='FLEXO 350' and velocidade=1800;
update public.maquinas_grupos set
  velocidade    = coalesce(nullif(velocidade,0), 2000),
  desp_prod_pct = coalesce(nullif(desp_prod_pct,0), 10),
  setup_min     = coalesce(nullif(setup_min,0), 20),
  desperdicio_m = coalesce(nullif(desperdicio_m,0), 10)
  where nome in ('TROQUELADORAS','CORTE BROTECH / VOREY','REVISORAS');
-- Corte tambem aplica acabamento (verniz/laminacao em linha).
update public.maquinas_grupos set aplica_verniz=true, aplica_laminacao=true,
  acab_min=coalesce(nullif(acab_min,0),20), acab_desp=coalesce(nullif(acab_desp,0),20)
  where nome='CORTE BROTECH / VOREY';
update public.maquinas_grupos set
  velocidade    = coalesce(nullif(velocidade,0), 3000),
  desp_prod_pct = coalesce(nullif(desp_prod_pct,0), 10),
  setup_min     = coalesce(nullif(setup_min,0), 30),
  desp_un       = coalesce(nullif(desp_un,0), 1000)
  where nome='BATIDA';
update public.maquinas_grupos set
  velocidade    = coalesce(nullif(velocidade,0), 1200),
  desp_prod_pct = coalesce(nullif(desp_prod_pct,0), 10),
  setup_min     = coalesce(nullif(setup_min,0), 10),
  desperdicio_m = coalesce(nullif(desperdicio_m,0), 10)
  where nome='DIGITAL';

comment on column public.maquinas_grupos.modo is
  'Como o grupo calcula tempo/desperdicio: por_cor | fixo | unidade | validacao.';
comment on column public.maquinas_grupos.acab_min is
  'Cada acabamento (verniz/laminacao) que o grupo aplica conta como +1 "cor", somando acab_min ao setup.';


-- =====================================================================
-- B) PRODUTOS / FICHA TECNICA (dado-mestre; nao some no upload)
-- =====================================================================

create table if not exists public.produtos (
  codigo_pa       text primary key,            -- ex: 'PA000000000442'
  descricao       text,
  substrato       text,                        -- MP padrao (ex: COUCHE, FILME)
  larg_substrato  numeric,                     -- mm
  larg_etiqueta   numeric,                     -- mm
  alt_etiqueta    numeric,                     -- mm
  gap_etiqueta    numeric not null default 0,  -- mm (passo = alt + gap)
  cores           integer not null default 0,
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now()
);
comment on table public.produtos is 'Ficha tecnica do produto. Passo da etiqueta = alt_etiqueta + gap_etiqueta.';

-- Conversao de unidade da base de pedidos -> etiquetas (ex: 1 ROLO = 1000)
create table if not exists public.produto_conversoes (
  produto_codigo text not null references public.produtos(codigo_pa) on delete cascade,
  um             text not null,                -- unidade da base (ex: ROLO, CAIXA, MI)
  fator          numeric not null,             -- quantas etiquetas por 1 unidade
  primary key (produto_codigo, um)
);

-- Roteiro de producao: uma linha por etapa (grupo de maquina), na ordem
create table if not exists public.produto_etapas (
  id             bigint generated always as identity primary key,
  produto_codigo text not null references public.produtos(codigo_pa) on delete cascade,
  ordem          integer not null default 1,   -- posicao no fluxo
  grupo          text not null references public.maquinas_grupos(nome),
  carreiras      integer not null default 1,
  acab_verniz    boolean not null default false,
  acab_laminacao boolean not null default false,
  -- overrides opcionais de parametros so para este produto nesta etapa
  ov             jsonb,
  unique (produto_codigo, ordem)
);


-- =====================================================================
-- C) ORDENS DE PRODUCAO (OS persistente) + OPERACOES
-- A OS e identificada por pedido+item. Criada/atualizada no upload de
-- "pedidos em aberto" (merge), NUNCA apagada.
-- =====================================================================

create table if not exists public.ordens (
  id              uuid primary key default gen_random_uuid(),
  pedido          integer not null,
  item            integer not null,
  produto_codigo  text,                          -- SOFT ref ao produto (pode nao ter ficha ainda)
  descricao_origem text,                        -- descricao vinda da planilha
  qtd             numeric,                       -- saldo do pedido
  um              text,                          -- unidade (ROLO/CAIXA/MI/UN...)
  entrega         date,
  pedido_cliente  text,                          -- xPed (informativo p/ faturamento)
  criado_em       timestamptz not null default now(),
  atualizado_em   timestamptz not null default now(),
  unique (pedido, item)
);
comment on table public.ordens is 'OS persistente (historico). Alimentada por upload de pedidos em aberto; nunca deletada.';
-- Para bancos que ja aplicaram a v1 com a FK: remove a FK (OS pode existir sem ficha).
alter table public.ordens drop constraint if exists ordens_produto_codigo_fkey;
-- Cliente na OS (para filtros/colunas dos KPIs). Preenchido pelo sincronizar_ordens
-- a partir da camada-foto (pedidos_abertos), que e substituida a cada upload.
alter table public.ordens
  add column if not exists cliente_codigo text,
  add column if not exists cliente_nome   text;

-- Sincroniza a OS persistente a partir da camada-foto (pedidos_abertos).
-- MERGE por (pedido,item): atualiza os campos, NUNCA apaga OS que sairam da
-- base. Chamada pelo app apos o upload de pedidos em aberto. Retorna nº de linhas.
create or replace function public.sincronizar_ordens()
returns integer language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  if not public.sou_gestor() then
    raise exception 'Apenas o gestor pode sincronizar ordens.';
  end if;
  insert into public.ordens (pedido, item, produto_codigo, descricao_origem, qtd, um, entrega, pedido_cliente, cliente_codigo, cliente_nome)
  select distinct on (pa.pedido, pa.item)
         pa.pedido, pa.item,
         upper(substring(coalesce(pa.produto,'') from '[A-Za-z]{2}[0-9]{3,}')),
         pa.produto_desc, pa.saldo, pa.um, pa.entrega, pa.pedido_cliente,
         pa.cliente_codigo,
         coalesce(c.nome_reduzido, c.razao_social, pa.cliente_nome_origem)
  from public.pedidos_abertos pa
  left join public.clientes c on c.codigo = pa.cliente_codigo
  order by pa.pedido, pa.item
  on conflict (pedido, item) do update set
    produto_codigo   = excluded.produto_codigo,
    descricao_origem = excluded.descricao_origem,
    qtd              = excluded.qtd,
    um               = excluded.um,
    entrega          = excluded.entrega,
    pedido_cliente   = excluded.pedido_cliente,
    cliente_codigo   = excluded.cliente_codigo,
    cliente_nome     = excluded.cliente_nome,
    atualizado_em    = now();
  get diagnostics v_n = row_count;
  return v_n;
end $$;
grant execute on function public.sincronizar_ordens() to authenticated;

do $$ begin
  if not exists (select 1 from pg_type where typname = 'status_operacao') then
    create type public.status_operacao as enum
      ('aguardando','em_setup','setup_ok','em_producao','parado','finalizada');
  end if;
end $$;

-- Uma operacao por etapa do roteiro, materializada quando a OS entra em producao.
-- Guarda tambem o ESTIMADO (snapshot) para comparar com o real sem recalcular.
create table if not exists public.ordem_operacoes (
  id             uuid primary key default gen_random_uuid(),
  ordem_id       uuid not null references public.ordens(id) on delete cascade,
  etapa_idx      integer not null,              -- 1,2,3...
  grupo          text not null references public.maquinas_grupos(nome),
  carreiras      integer not null default 1,
  acab_verniz    boolean not null default false,
  acab_laminacao boolean not null default false,
  maquina        text,                          -- sub-maquina escolhida na operacao
  status         public.status_operacao not null default 'aguardando',
  -- estimado (snapshot no momento da materializacao)
  unidade_est    text,                          -- 'm' | 'un' | ''
  qtd_est        numeric,
  setup_est_min  numeric,
  prod_est_min   numeric,
  desp_setup_est numeric,
  desp_prod_est  numeric,
  vel_est        numeric,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  unique (ordem_id, etapa_idx)
);
create index if not exists idx_operacoes_grupo on public.ordem_operacoes(grupo);
create index if not exists idx_operacoes_status on public.ordem_operacoes(status);
-- Quanto a etapa precisa RODAR (cascata): producao liquida / (1 - desp% propria e
-- seguintes) + acerto(setup) das etapas seguintes. Base do "quanto rodar" (informativo
-- ao operador) e do KPI de desperdicio (apontado x o que deveria rodar). Em metros/un.
alter table public.ordem_operacoes
  add column if not exists qtd_rodar_est numeric;


-- =====================================================================
-- D) APONTAMENTOS (log append-only) + MOTIVOS DE PARADA
-- Os tempos reais sao DERIVADOS destes eventos (nunca digitados).
-- operador_id = quem fez o apontamento (via login).
-- =====================================================================

do $$ begin
  if not exists (select 1 from pg_type where typname = 'tipo_apontamento') then
    create type public.tipo_apontamento as enum (
      'setup_inicio','setup_fim',
      'prod_inicio','prod_fim',
      'parada_inicio','parada_fim',
      'lancamento',    -- metragem/quantidade rodada num trecho (usa qtd)
      'validada',      -- etapa de validacao concluida
      'reabertura',    -- etapa reaberta (os novos eventos somam aos anteriores)
      'observacao'     -- nota livre do operador por etapa (nao afeta status; texto em motivo)
    );
  end if;
end $$;
-- Para bancos que ja tinham o enum (v<=3.6): adiciona o valor novo de forma idempotente.
-- (Se o editor do Supabase reclamar de "transaction block", rode SO esta linha primeiro.)
alter type public.tipo_apontamento add value if not exists 'observacao';

create table if not exists public.apontamentos (
  id          uuid primary key default gen_random_uuid(),
  operacao_id uuid not null references public.ordem_operacoes(id) on delete cascade,
  tipo        public.tipo_apontamento not null,
  ts          timestamptz not null default now(),
  operador_id uuid not null default auth.uid() references auth.users(id),
  maquina     text,         -- maquina fisica escolhida (no setup_inicio)
  motivo      text,         -- para parada_inicio
  qtd         numeric       -- para 'lancamento' (metros/un) e setup_fim (desperdicio de setup)
);
-- Para bancos que ja aplicaram a v1 (sem a coluna maquina): adiciona agora.
alter table public.apontamentos add column if not exists maquina text;
create index if not exists idx_apont_operacao on public.apontamentos(operacao_id, ts);
create index if not exists idx_apont_operador on public.apontamentos(operador_id);

create table if not exists public.motivos_parada (
  id     bigint generated always as identity primary key,
  nome   text not null unique,
  ordem  integer not null default 0,
  ativo  boolean not null default true
);
insert into public.motivos_parada (nome, ordem) values
  ('Almoço',1),('Fim de expediente',2),('Troca de clichê',3),
  ('Quebra de máquina',4),('Falta de material',5),
  ('Aguardando aprovação',6),('Manutenção',7)
on conflict (nome) do nothing;


-- ---------------------------------------------------------------------
-- D.1) STATUS dirigido pelos apontamentos (state machine no servidor)
-- O operador so INSERE apontamentos (ja restritos por RLS a sua maquina)
-- e NUNCA faz UPDATE direto em ordem_operacoes. Um trigger traduz o evento
-- em status/maquina. Assim nao e preciso dar UPDATE de tabela ao operador
-- (evita que ele altere grupo, carreiras ou o estimado).
-- ---------------------------------------------------------------------
create or replace function public.aplicar_apontamento()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_modo public.modo_maquina;
begin
  -- Insercao manual (via apontamento_manual): o status e recalculado
  -- cronologicamente pela propria funcao, nao evento a evento.
  if coalesce(current_setting('app.apont_manual', true),'') = '1' then
    return new;
  end if;

  select g.modo into v_modo
  from public.ordem_operacoes oo
  join public.maquinas_grupos g on g.nome = oo.grupo
  where oo.id = new.operacao_id;

  update public.ordem_operacoes oo set
    maquina = case when new.tipo = 'setup_inicio' and new.maquina is not null
                   then new.maquina else oo.maquina end,
    -- ao escolher a sub-maquina no setup, re-snapshot da velocidade prevista e do
    -- tempo estimado pela velocidade DELA (ex.: VOREY 600 vs BROTECH 2000), em vez
    -- da nominal do grupo congelada na materializacao.
    vel_est = case when new.tipo = 'setup_inicio' and new.maquina is not null
                   then coalesce((select s.velocidade from public.maquinas_sub s
                                   where s.grupo = oo.grupo and s.nome = new.maquina
                                     and s.velocidade is not null and s.velocidade > 0),
                                 oo.vel_est)
                   else oo.vel_est end,
    prod_est_min = case when new.tipo = 'setup_inicio' and new.maquina is not null
                        then coalesce((select round(coalesce(oo.qtd_rodar_est, oo.qtd_est, 0) / s.velocidade * 60, 2)
                                        from public.maquinas_sub s
                                        where s.grupo = oo.grupo and s.nome = new.maquina
                                          and s.velocidade is not null and s.velocidade > 0),
                                      oo.prod_est_min)
                        else oo.prod_est_min end,
    status = (case new.tipo
      when 'setup_inicio'  then 'em_setup'
      when 'setup_fim'     then 'setup_ok'
      when 'prod_inicio'   then 'em_producao'
      when 'parada_inicio' then 'parado'
      when 'parada_fim'    then 'em_producao'
      when 'prod_fim'      then 'finalizada'
      when 'validada'      then 'finalizada'
      when 'reabertura'    then (case when v_modo = 'validacao' then 'aguardando' else 'setup_ok' end)
      else oo.status::text  -- 'lancamento' nao muda status
    end)::public.status_operacao,
    atualizado_em = now()
  where oo.id = new.operacao_id;
  return new;
end $$;

drop trigger if exists trg_aplicar_apontamento on public.apontamentos;
create trigger trg_aplicar_apontamento
  after insert on public.apontamentos
  for each row execute function public.aplicar_apontamento();

-- Integridade do log: para NAO-gestores (operadores), o servidor forca o
-- timestamp e o operador, e valida a maquina. Impede forjar ts (manipular
-- KPIs de tempo) ou informar maquina de outro grupo. Gestor/editor mantem
-- ts manual (para correcoes de historico).
create or replace function public.apont_forca_valores()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- Insercao manual validada por apontamento_manual: ts/operador ja corretos.
  -- (A GUC app.apont_manual so pode ser setada dentro daquela funcao SECURITY
  -- DEFINER; o cliente nao consegue seta-la pelo PostgREST.)
  if coalesce(current_setting('app.apont_manual', true),'') = '1' then
    return new;
  end if;
  if not public.posso_editar() then
    new.ts := now();
    new.operador_id := auth.uid();
    if new.maquina is not null and not exists (
      select 1 from public.maquinas_sub s
      join public.ordem_operacoes oo on oo.grupo = s.grupo
      where oo.id = new.operacao_id and s.nome = new.maquina
    ) then
      raise exception 'Maquina invalida para esta operacao.';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_apont_forca_valores on public.apontamentos;
create trigger trg_apont_forca_valores
  before insert on public.apontamentos
  for each row execute function public.apont_forca_valores();


-- ---------------------------------------------------------------------
-- D.2) STATUS implicado pelo ULTIMO evento (por ts) de uma operacao.
-- Usado apos insercoes manuais retroativas: o status passa a refletir o
-- evento cronologicamente mais recente, nao a ordem em que foram inseridos.
-- ---------------------------------------------------------------------
create or replace function public.status_operacao_log(p_op uuid)
returns public.status_operacao
language plpgsql stable security definer set search_path = public as $$
declare v_modo public.modo_maquina; v_tipo public.tipo_apontamento;
begin
  select g.modo into v_modo
  from public.ordem_operacoes oo
  join public.maquinas_grupos g on g.nome = oo.grupo
  where oo.id = p_op;
  -- 'lancamento' nao muda status; ignora na hora de deduzir o estado.
  select tipo into v_tipo from public.apontamentos
   where operacao_id = p_op and tipo <> 'lancamento'
   order by ts desc, id desc limit 1;
  if v_tipo is null then return 'aguardando'; end if;
  return (case v_tipo
    when 'setup_inicio'  then 'em_setup'
    when 'setup_fim'     then 'setup_ok'
    when 'prod_inicio'   then 'em_producao'
    when 'parada_inicio' then 'parado'
    when 'parada_fim'    then 'em_producao'
    when 'prod_fim'      then 'finalizada'
    when 'validada'      then 'finalizada'
    when 'reabertura'    then (case when v_modo = 'validacao' then 'aguardando' else 'setup_ok' end)
    else 'aguardando'
  end)::public.status_operacao;
end $$;

-- ---------------------------------------------------------------------
-- D.2b) EXCLUSAO de apontamento (correcao de erro de lancamento).
-- So GESTOR. LIFO: apaga o evento OPERACIONAL mais recente (ignora observacoes,
-- que sao avulsas) e recalcula o status cronologicamente. Para desfazer varios,
-- chama repetidas vezes (do ultimo ao primeiro). Destrutivo/irreversivel.
-- ---------------------------------------------------------------------
create or replace function public.excluir_ultimo_apontamento(p_operacao uuid)
returns public.status_operacao
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_status public.status_operacao;
begin
  if not public.sou_gestor() then
    raise exception 'Apenas o gestor pode excluir apontamentos.';
  end if;
  select id into v_id from public.apontamentos
   where operacao_id = p_operacao and tipo <> 'observacao'
   order by ts desc, id desc limit 1;
  if v_id is null then
    raise exception 'Nao ha apontamento para excluir nesta etapa.';
  end if;
  delete from public.apontamentos where id = v_id;
  v_status := public.status_operacao_log(p_operacao);
  update public.ordem_operacoes set status = v_status, atualizado_em = now()
   where id = p_operacao;
  return v_status;
end $$;

-- Exclusao de UMA observacao (avulsa; nao afeta status). So gestor.
create or replace function public.excluir_observacao(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.sou_gestor() then
    raise exception 'Apenas o gestor pode excluir observacoes.';
  end if;
  delete from public.apontamentos where id = p_id and tipo = 'observacao';
end $$;

grant execute on function public.excluir_ultimo_apontamento(uuid) to authenticated;
grant execute on function public.excluir_observacao(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- D.3) LANCAMENTO MANUAL (retroativo).
-- Resolve dois limites do fluxo normal de apontamento:
--   1) o trigger apont_forca_valores forca ts=now() para nao-gestor;
--   2) a RLS de insert exige operador_id = auth.uid().
-- Esta funcao roda como SECURITY DEFINER (RLS bypassada) e faz a propria
-- autorizacao: operador so lanca na sua maquina e em seu nome; gestor/editor
-- pode indicar o operador responsavel e usar qualquer data (correcao).
-- Insere um bloco fechado (inicio+fim) e recalcula o status cronologicamente.
-- p_bloco: 'setup' (metros = desperdicio) ou 'producao' (metros = produzido).
-- ---------------------------------------------------------------------
create or replace function public.apontamento_manual(
  p_operacao uuid,
  p_bloco    text,
  p_ini      timestamptz,
  p_fim      timestamptz,
  p_metros   numeric default 0,
  p_operador uuid default null,
  p_motivo   text default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_grupo    text;
  v_maq      text;
  v_editor   boolean := public.posso_editar();
  v_oper     uuid;
  v_lim_dias int;
begin
  select grupo, maquina into v_grupo, v_maq
  from public.ordem_operacoes where id = p_operacao;
  if v_grupo is null then
    raise exception 'Operacao inexistente.';
  end if;

  -- Autorizacao (RLS e bypassada em SECURITY DEFINER; validar aqui).
  if not v_editor and not public.grupo_na_minha_maquina(v_grupo) then
    raise exception 'Sem permissao para lancar nesta operacao.';
  end if;

  -- Operador responsavel.
  if v_editor then
    v_oper := coalesce(p_operador, auth.uid());
    if not exists (select 1 from public.profiles where id = v_oper) then
      raise exception 'Operador invalido.';
    end if;
  else
    v_oper := auth.uid();  -- operador so lanca em seu proprio nome
  end if;

  -- Validacao de tempo e quantidade.
  if p_ini is null or p_fim is null or p_ini >= p_fim then
    raise exception 'Intervalo invalido: o inicio deve ser antes do fim.';
  end if;
  if p_fim > now() + interval '10 minutes' then
    raise exception 'O fim nao pode ser no futuro.';
  end if;
  v_lim_dias := case when v_editor then 365 else 30 end;
  if p_ini < now() - make_interval(days => v_lim_dias) then
    raise exception 'Data muito antiga (limite de % dias).', v_lim_dias;
  end if;
  if coalesce(p_metros,0) < 0 then
    raise exception 'Metros invalidos.';
  end if;

  -- Sinaliza aos triggers que estes inserts sao manuais e ja validados:
  -- preservam ts/operador e nao mexem no status evento a evento.
  perform set_config('app.apont_manual','1', true);

  if p_bloco = 'setup' then
    insert into public.apontamentos(operacao_id,tipo,ts,operador_id,maquina)
      values (p_operacao,'setup_inicio',p_ini,v_oper,v_maq);
    insert into public.apontamentos(operacao_id,tipo,ts,operador_id,qtd)
      values (p_operacao,'setup_fim',p_fim,v_oper,coalesce(p_metros,0));
  elsif p_bloco = 'producao' then
    insert into public.apontamentos(operacao_id,tipo,ts,operador_id,maquina)
      values (p_operacao,'prod_inicio',p_ini,v_oper,v_maq);
    if coalesce(p_metros,0) > 0 then
      insert into public.apontamentos(operacao_id,tipo,ts,operador_id,qtd)
        values (p_operacao,'lancamento',p_fim,v_oper,p_metros);
    end if;
    insert into public.apontamentos(operacao_id,tipo,ts,operador_id)
      values (p_operacao,'prod_fim',p_fim,v_oper);
  else
    raise exception 'Bloco invalido (use setup ou producao).';
  end if;

  -- Recalcula o status pelo evento cronologicamente mais recente.
  update public.ordem_operacoes oo
     set status = public.status_operacao_log(p_operacao),
         atualizado_em = now()
   where oo.id = p_operacao;

  -- Re-snapshot da velocidade/tempo estimado pela sub-maquina da operacao (se houver).
  if v_maq is not null then
    update public.ordem_operacoes oo
       set vel_est = coalesce((select s.velocidade from public.maquinas_sub s
                                 where s.grupo = oo.grupo and s.nome = v_maq
                                   and s.velocidade is not null and s.velocidade > 0),
                              oo.vel_est),
           prod_est_min = coalesce((select round(coalesce(oo.qtd_rodar_est, oo.qtd_est, 0) / s.velocidade * 60, 2)
                                      from public.maquinas_sub s
                                      where s.grupo = oo.grupo and s.nome = v_maq
                                        and s.velocidade is not null and s.velocidade > 0),
                                   oo.prod_est_min)
     where oo.id = p_operacao;
  end if;

  perform set_config('app.apont_manual','', true);
end $$;

grant execute on function public.status_operacao_log(uuid) to authenticated;
grant execute on function public.apontamento_manual(uuid,text,timestamptz,timestamptz,numeric,uuid,text) to authenticated;


-- =====================================================================
-- E) RLS
-- =====================================================================
alter table public.produtos            enable row level security;
alter table public.produto_conversoes  enable row level security;
alter table public.produto_etapas      enable row level security;
alter table public.ordens              enable row level security;
alter table public.ordem_operacoes     enable row level security;
alter table public.apontamentos        enable row level security;
alter table public.motivos_parada      enable row level security;

-- Helper: o grupo informado esta nas maquinas do operador logado?
create or replace function public.grupo_na_minha_maquina(p_grupo text)
returns boolean language sql stable security definer set search_path = public
as $$ select p_grupo = any(public.minhas_maquinas()); $$;

-- Todas as policies sao recriadas com DROP IF EXISTS antes, para o arquivo
-- poder ser re-executado sem erro ("policy already exists").

-- --- Ficha tecnica: leitura autenticado; escrita gestor/editor ---
drop policy if exists "produtos: le" on public.produtos;
create policy "produtos: le" on public.produtos
  for select using (auth.role() = 'authenticated');
drop policy if exists "produtos: escreve" on public.produtos;
create policy "produtos: escreve" on public.produtos
  for all using (public.posso_editar()) with check (public.posso_editar());

drop policy if exists "conv: le" on public.produto_conversoes;
create policy "conv: le" on public.produto_conversoes
  for select using (auth.role() = 'authenticated');
drop policy if exists "conv: escreve" on public.produto_conversoes;
create policy "conv: escreve" on public.produto_conversoes
  for all using (public.posso_editar()) with check (public.posso_editar());

drop policy if exists "etapas: le" on public.produto_etapas;
create policy "etapas: le" on public.produto_etapas
  for select using (auth.role() = 'authenticated');
drop policy if exists "etapas: escreve" on public.produto_etapas;
create policy "etapas: escreve" on public.produto_etapas
  for all using (public.posso_editar()) with check (public.posso_editar());

-- --- Ordens: ve_tudo ve todas; operador ve so as que tem operacao na maquina dele ---
drop policy if exists "ordens: leitura por papel" on public.ordens;
create policy "ordens: leitura por papel" on public.ordens
  for select using (
    public.ve_tudo()
    or exists (
      select 1 from public.ordem_operacoes oo
      where oo.ordem_id = ordens.id
        and public.grupo_na_minha_maquina(oo.grupo)
    )
  );
-- Escrita de ordens (upload/merge): so gestor
drop policy if exists "ordens: gestor escreve" on public.ordens;
create policy "ordens: gestor escreve" on public.ordens
  for all using (public.sou_gestor()) with check (public.sou_gestor());

-- --- Operacoes: ve_tudo OU operador do grupo ---
-- Remove a policy da v1 que dava UPDATE de tabela ao operador (privilege escalation).
drop policy if exists "operacoes: operador atualiza status" on public.ordem_operacoes;
drop policy if exists "operacoes: leitura por papel" on public.ordem_operacoes;
create policy "operacoes: leitura por papel" on public.ordem_operacoes
  for select using (
    public.ve_tudo() or public.grupo_na_minha_maquina(grupo)
  );
-- Escrita direta (materializacao, estimado, correcoes): so gestor/editor.
-- O OPERADOR nao recebe UPDATE de tabela: o status muda pelo trigger
-- trg_aplicar_apontamento ao inserir apontamentos (ver secao D.1).
-- (RLS filtra linha; nao filtra coluna — por isso nao damos UPDATE ao operador.)
drop policy if exists "operacoes: gestor materializa" on public.ordem_operacoes;
create policy "operacoes: gestor materializa" on public.ordem_operacoes
  for all using (public.posso_editar()) with check (public.posso_editar());

-- --- Apontamentos: operador insere so na sua maquina e so em seu nome ---
drop policy if exists "apont: leitura por papel" on public.apontamentos;
create policy "apont: leitura por papel" on public.apontamentos
  for select using (
    public.ve_tudo() or exists (
      select 1 from public.ordem_operacoes oo
      where oo.id = apontamentos.operacao_id
        and public.grupo_na_minha_maquina(oo.grupo)
    )
  );
drop policy if exists "apont: insere" on public.apontamentos;
create policy "apont: insere" on public.apontamentos
  for insert with check (
    operador_id = auth.uid()
    and (
      public.posso_editar()
      or exists (
        select 1 from public.ordem_operacoes oo
        where oo.id = operacao_id and public.grupo_na_minha_maquina(oo.grupo)
      )
    )
  );
-- Correcao/exclusao de apontamento: so gestor (log e append-only para operador)
drop policy if exists "apont: gestor corrige" on public.apontamentos;
create policy "apont: gestor corrige" on public.apontamentos
  for delete using (public.sou_gestor());

-- --- Motivos de parada: leitura autenticado; escrita gestor ---
drop policy if exists "motivos: le" on public.motivos_parada;
create policy "motivos: le" on public.motivos_parada
  for select using (auth.role() = 'authenticated');
drop policy if exists "motivos: gestor escreve" on public.motivos_parada;
create policy "motivos: gestor escreve" on public.motivos_parada
  for all using (public.sou_gestor()) with check (public.sou_gestor());


-- =====================================================================
-- F) FUNCOES E VIEWS DE KPI
-- Tempos reais derivados do log: pareia o n-esimo inicio com o n-esimo fim.
-- =====================================================================

-- Duracao total (ms) de pares (inicio,fim) de uma operacao.
create or replace function public.dur_apont(p_op uuid, p_ini public.tipo_apontamento, p_fim public.tipo_apontamento)
returns bigint language sql stable security definer set search_path = public
as $$
  with i as (
    select ts, row_number() over (order by ts) rn
    from public.apontamentos where operacao_id = p_op and tipo = p_ini
  ),
  f as (
    select ts, row_number() over (order by ts) rn
    from public.apontamentos where operacao_id = p_op and tipo = p_fim
  )
  select coalesce(sum( (extract(epoch from (f.ts - i.ts)) * 1000)::bigint ), 0)
  from i join f on f.rn = i.rn;
$$;

-- KPI por OPERACAO: estimado (snapshot) x real (derivado dos eventos).
create or replace view public.v_operacao_kpi with (security_invoker = true) as
select
  oo.id              as operacao_id,
  oo.ordem_id,
  o.pedido, o.item,
  oo.etapa_idx,
  oo.grupo,
  oo.maquina,
  -- quem produziu (operador do primeiro prod_inicio, se houver)
  (select a.operador_id from public.apontamentos a
     where a.operacao_id = oo.id and a.tipo = 'prod_inicio'
     order by a.ts limit 1) as operador_id,
  oo.status,
  -- reais (minutos)
  round(public.dur_apont(oo.id,'setup_inicio','setup_fim')/60000.0, 2)  as setup_real_min,
  round((public.dur_apont(oo.id,'prod_inicio','prod_fim')
         - public.dur_apont(oo.id,'parada_inicio','parada_fim'))/60000.0, 2) as prod_real_min,
  round(public.dur_apont(oo.id,'parada_inicio','parada_fim')/60000.0, 2) as parada_min,
  -- quantidade produzida real (soma dos lancamentos)
  coalesce((select sum(a.qtd) from public.apontamentos a
            where a.operacao_id = oo.id and a.tipo = 'lancamento'), 0) as qtd_real,
  -- desperdicio de setup real (qtd gravada no setup_fim)
  coalesce((select sum(a.qtd) from public.apontamentos a
            where a.operacao_id = oo.id and a.tipo = 'setup_fim'), 0) as desp_setup_real,
  -- estimados (snapshot)
  oo.setup_est_min, oo.prod_est_min, oo.qtd_est, oo.unidade_est,
  oo.desp_setup_est, oo.desp_prod_est,
  -- datas (para filtro de periodo na tela de KPIs)
  (select min(a.ts) from public.apontamentos a
     where a.operacao_id = oo.id and a.tipo in ('setup_inicio','prod_inicio')) as inicio_prod,
  (select max(a.ts) from public.apontamentos a
     where a.operacao_id = oo.id and a.tipo = 'prod_fim') as fim_prod,
  (select max(a.ts) from public.apontamentos a
     where a.operacao_id = oo.id) as ultimo_evento,
  coalesce(
    (select max(a.ts) from public.apontamentos a where a.operacao_id = oo.id and a.tipo = 'prod_fim'),
    (select max(a.ts) from public.apontamentos a where a.operacao_id = oo.id)
  ) as data_ref,
  -- velocidade prevista (nominal da sub-maquina escolhida) e quanto PRECISA rodar (cascata)
  oo.vel_est,
  oo.qtd_rodar_est,
  -- cliente e descricao da OS (para filtros/colunas e popup de detalhe)
  o.cliente_codigo,
  o.cliente_nome,
  coalesce(pr.descricao, o.descricao_origem) as descricao
from public.ordem_operacoes oo
join public.ordens o on o.id = oo.ordem_id
left join public.produtos pr on pr.codigo_pa = o.produto_codigo;

-- KPI por MAQUINA (agregado). Tempo rodando = setup + producao liquida.
-- OBS: "Disponibilidade" e "OEE" completos exigem o TEMPO DISPONIVEL
-- (calendario/turnos), que ainda nao modelamos (ver secao de decisao).
-- Aqui ja entregamos tempo rodando, paradas, metros e estimado x real.
create or replace view public.v_kpi_maquina with (security_invoker = true) as
select
  grupo,
  maquina,
  count(*)                              as operacoes,
  round(sum(setup_real_min),2)          as setup_min,
  round(sum(prod_real_min),2)           as producao_min,
  round(sum(parada_min),2)              as parada_min,
  round(sum(setup_real_min+prod_real_min),2) as tempo_rodando_min,
  sum(qtd_real)                         as qtd_produzida,
  round(sum(prod_real_min) - sum(prod_est_min),2) as desvio_prod_min
from public.v_operacao_kpi
group by grupo, maquina;

-- KPI por OPERADOR (agregado).
create or replace view public.v_kpi_operador with (security_invoker = true) as
select
  k.operador_id,
  p.nome as operador_nome,
  count(*)                       as operacoes,
  round(sum(k.prod_real_min),2)  as producao_min,
  round(sum(k.parada_min),2)     as parada_min,
  sum(k.qtd_real)                as qtd_produzida,
  round(sum(k.prod_real_min) - sum(k.prod_est_min),2) as desvio_prod_min
from public.v_operacao_kpi k
left join public.profiles p on p.id = k.operador_id
where k.operador_id is not null
group by k.operador_id, p.nome;

-- Detalhe de cada parada (pareia o n-esimo parada_inicio com o n-esimo parada_fim),
-- com motivo, maquina, operador e minutos. Base do KPI de "paradas por motivo"
-- (agregado no cliente, com filtro de periodo pela coluna `inicio`).
create or replace view public.v_parada_detalhe with (security_invoker = true) as
with pi as (
  select a.operacao_id, a.ts, a.motivo, a.operador_id,
         row_number() over (partition by a.operacao_id order by a.ts) rn
  from public.apontamentos a where a.tipo = 'parada_inicio'
),
pf as (
  select a.operacao_id, a.ts,
         row_number() over (partition by a.operacao_id order by a.ts) rn
  from public.apontamentos a where a.tipo = 'parada_fim'
)
select pi.operacao_id,
       oo.grupo, oo.maquina,
       coalesce(pi.motivo,'(sem motivo)') as motivo,
       pi.operador_id,
       pi.ts as inicio,
       pf.ts as fim,
       round(extract(epoch from (pf.ts - pi.ts))/60.0, 2) as minutos
from pi
join pf on pf.operacao_id = pi.operacao_id and pf.rn = pi.rn
join public.ordem_operacoes oo on oo.id = pi.operacao_id;

grant select on public.v_operacao_kpi, public.v_kpi_maquina,
                public.v_kpi_operador, public.v_parada_detalhe to authenticated;

-- ---------------------------------------------------------------------
-- G) REALTIME: o painel do gestor acompanha ao vivo os apontamentos.
-- Publica as tabelas na publication do Supabase Realtime (idempotente:
-- ignora se ja estao publicadas). A RLS continua valendo nos eventos.
-- ---------------------------------------------------------------------
do $$ begin
  begin alter publication supabase_realtime add table public.apontamentos; exception when others then null; end;
  begin alter publication supabase_realtime add table public.ordem_operacoes; exception when others then null; end;
end $$;


-- =====================================================================
-- FIM DO 13_producao_apontamentos.sql (RASCUNHO)
--
-- DECISOES EM ABERTO (para a revisao):
--   1) OEE/Disponibilidade: precisam de TEMPO DISPONIVEL (turnos/calendario
--      por maquina). Sugestao: tabela `maquina_turnos` (dia/semana, horas)
--      numa fase seguinte. Sem isso, entregamos tempo rodando x paradas.
--   2) Restricao por maquina fisica (nao so por grupo): hoje maquinas_permitidas
--      e por grupo. Se um operador precisar ver so 1 sub-maquina, trocar para
--      lista de sub-maquinas (ajuste em profiles + grupo_na_minha_maquina).
--   3) Materializacao das operacoes e do ESTIMADO: feita pelo app (ou por uma
--      function dedicada) quando a OS entra em producao. A formula de estimativa
--      e a mesma ja validada no prototipo (producao.html).
--   4) Aposentar o upload de PCP: as operacoes vem do roteiro (produto_etapas),
--      e o status vem dos apontamentos (ajustar rastrear_pedido depois).
-- =====================================================================
