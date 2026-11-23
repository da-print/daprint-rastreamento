-- 31_custo_mp.sql  (idempotente / reaplicavel)
-- CUSTO DO PRODUTO VENDIDO — v2, UNIFICADO nas MATERIAS-PRIMAS.
--
-- Substitui o 22_custo_produto.sql (que fica ORFAO — NAO aplicar o 22_). Em vez de
-- tabelas separadas `acabamentos` e `ribbons`, os insumos de custo passam a ser
-- MATERIAS-PRIMAS com um `tipo` e os campos de calculo de cada tipo. A ficha do
-- produto (uma so) referencia: substrato (materia_prima_id, ja existia), ribbon
-- (ribbon_id) e acabamentos aplicados (produto_acabamentos).
--
-- Tudo ADITIVO. O app degrada com aviso se esta migration nao estiver aplicada.
-- NAO altera producao/apontamento. Depende de: 20_/21_ (materias_primas, produtos),
-- 13_/09_ (produtos, maquinas_sub).
--
-- Decisoes (validadas com o usuario):
--  * Tudo em materias_primas por `tipo` (substrato|laminacao|verniz|ribbon|stamping).
--  * Custo em materias_primas e legivel por todos (como o valor/m2 do substrato ja e);
--    a UI esconde de quem nao e gestor/editor. Os cadastros SENSIVEIS novos
--    (produto_acabamentos, maquinas_sub_custo, custo_parametros) ficam restritos.
--  * Tinta por GRUPO: FLEXO (por_cor) = gramatura x preco_kg x ocupacao x n cores
--    (custo_parametros, global). DIGITAL = insumo por m2 por SUB-MAQUINA
--    (maquinas_sub_custo.insumo_m2). Cliche de cor so na FLEXO (digital nao gera).
--  * Cliche/zinco extra vem de acabamentos (cold -> cliche; hot -> zinco).

-- =====================================================================
-- A) MATERIAS-PRIMAS: tipo + campos de calculo por tipo (todos default 0/false)
--    valor_m2/largura_mm/icms_pct/ipi_pct ja existem (20_/21_) e sao reusados.
-- =====================================================================
alter table public.materias_primas
  add column if not exists tipo          text    not null default 'substrato', -- substrato|laminacao|verniz|tinta|ribbon|stamping
  add column if not exists gramatura     numeric not null default 0,  -- verniz: fracao do quilo por m2 (ex. 0,003)
  add column if not exists preco_kg      numeric not null default 0,  -- verniz: R$/kg
  add column if not exists comprimento_m numeric not null default 0,  -- ribbon: metros por rolo
  add column if not exists valor_rolo    numeric not null default 0,  -- ribbon: R$/rolo
  add column if not exists setup_m       numeric not null default 0,  -- acabamento: metros de acerto somados ao setup
  add column if not exists gera_cliche   boolean not null default false, -- verniz localizado / cold stamping -> +1 cliche
  add column if not exists gera_zinco    boolean not null default false, -- hot stamping -> ferramental zinco
  add column if not exists sub_id        bigint,                         -- tinta DIGITAL: sub-maquina (Bobst/Conica) a que o insumo pertence
  add column if not exists tinta_branca  boolean not null default false; -- tinta DIGITAL: e o add-on de branco (soma ao base da mesma sub)
comment on column public.materias_primas.tipo is 'substrato|laminacao|verniz|tinta|cliche|ribbon|stamping — define quais campos de custo valem. tinta: preco_kg (flexo) OU valor_m2+sub_id (digital). cliche: valor_m2 = R$/cm2.';

-- maquina de CUSTO por etapa do roteiro (sub-maquina pre-definida p/ a estruturacao de
-- custo). A PRODUCAO/PAINEL NAO le isto (continua pelo grupo + sub escolhida ao rodar).
alter table public.produto_etapas add column if not exists maquina_custo text;
-- FK soft sub_id -> maquinas_sub (tinta digital vinculada a uma sub)
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'materias_primas_sub_fkey') then
    alter table public.materias_primas
      add constraint materias_primas_sub_fkey
      foreign key (sub_id) references public.maquinas_sub(id) on delete set null;
  end if;
end $$;

-- =====================================================================
-- B) PRODUTOS: ingredientes de custo na ficha (uma ficha so). (repeticoes p/ cliche
--    ja existe em produto_etapas — 14_). Default 0/false: nao muda nada sem preencher.
-- =====================================================================
alter table public.produtos
  add column if not exists espaco_carreiras  numeric  not null default 0,  -- mm, entre carreiras (cliche)
  add column if not exists esqueleto_lateral numeric  not null default 0,  -- mm, total das duas bordas (cliche)
  add column if not exists chapado           boolean  not null default false, -- true = nao gera cliche de cor
  add column if not exists custo_faca        numeric  not null default 0,  -- R$ fixo por pedido
  add column if not exists ocupacao_tinta    numeric  not null default 0,  -- % ocupacao media de tinta
  add column if not exists ribbon_id         bigint,                       -- -> materias_primas (tipo ribbon)
  add column if not exists carreiras_ribbon  integer  not null default 1,
  add column if not exists tinta_branca      boolean  not null default false, -- flag na ficha: usa tinta branca (digital)
  add column if not exists impressao         text     not null default 'flexo', -- sem|digital|flexo (gatilho da ficha; so CUSTO/UI)
  add column if not exists carreiras         integer  not null default 1,     -- dados tecnicos p/ CLICHE (nao usado na producao)
  add column if not exists repeticoes        integer  not null default 1;     -- dados tecnicos p/ CLICHE (nao usado na producao)
