-- 28_batida_setup.sql  (idempotente / reaplicavel)
-- GENERALIZA a RPC iniciar_setup_pagina (criada no 26_ para a VOREY) para tambem
-- atender a BATIDA: ao iniciar o setup, o operador informa carreiras x repeticoes
-- (pre-preenchidas da ficha, editaveis) e a etapa e recalculada na hora.
--
-- Diferenca VOREY x BATIDA:
--  * VOREY: sub-maquina com por_pagina=true; velocidade em velocidade_pagina.
--  * BATIDA: grupo em modo 'unidade'; velocidade = da sub-maquina (batidas/h),
--    com fallback na velocidade do grupo.
-- A matematica e a mesma: n de paginas/batidas = etiquetas / (carreiras x repeticoes),
-- partindo das ETIQUETAS da OS (invariante) e das razoes da op (idempotente: reabrir
-- e trocar os valores recalcula proporcional, nao compoe).
--
-- Depende de: 26_vorei_pagina.sql (colunas/por_pagina), 13_, 09_.

create or replace function public.iniciar_setup_pagina(
  p_operacao uuid, p_maquina text, p_carreiras integer, p_repeticoes integer
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_op     public.ordem_operacoes%rowtype;
  v_sub    public.maquinas_sub%rowtype;
  v_modo   text;
  v_qtd    numeric; v_um text; v_prod text; v_fc numeric; v_etiq numeric;
  v_img    numeric; v_vel numeric;
  v_liq numeric; v_rodar numeric;
  v_r_rodar numeric; v_r_dprod numeric; v_r_dsetup numeric;
begin
  select * into v_op from public.ordem_operacoes where id = p_operacao for update;
  if not found then raise exception 'Operacao nao encontrada'; end if;

  if not (public.posso_editar() or public.grupo_na_minha_maquina(v_op.grupo)) then
    raise exception 'Sem permissao para esta operacao';
  end if;
  if v_op.status <> 'aguardando' then
    raise exception 'A etapa precisa estar aguardando (status atual: %)', v_op.status;
  end if;

  select * into v_sub from public.maquinas_sub where grupo = v_op.grupo and nome = p_maquina;
  if not found then raise exception 'Maquina nao encontrada no grupo'; end if;
  select modo::text into v_modo from public.maquinas_grupos where nome = v_op.grupo;
  -- aceita: sub por pagina (VOREY) OU grupo em modo unidade (batida)
  if not (coalesce(v_sub.por_pagina,false) or v_modo = 'unidade') then
    raise exception 'Etapa nao calcula por carreiras x repeticoes';
  end if;

  if coalesce(p_carreiras,0) <= 0 or coalesce(p_repeticoes,0) <= 0
     or p_carreiras > 10000 or p_repeticoes > 10000 then
    raise exception 'Carreiras e repeticoes invalidos (1..10000)';
  end if;
  v_img := p_carreiras::numeric * p_repeticoes::numeric;
  v_vel := case when coalesce(v_sub.por_pagina,false)
             then coalesce(v_sub.velocidade_pagina,0)
             else coalesce(v_sub.velocidade,
                           (select velocidade from public.maquinas_grupos where nome = v_op.grupo), 0) end;

  -- ETIQUETAS da OS (invariante)
  select o.qtd, upper(coalesce(o.um,'')), o.produto_codigo into v_qtd, v_um, v_prod
    from public.ordens o where o.id = v_op.ordem_id;
  select c.fator into v_fc from public.produto_conversoes c
    where c.produto_codigo = v_prod and upper(c.um) = v_um limit 1;
  if v_fc is null then v_fc := case when v_um in ('MI','MILHEIRO','MIL') then 1000 else 1 end; end if;
  v_etiq := coalesce(v_qtd,0) * coalesce(v_fc,1);

  -- razoes invariantes da op (cascata e desperdicio por unidade de liquido)
  v_r_rodar  := case when coalesce(v_op.qtd_est,0) > 0 then v_op.qtd_rodar_est  / v_op.qtd_est else 1 end;
  v_r_dprod  := case when coalesce(v_op.qtd_est,0) > 0 then v_op.desp_prod_est  / v_op.qtd_est else 0 end;
  v_r_dsetup := case when coalesce(v_op.qtd_est,0) > 0 then v_op.desp_setup_est / v_op.qtd_est else 0 end;

  v_liq   := case when v_img > 0 then v_etiq / v_img else 0 end;  -- n de paginas/batidas (liquido)
  v_rodar := v_liq * v_r_rodar;

  insert into public.apontamentos(operacao_id, tipo, maquina)
    values (p_operacao, 'setup_inicio', p_maquina);

  update public.ordem_operacoes set
    maquina        = p_maquina,
    carreiras      = p_carreiras,
    repeticoes     = p_repeticoes,
    unidade_est    = 'un',
    qtd_est        = v_liq,
    qtd_rodar_est  = v_rodar,
    desp_prod_est  = v_liq * v_r_dprod,
    desp_setup_est = v_liq * v_r_dsetup,
    vel_est        = case when v_vel > 0 then v_vel else vel_est end,
    prod_est_min   = case when v_vel > 0 then v_rodar / v_vel * 60 else prod_est_min end
  where id = p_operacao;
end $$;

grant execute on function public.iniciar_setup_pagina(uuid,text,integer,integer) to authenticated;

-- =====================================================================
-- FIM DO 28_batida_setup.sql
-- =====================================================================
