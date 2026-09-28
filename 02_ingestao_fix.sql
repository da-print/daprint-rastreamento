-- =====================================================================
-- D&A - Rastreamento de Pedidos | 02_ingestao.sql
-- Funcoes de upload ATOMICO (Opcao B) + limpeza de overrides (Opcao B carencia)
--
-- COMO USAR: rodar este arquivo INTEIRO no SQL Editor do Supabase,
-- DEPOIS de ja ter rodado o 01_schema.sql.
--
-- Garantias de design (ja aprovadas):
--   - Upload troca a "foto do dia"; NUNCA toca na tabela overrides
--   - Cada funcao de upload e atomica: ou grava tudo, ou nada (sem meio-termo)
--   - So gestor pode executar as funcoes de upload
--   - Overrides so somem apos 45 dias ausentes das bases (carencia)
-- =====================================================================


-- =====================================================================
-- 1) UPLOAD DE CLIENTES (cadastro mestre: faz UPSERT, nao apaga)
-- Recebe um array JSON com as linhas ja tratadas pelo front.
-- Clientes e mestre: inserimos novos e atualizamos existentes, sem apagar
-- quem nao veio (evita perder cadastro por um export parcial).
-- =====================================================================
create or replace function public.upload_clientes(linhas jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  if not public.sou_gestor() then
    raise exception 'Apenas o gestor pode subir planilhas.';
  end if;

  insert into public.clientes
    (codigo, razao_social, nome_reduzido, cnpj, cnpj_digitos,
     vendedor, codigo_vendedor, atualizado_em)
  select
    x.codigo, x.razao_social, x.nome_reduzido, x.cnpj, x.cnpj_digitos,
    x.vendedor, x.codigo_vendedor, now()
  from jsonb_to_recordset(linhas) as x(
    codigo text, razao_social text, nome_reduzido text, cnpj text,
    cnpj_digitos text, vendedor text, codigo_vendedor text
  )
  on conflict (codigo) do update set
    razao_social = excluded.razao_social,
    nome_reduzido = excluded.nome_reduzido,
    cnpj = excluded.cnpj,
    cnpj_digitos = excluded.cnpj_digitos,
    vendedor = excluded.vendedor,
    codigo_vendedor = excluded.codigo_vendedor,
    atualizado_em = now();

  get diagnostics n = row_count;
  return n;
end;
$$;


-- =====================================================================
-- 2) UPLOAD DE PEDIDOS ABERTOS (substitui a foto do dia, atomico)
-- Apaga tudo e insere o novo dentro da mesma transacao (funcao = 1 transacao).
-- NAO toca em overrides.
-- =====================================================================
create or replace function public.upload_pedidos_abertos(linhas jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  if not public.sou_gestor() then
    raise exception 'Apenas o gestor pode subir planilhas.';
  end if;

  delete from public.pedidos_abertos where true;

  insert into public.pedidos_abertos
    (pedido, item, cliente_codigo, cliente_nome_origem, produto, produto_desc,
     saldo, um, saldo2, um2, entrega, status_producao_origem, ml,
     pedido_cliente, atualizado_em)
  select
    x.pedido, x.item, x.cliente_codigo, x.cliente_nome_origem, x.produto,
    x.produto_desc, x.saldo, x.um, x.saldo2, x.um2, x.entrega,
    x.status_producao_origem, x.ml, x.pedido_cliente, now()
  from jsonb_to_recordset(linhas) as x(
    pedido integer, item integer, cliente_codigo text, cliente_nome_origem text,
    produto text, produto_desc text, saldo numeric, um text, saldo2 numeric,
    um2 text, entrega date, status_producao_origem text, ml numeric,
    pedido_cliente text
  );

  get diagnostics n = row_count;
  return n;
end;
$$;


-- =====================================================================
-- 3) UPLOAD DE PCP (substitui a foto do dia, atomico)
-- =====================================================================
create or replace function public.upload_pcp(linhas jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  if not public.sou_gestor() then
    raise exception 'Apenas o gestor pode subir planilhas.';
  end if;

  delete from public.pcp where true;

  insert into public.pcp
    (numero_ordem, pedido, item, produto_code, cliente_code,
     grupo_maquinas, status_ordem, atualizado_em)
  select
    x.numero_ordem, x.pedido, x.item, x.produto_code, x.cliente_code,
    x.grupo_maquinas, x.status_ordem, now()
  from jsonb_to_recordset(linhas) as x(
    numero_ordem text, pedido integer, item integer, produto_code text,
    cliente_code text, grupo_maquinas text, status_ordem text
  );

  get diagnostics n = row_count;
  return n;
end;
$$;


-- =====================================================================
-- 4) UPLOAD DE FATURAMENTO (substitui a janela, atomico)
-- =====================================================================
create or replace function public.upload_faturamento(linhas jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  if not public.sou_gestor() then
    raise exception 'Apenas o gestor pode subir planilhas.';
  end if;

  delete from public.faturamento where true;

  insert into public.faturamento
    (pedido, item, numero_nf, pedido_cliente, atualizado_em)
  select
    x.pedido, x.item, x.numero_nf, x.pedido_cliente, now()
  from jsonb_to_recordset(linhas) as x(
    pedido integer, item integer, numero_nf text, pedido_cliente text
  );

  get diagnostics n = row_count;
  return n;
end;
$$;


-- =====================================================================
-- 5) LIMPEZA DE OVERRIDES COM CARENCIA (Opcao B aprovada)
-- Deve ser chamada logo APOS cada upload completo do dia.
-- Logica:
--   a) item que voltou a aparecer em qualquer base -> ausente_desde = NULL
--   b) item que NAO aparece em nenhuma base e ainda nao tinha marca
--      -> ausente_desde = hoje
--   c) override ausente ha mais de 45 dias -> excluido (limpeza de lixo)
-- NUNCA apaga override de item que ainda aparece nas bases.
-- =====================================================================
create or replace function public.limpar_overrides()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  if not public.sou_gestor() then
    raise exception 'Apenas o gestor pode executar a limpeza.';
  end if;

  -- (a) reapareceu: zera a marca de ausencia
  update public.overrides o
  set ausente_desde = null
  where o.ausente_desde is not null
    and (
      exists (select 1 from public.pedidos_abertos p
              where p.pedido = o.pedido and p.item = o.item)
      or exists (select 1 from public.faturamento f
              where f.pedido = o.pedido and f.item = o.item)
    );

  -- (b) sumiu agora: marca a data de ausencia
  update public.overrides o
  set ausente_desde = current_date
  where o.ausente_desde is null
    and not exists (select 1 from public.pedidos_abertos p
              where p.pedido = o.pedido and p.item = o.item)
    and not exists (select 1 from public.faturamento f
              where f.pedido = o.pedido and f.item = o.item);

  -- (c) ausente ha mais de 45 dias: exclui
  delete from public.overrides o
  where o.ausente_desde is not null
    and o.ausente_desde < current_date - interval '45 days';

  get diagnostics n = row_count;  -- linhas excluidas na etapa (c)
  return n;
end;
$$;


-- =====================================================================
-- Permissoes: so usuarios autenticados podem sequer tentar chamar.
-- O check de "sou_gestor()" dentro de cada funcao e a trava real.
-- =====================================================================
revoke all on function public.upload_clientes(jsonb)        from anon;
revoke all on function public.upload_pedidos_abertos(jsonb) from anon;
revoke all on function public.upload_pcp(jsonb)             from anon;
revoke all on function public.upload_faturamento(jsonb)     from anon;
revoke all on function public.limpar_overrides()            from anon;

grant execute on function public.upload_clientes(jsonb)        to authenticated;
grant execute on function public.upload_pedidos_abertos(jsonb) to authenticated;
grant execute on function public.upload_pcp(jsonb)             to authenticated;
grant execute on function public.upload_faturamento(jsonb)     to authenticated;
grant execute on function public.limpar_overrides()            to authenticated;


-- =====================================================================
-- FIM DO 02_ingestao.sql
-- =====================================================================
