-- 17_pendencia_tipos.sql  (idempotente / reaplicavel)
-- Tipos de pendencia editaveis pelo gestor (antes eram fixos no codigo).
-- Tambem garante escrita do gestor em motivos_parada (para a aba "Listas").

create table if not exists public.pendencia_tipos(
  id uuid primary key default gen_random_uuid(),
  nome text not null unique,
  ordem integer not null default 0,
  ativo boolean not null default true
);

-- Seed inicial (so quando a tabela ainda esta vazia):
insert into public.pendencia_tipos(nome,ordem)
select v.nome, v.ord from (values
  ('Solicitar faca',1),('Solicitar clichê',2),('Aguardando material',3),('Outro',4)
) as v(nome,ord)
where not exists (select 1 from public.pendencia_tipos);

alter table public.pendencia_tipos enable row level security;
drop policy if exists ptipos_select on public.pendencia_tipos;
create policy ptipos_select on public.pendencia_tipos for select to authenticated using (true);
drop policy if exists ptipos_write on public.pendencia_tipos;
create policy ptipos_write on public.pendencia_tipos for all to authenticated using (sou_gestor()) with check (sou_gestor());

-- Garante leitura/escrita de gestor em motivos_parada (idempotente; aditivo as policies do 13_):
alter table public.motivos_parada enable row level security;
drop policy if exists motivos_select_all on public.motivos_parada;
create policy motivos_select_all on public.motivos_parada for select to authenticated using (true);
drop policy if exists motivos_write_gestor on public.motivos_parada;
create policy motivos_write_gestor on public.motivos_parada for all to authenticated using (sou_gestor()) with check (sou_gestor());
