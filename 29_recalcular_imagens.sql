-- 29_recalcular_imagens.sql  (idempotente / reaplicavel)
-- Separa o RECALCULO (carreiras x repeticoes -> paginas/batidas) do inicio do setup,
-- para que o LANCAMENTO MANUAL (backfill) tambem recalcule a etapa, igual ao
-- "Iniciar setup". Parte das ETIQUETAS da OS (invariante) -> idempotente.
--
-- SEGURANCA (revisao): o recalculo cru fica numa funcao INTERNA (_recompute_imagens,
-- SEM grant a authenticated) e so e chamado pelas RPCs confiaveis, que validam
-- permissao + status='aguardando' ANTES de qualquer efeito. Assim nenhuma RPC
-- chamavel insere apontamento ou altera a op sem checar antes.
--
-- Depende de: 26_ (colunas por_pagina/velocidade_pagina, repeticoes), 13_/09_.

-- =====================================================================
-- INTERNA: so recalcula a estimativa (sem checar permissao/estado — quem chama ja
-- validou). NAO recebe grant a authenticated. Idempotente (parte das etiquetas).
-- =====================================================================
create or replace function public._recompute_imagens(
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
  select * into v_op from public.ordem_operacoes where id = p_operacao;
  if not found then raise exception 'Operacao nao encontrada'; end if;

  -- DEFESA EM PROFUNDIDADE: mesmo sendo interna (sem grant), revalida a permissao,
  -- para nunca alterar uma op de quem nao pode, caso fique exposta por engano.
  if not (public.posso_editar() or public.grupo_na_minha_maquina(v_op.grupo)) then
    raise exception 'Sem permissao para esta operacao';
  end if;

  select * into v_sub from public.maquinas_sub where grupo = v_op.grupo and nome = p_maquina;
  if not found then raise exception 'Maquina nao encontrada no grupo'; end if;
  select modo::text into v_modo from public.maquinas_grupos where nome = v_op.grupo;
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

  select o.qtd, upper(coalesce(o.um,'')), o.produto_codigo into v_qtd, v_um, v_prod
    from public.ordens o where o.id = v_op.ordem_id;
  select c.fator into v_fc from public.produto_conversoes c
    where c.produto_codigo = v_prod and upper(c.um) = v_um limit 1;
  if v_fc is null then v_fc := case when v_um in ('MI','MILHEIRO','MIL') then 1000 else 1 end; end if;
  v_etiq := coalesce(v_qtd,0) * coalesce(v_fc,1);

  v_r_rodar  := case when coalesce(v_op.qtd_est,0) > 0 then v_op.qtd_rodar_est  / v_op.qtd_est else 1 end;
  v_r_dprod  := case when coalesce(v_op.qtd_est,0) > 0 then v_op.desp_prod_est  / v_op.qtd_est else 0 end;
  v_r_dsetup := case when coalesce(v_op.qtd_est,0) > 0 then v_op.desp_setup_est / v_op.qtd_est else 0 end;

  v_liq   := case when v_img > 0 then v_etiq / v_img else 0 end;
  v_rodar := v_liq * v_r_rodar;

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
-- funcao interna: NAO pode ser chamada direto pelo cliente (revoga dos roles da API)
revoke all on function public._recompute_imagens(uuid,text,integer,integer) from public, anon, authenticated;

-- =====================================================================
-- CHAMAVEL: recalcula (lancamento manual). Valida permissao + aguardando ANTES.
-- =====================================================================
create or replace function public.recalcular_op_imagens(
  p_operacao uuid, p_maquina text, p_carreiras integer, p_repeticoes integer
) returns void
language plpgsql security definer set search_path = public
as $$
declare v_st text; v_grp text;
begin
  select status::text, grupo into v_st, v_grp from public.ordem_operacoes where id = p_operacao for update;
  if v_st is null then raise exception 'Operacao nao encontrada'; end if;
  if not (public.posso_editar() or public.grupo_na_minha_maquina(v_grp)) then
    raise exception 'Sem permissao para esta operacao';
  end if;
  if v_st <> 'aguardando' then
    raise exception 'So e possivel recalcular antes de iniciar (status atual: %)', v_st;
  end if;
  perform public._recompute_imagens(p_operacao, p_maquina, p_carreiras, p_repeticoes);
end $$;
grant execute on function public.recalcular_op_imagens(uuid,text,integer,integer) to authenticated;

-- =====================================================================
-- CHAMAVEL: inicia o setup por imagens. Valida permissao + aguardando ANTES de
-- inserir o setup_inicio; depois recalcula (o update vence o re-snapshot em metro
-- feito pelo trigger ao inserir).
-- =====================================================================
create or replace function public.iniciar_setup_pagina(
  p_operacao uuid, p_maquina text, p_carreiras integer, p_repeticoes integer
) returns void
language plpgsql security definer set search_path = public
as $$
declare v_st text; v_grp text;
begin
  select status::text, grupo into v_st, v_grp from public.ordem_operacoes where id = p_operacao for update;
  if v_st is null then raise exception 'Operacao nao encontrada'; end if;
  if not (public.posso_editar() or public.grupo_na_minha_maquina(v_grp)) then
    raise exception 'Sem permissao para esta operacao';
  end if;
  if v_st <> 'aguardando' then
    raise exception 'A etapa precisa estar aguardando (status atual: %)', v_st;
  end if;
  insert into public.apontamentos(operacao_id, tipo, maquina)
    values (p_operacao, 'setup_inicio', p_maquina);
  perform public._recompute_imagens(p_operacao, p_maquina, p_carreiras, p_repeticoes);
end $$;
grant execute on function public.iniciar_setup_pagina(uuid,text,integer,integer) to authenticated;

-- =====================================================================
-- FIM DO 29_recalcular_imagens.sql
-- =====================================================================
