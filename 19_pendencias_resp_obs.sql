-- 19_pendencias_resp_obs.sql  (idempotente / reaplicavel)
-- (1) Responsavel pela pendencia; (2) HISTORICO de observacoes (com autor), em vez
-- de um unico campo que era sobrescrito.

alter table public.ordem_pendencias
  add column if not exists responsavel_id uuid;   -- soft ref a profiles/auth.users

create table if not exists public.pendencia_observacoes(
  id uuid primary key default gen_random_uuid(),
  pendencia_id uuid not null references public.ordem_pendencias(id) on delete cascade,
  texto text not null,
  autor_id uuid default auth.uid(),
  criado_em timestamptz not null default now()
);
create index if not exists idx_pend_obs_pend on public.pendencia_observacoes(pendencia_id);

alter table public.pendencia_observacoes enable row level security;
drop policy if exists pobs_select on public.pendencia_observacoes;
create policy pobs_select on public.pendencia_observacoes for select to authenticated using (true);
drop policy if exists pobs_insert on public.pendencia_observacoes;
-- autor_id tem default auth.uid(); a policy EXIGE que seja o proprio usuario,
-- para ninguem forjar a autoria no historico (o front nao envia autor_id).
-- Sem policy de UPDATE => autor_id/criado_em nao podem ser alterados depois.
create policy pobs_insert on public.pendencia_observacoes for insert to authenticated with check (posso_editar() and autor_id = auth.uid());
drop policy if exists pobs_delete on public.pendencia_observacoes;
create policy pobs_delete on public.pendencia_observacoes for delete to authenticated using (sou_gestor());
