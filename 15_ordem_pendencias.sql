-- 15_ordem_pendencias.sql  (idempotente / reaplicavel)
-- Pendencias / impedimentos de uma OS: "Solicitar faca", "Solicitar clichê",
-- "Aguardando material", "Outro". Da visibilidade do que trava o trabalho.
-- Abertura/resolucao por gestor/editor (posso_editar()); leitura p/ todos autenticados.

create table if not exists public.ordem_pendencias(
  id uuid primary key default gen_random_uuid(),
  ordem_id uuid not null references public.ordens(id) on delete cascade,
  tipo text not null,
  obs text,
  status text not null default 'aberta',   -- 'aberta' | 'resolvida'
  criado_por uuid default auth.uid(),
  criado_em timestamptz not null default now(),
  resolvido_por uuid,
  resolvido_em timestamptz
);
-- Datas opcionais (criado_em = data de abertura da pendencia):
alter table public.ordem_pendencias add column if not exists data_solicitacao date;  -- ex.: data em que a faca/clichê foi solicitado
alter table public.ordem_pendencias add column if not exists previsao_chegada date;  -- ex.: previsao de chegada do material/faca

create index if not exists idx_ordem_pend_ordem  on public.ordem_pendencias(ordem_id);
create index if not exists idx_ordem_pend_status on public.ordem_pendencias(status);

alter table public.ordem_pendencias enable row level security;

drop policy if exists pend_select on public.ordem_pendencias;
create policy pend_select on public.ordem_pendencias
  for select to authenticated using (true);

drop policy if exists pend_insert on public.ordem_pendencias;
create policy pend_insert on public.ordem_pendencias
  for insert to authenticated with check (posso_editar());

drop policy if exists pend_update on public.ordem_pendencias;
create policy pend_update on public.ordem_pendencias
  for update to authenticated using (posso_editar()) with check (posso_editar());

drop policy if exists pend_delete on public.ordem_pendencias;
create policy pend_delete on public.ordem_pendencias
  for delete to authenticated using (sou_gestor());
