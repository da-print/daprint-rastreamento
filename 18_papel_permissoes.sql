-- 18_papel_permissoes.sql  (idempotente / reaplicavel)
-- Flags de interface por papel (o gestor edita na aba "Permissões").
-- SEM seed: a ausencia de linha = usa o padrao atual do sistema (fallback no front),
-- entao aplicar + publicar NAO muda nada ate o gestor marcar/desmarcar algo.
-- OBS seguranca: estes flags controlam o que a INTERFACE mostra/habilita. A protecao
-- real dos dados continua na RLS de cada tabela.

create table if not exists public.papel_permissoes(
  papel text not null,
  chave text not null,
  permitido boolean not null default false,
  primary key(papel,chave)
);

alter table public.papel_permissoes enable row level security;
drop policy if exists perm_select on public.papel_permissoes;
create policy perm_select on public.papel_permissoes for select to authenticated using (true);
drop policy if exists perm_write on public.papel_permissoes;
create policy perm_write on public.papel_permissoes for all to authenticated using (sou_gestor()) with check (sou_gestor());
