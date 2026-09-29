-- =====================================================================
-- D&A - Rastreamento de Pedidos | 09_maquinas.sql
-- Torna as maquinas e sub-maquinas configuraveis pela tela (antes fixas no
-- codigo). Guarda tambem os parametros usados no calculo de tempo:
-- velocidade, setup e desperdicio.
--
-- COMO USAR: rodar no SQL Editor, DEPOIS de 01..08.
-- Ja vem semeada com a configuracao atual do sistema.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Grupos de maquina (ex: FLEXO 350) com parametros de grupo
-- ---------------------------------------------------------------------
create table if not exists public.maquinas_grupos (
  nome text primary key,               -- ex: 'FLEXO 350'
  display text,                        -- rotulo exibido (ex: 'FLEXO 350')
  icon text,                           -- sigla do icone (ex: 'F2')
  ordem_fluxo integer not null default 2, -- 1=pre-impressao ... 4=revisao
  setup_min integer not null default 0,   -- setup fixo em minutos
  desperdicio_m integer not null default 0, -- desperdicio em metros
  ordem_exibicao integer not null default 100 -- ordem na tela
);

-- ---------------------------------------------------------------------
-- Sub-maquinas (ex: ETIRAMA dentro de FLEXO 350) com velocidade propria
-- ---------------------------------------------------------------------
create table if not exists public.maquinas_sub (
  id bigint generated always as identity primary key,
  grupo text not null references public.maquinas_grupos(nome) on delete cascade,
  nome text not null,                  -- ex: 'ETIRAMA'
  velocidade integer,                  -- m/h ou un/h
  ordem_exibicao integer not null default 100,
  unique (grupo, nome)
);

-- ---------------------------------------------------------------------
-- RLS: leitura para autenticados; escrita so gestor
-- ---------------------------------------------------------------------
alter table public.maquinas_grupos enable row level security;
alter table public.maquinas_sub    enable row level security;

create policy "maq_grupos: autenticado le" on public.maquinas_grupos
  for select using (auth.role() = 'authenticated');
create policy "maq_grupos: gestor escreve" on public.maquinas_grupos
  for all using (public.sou_gestor()) with check (public.sou_gestor());

create policy "maq_sub: autenticado le" on public.maquinas_sub
  for select using (auth.role() = 'authenticated');
create policy "maq_sub: gestor escreve" on public.maquinas_sub
  for all using (public.sou_gestor()) with check (public.sou_gestor());

-- ---------------------------------------------------------------------
-- Semear com a configuracao atual do sistema
-- ---------------------------------------------------------------------
insert into public.maquinas_grupos (nome, display, icon, ordem_fluxo, setup_min, desperdicio_m, ordem_exibicao) values
  ('PRE-IMPRESSAO',        'PRÉ-IMPRESSÃO',          'PI', 1,  0,  0, 10),
  ('FLEXO 250',            'FLEXO 250',              'F1', 2, 90, 90, 20),
  ('FLEXO 350',            'FLEXO 350',              'F2', 2, 90, 90, 30),
  ('DIGITAL',              'DIGITAL',                'DG', 2, 20, 10, 40),
  ('TROQUELADORAS',        'TROQUELADORAS',          'TR', 3, 20, 10, 50),
  ('BATIDA',               'BATIDA',                 'BA', 3, 20, 15, 60),
  ('CORTE BROTECH / VOREY','CORTE BROTECH / VOREY',  'CB', 3, 20, 10, 70),
  ('REVISORAS',            'REVISORAS',              'RE', 4, 10, 10, 80),
  ('TERMICA',              'TÉRMICA',                'TH', 2, 10,  5, 90)
on conflict (nome) do nothing;

insert into public.maquinas_sub (grupo, nome, velocidade, ordem_exibicao) values
  ('FLEXO 250','FLEXO 1',1800,1),
  ('FLEXO 250','FLEXO 2',1800,2),
  ('FLEXO 250','FLEXO 3',1800,3),
  ('FLEXO 350','ETIRAMA',2400,1),
  ('FLEXO 350','KROMIA',2400,2),
  ('FLEXO 350','NACBRAS',2400,3),
  ('TROQUELADORAS','TROQUELADORA 1',2000,1),
  ('TROQUELADORAS','TROQUELADORA 2',2000,2),
  ('TROQUELADORAS','PULMÃO',2000,3),
  ('BATIDA','CHINESA',3000,1),
  ('BATIDA','TURO',3000,2),
  ('CORTE BROTECH / VOREY','BROTECH',2000,1),
  ('CORTE BROTECH / VOREY','VOREY',600,2),
  ('REVISORAS','REVISORA 1',2400,1),
  ('REVISORAS','REVISORA 2',2400,2)
on conflict (grupo, nome) do nothing;

-- =====================================================================
-- FIM DO 09_maquinas.sql
-- =====================================================================