-- FK soft ribbon_id -> materias_primas(id) (on delete set null).
-- Se o 22_ (orfao) foi aplicado, existe a FK antiga produtos_ribbon_id_fkey
-- (ribbon_id -> ribbons) que conflita; removemos antes de criar a nova.
do $$ begin
  if exists (select 1 from pg_constraint where conname = 'produtos_ribbon_id_fkey') then
    alter table public.produtos drop constraint produtos_ribbon_id_fkey;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'produtos_ribbon_mp_fkey') then
    alter table public.produtos
      add constraint produtos_ribbon_mp_fkey
      foreign key (ribbon_id) references public.materias_primas(id) on delete set null;
  end if;
end $$;

-- =====================================================================
-- C) ACABAMENTOS APLICADOS AO PRODUTO (link ficha -> materias_primas de acabamento)
-- =====================================================================
create table if not exists public.produto_acabamentos (
  id               bigint generated always as identity primary key,
  produto_codigo   text not null references public.produtos(codigo_pa) on delete cascade,
  materia_prima_id bigint not null references public.materias_primas(id) on delete cascade,
  ocupacao         numeric not null default 0,   -- verniz localizado: %
  fita_larg_mm     numeric,                       -- stamping: area estampada por etiqueta
  fita_alt_mm      numeric,                       -- stamping: area estampada por etiqueta
  valor_zinco      numeric not null default 0,    -- hot stamping: R$ fixo do ferramental (zinco)
  ordem            integer not null default 1,
  unique (produto_codigo, materia_prima_id)
);
-- Reconciliacao: se o 22_ (orfao) criou produto_acabamentos com o schema antigo
-- (acabamento_id -> acabamentos), o create acima e no-op. Ajusta p/ o novo schema.
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='produto_acabamentos' and column_name='acabamento_id') then
    alter table public.produto_acabamentos add column if not exists materia_prima_id bigint;
    begin alter table public.produto_acabamentos alter column acabamento_id drop not null; exception when others then null; end;
    if exists (select 1 from pg_constraint where conname='produto_acabamentos_acabamento_id_fkey') then
      alter table public.produto_acabamentos drop constraint produto_acabamentos_acabamento_id_fkey;
    end if;
    if not exists (select 1 from pg_constraint where conname='produto_acabamentos_materia_prima_id_fkey') then
      alter table public.produto_acabamentos add constraint produto_acabamentos_materia_prima_id_fkey foreign key (materia_prima_id) references public.materias_primas(id) on delete cascade;
    end if;
  end if;
end $$;

-- =====================================================================
-- D) HORA-MAQUINA + INSUMO DIGITAL por sub-maquina (tabela separada e RESTRITA,
--    pois maquinas_sub e lida por todos). insumo_m2 = custo digital por m2.
-- =====================================================================
create table if not exists public.maquinas_sub_custo (
  sub_id        bigint primary key references public.maquinas_sub(id) on delete cascade,
  custo_hora    numeric not null default 0,   -- R$/h da hora-maquina
  insumo_m2     numeric not null default 0,   -- R$/m2 do insumo digital (toner/tinta digital por m2)
  atualizado_em timestamptz not null default now()
);
-- se a tabela ja existia (de um 22_ aplicado por engano), garante a coluna nova:
alter table public.maquinas_sub_custo add column if not exists insumo_m2 numeric not null default 0;
comment on table public.maquinas_sub_custo is 'Custo por maquina fisica: hora-maquina (R$/h) e insumo digital (R$/m2). Leitura restrita (custo sensivel).';

-- =====================================================================
-- E) PARAMETROS GLOBAIS (tinta flexo por gramatura + cliche por cm2)
-- =====================================================================
create table if not exists public.custo_parametros (
  id                smallint primary key default 1 check (id = 1),
  preco_cliche_cm2  numeric not null default 0.17,
  tinta_gramatura   numeric not null default 0,
  tinta_preco_kg    numeric not null default 0,
  atualizado_em     timestamptz not null default now()
);
insert into public.custo_parametros (id) values (1) on conflict (id) do nothing;

-- =====================================================================
-- F) RLS. materias_primas e produtos JA tem policy (leitura aberta / escrita
--    posso_editar). As tabelas NOVAS trazem numero de custo sensivel -> leitura E
--    escrita so gestor/editor (posso_editar()).
-- =====================================================================
alter table public.produto_acabamentos enable row level security;
alter table public.maquinas_sub_custo  enable row level security;
alter table public.custo_parametros    enable row level security;

drop policy if exists pac_select on public.produto_acabamentos;
drop policy if exists pac_write  on public.produto_acabamentos;
create policy pac_select on public.produto_acabamentos for select to authenticated using (posso_editar());
create policy pac_write  on public.produto_acabamentos for all    to authenticated using (posso_editar()) with check (posso_editar());

drop policy if exists msc_select on public.maquinas_sub_custo;
drop policy if exists msc_write  on public.maquinas_sub_custo;
create policy msc_select on public.maquinas_sub_custo for select to authenticated using (posso_editar());
create policy msc_write  on public.maquinas_sub_custo for all    to authenticated using (posso_editar()) with check (posso_editar());

drop policy if exists cp_select on public.custo_parametros;
drop policy if exists cp_write  on public.custo_parametros;
create policy cp_select on public.custo_parametros for select to authenticated using (posso_editar());
create policy cp_write  on public.custo_parametros for all    to authenticated using (posso_editar()) with check (posso_editar());

-- =====================================================================
-- FIM DO 31_custo_mp.sql
-- =====================================================================
