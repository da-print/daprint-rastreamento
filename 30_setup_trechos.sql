-- 30_setup_trechos.sql  (idempotente / reaplicavel)
-- SETUP com lancamentos por trecho + paradas (igual a producao). ADITIVO e
-- RETROCOMPATIVEL: a producao se comporta exatamente como hoje; OS antigas idem.
--
-- 1) Novo evento 'setup_lancamento' (trecho de setup). Nao muda status (cai no else
--    do trigger, mantendo 'em_setup'). O desperdicio de setup continua sendo lido do
--    'setup_fim' (o app grava nele o TOTAL = trechos + final), entao a view NAO muda.
-- 2) 'parada_fim' passa a ser CIENTE DA FASE: se ainda nao houve prod_inicio, volta
--    para 'em_setup'; se ja houve, volta para 'em_producao' (como hoje). Produção
--    inalterada (sempre teve prod_inicio antes das paradas dela).
-- 3) status_operacao_log ignora 'setup_lancamento' (e 'observacao') ao deduzir o
--    estado, e aplica a mesma regra de fase no parada_fim.
--
-- Depende de: 13_producao_apontamentos.sql.

-- =====================================================================
-- 1) Novo valor do enum (idempotente). Nao e usado como literal nas funcoes
--    abaixo (comparacoes por ::text), para poder rodar no mesmo script.
-- =====================================================================
alter type public.tipo_apontamento add value if not exists 'setup_lancamento';

-- =====================================================================
-- 2) Trigger: parada_fim ciente da fase (setup x producao). Resto inalterado.
-- =====================================================================
create or replace function public.aplicar_apontamento()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_modo public.modo_maquina;
begin
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
    status = (case new.tipo::text
      when 'setup_inicio'  then 'em_setup'
      when 'setup_fim'     then 'setup_ok'
      when 'prod_inicio'   then 'em_producao'
      when 'parada_inicio' then 'parado'
      when 'parada_fim'    then (case when exists (
                                  select 1 from public.apontamentos a
                                  where a.operacao_id = new.operacao_id
                                    and a.tipo = 'prod_inicio' and a.ts < new.ts)
                                then 'em_producao' else 'em_setup' end)
      when 'prod_fim'      then 'finalizada'
      when 'validada'      then 'finalizada'
      when 'reabertura'    then (case when v_modo = 'validacao' then 'aguardando' else 'setup_ok' end)
      else oo.status::text  -- 'lancamento' e 'setup_lancamento' e 'observacao' nao mudam status
    end)::public.status_operacao,
    atualizado_em = now()
  where oo.id = new.operacao_id;
  return new;
end $$;

-- =====================================================================
-- 3) status_operacao_log: ignora trechos/observacao; parada_fim ciente da fase.
-- =====================================================================
create or replace function public.status_operacao_log(p_op uuid)
returns public.status_operacao
language plpgsql stable security definer set search_path = public as $$
declare v_modo public.modo_maquina; v_tipo text; v_ts timestamptz;
begin
  select g.modo into v_modo
  from public.ordem_operacoes oo
  join public.maquinas_grupos g on g.nome = oo.grupo
  where oo.id = p_op;
  -- trechos (lancamento/setup_lancamento) e observacao nao mudam status: ignora.
  select tipo::text, ts into v_tipo, v_ts from public.apontamentos
   where operacao_id = p_op and tipo::text not in ('lancamento','setup_lancamento','observacao')
   order by ts desc, id desc limit 1;
  if v_tipo is null then return 'aguardando'; end if;
  return (case v_tipo
    when 'setup_inicio'  then 'em_setup'
    when 'setup_fim'     then 'setup_ok'
    when 'prod_inicio'   then 'em_producao'
    when 'parada_inicio' then 'parado'
    when 'parada_fim'    then (case when exists (
                                select 1 from public.apontamentos a
                                where a.operacao_id = p_op
                                  and a.tipo = 'prod_inicio' and a.ts < v_ts)
                              then 'em_producao' else 'em_setup' end)
    when 'prod_fim'      then 'finalizada'
    when 'validada'      then 'finalizada'
    when 'reabertura'    then (case when v_modo = 'validacao' then 'aguardando' else 'setup_ok' end)
    else 'aguardando'
  end)::public.status_operacao;
end $$;

grant execute on function public.status_operacao_log(uuid) to authenticated;

-- =====================================================================
-- FIM DO 30_setup_trechos.sql
-- =====================================================================
