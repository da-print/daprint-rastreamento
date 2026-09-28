-- =====================================================================
-- D&A - Rastreamento de Pedidos | 06_gestao_usuarios.sql
-- Suporte a tela de gestao de usuarios (listagem).
-- A CRIACAO/REMOCAO e feita pela Edge Function 'gerenciar-usuarios'
-- (precisa da service_role). Aqui fica so a LEITURA, para o painel listar.
--
-- COMO USAR: rodar no SQL Editor, DEPOIS de 01..05.
-- =====================================================================

-- Funcao que lista os usuarios com seus papeis e vinculos.
-- Retorna tambem o "login" do operador (extraido do e-mail de fachada)
-- e o e-mail real de quem tem. So o gestor consegue executar.
create or replace function public.listar_usuarios()
returns table (
  id uuid,
  nome text,
  papel public.papel_usuario,
  codigo_vendedor text,
  maquinas_permitidas text[],
  login_ou_email text,
  criado_em timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.id,
    p.nome,
    p.papel,
    p.codigo_vendedor,
    p.maquinas_permitidas,
    case
      when u.email like '%@operador.daprint.local'
        then split_part(u.email, '@', 1)      -- operador: mostra so o login
      else u.email                            -- demais: mostra o e-mail real
    end as login_ou_email,
    p.criado_em
  from public.profiles p
  join auth.users u on u.id = p.id
  where public.sou_gestor()   -- so o gestor recebe a lista; senao, vazio
  order by p.criado_em;
$$;

revoke all on function public.listar_usuarios() from anon;
grant execute on function public.listar_usuarios() to authenticated;

-- =====================================================================
-- FIM DO 06_gestao_usuarios.sql
-- =====================================================================
