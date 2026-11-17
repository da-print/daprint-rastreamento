-- 26_vorei_pagina.sql  (idempotente / reaplicavel)
-- VOREY calculada por PAGINA (como a batida), enquanto a BROTECH (mesmo grupo
-- CORTE BROTECH / VOREY) continua por METRO. O modo hoje e por GRUPO; aqui o
-- calculo por pagina e ativado POR SUB-MAQUINA (so a VOREY), sem tocar no grupo
-- nem na BROTECH nem em mais nada.
--
-- Regra (validada): pagina = carreiras x repeticoes; n de paginas = etiquetas /
-- (carreiras x repeticoes); tempo = n de paginas / velocidade (paginas/h).
-- As carreiras/repeticoes sao VARIAVEIS (montagem da pre-impressao) e vem do
-- OPERADOR ao iniciar o setup na VOREY (carreira pre-preenchida da ficha, editavel;
-- repeticao digitada pelo operador).
--
-- Depende de: 09_maquinas.sql (maquinas_sub), 13_ (ordem_operacoes, ordens, produtos,
--             grupo_na_minha_maquina/posso_editar, trigger aplicar_apontamento).

-- =====================================================================
-- A) Flags por SUB-MAQUINA
-- =====================================================================
alter table public.maquinas_sub
  add column if not exists por_pagina        boolean not null default false,
  add column if not exists velocidade_pagina numeric;  -- paginas/h (so p/ subs por_pagina)
comment on column public.maquinas_sub.por_pagina is 'Sub-maquina calcula por PAGINA (carreiras x repeticoes), nao por metro. Ex.: VOREY.';
comment on column public.maquinas_sub.velocidade_pagina is 'Velocidade em PAGINAS/h (usada quando por_pagina=true).';

-- =====================================================================
-- B) Repeticoes na operacao (operador informa na VOREY; default 1)
-- =====================================================================
alter table public.ordem_operacoes
  add column if not exists repeticoes integer not null default 1;

-- =====================================================================
-- C) RPC: inicia o setup numa sub por_pagina (VOREY), recalcula a etapa em
--    PAGINAS e insere o setup_inicio. SECURITY DEFINER porque o operador nao
--    faz UPDATE direto em ordem_operacoes (status e dirigido por trigger).
--    Converte metros->paginas reaproveitando a cascata ja gravada:
--      etiquetas = qtd_metros * carreiras_atual * 1000 / passo
--      paginas   = etiquetas / (carreiras_novas * repeticoes)
--      => fator  = carreiras_atual * 1000 / (passo * carreiras_novas * repeticoes)
-- =====================================================================
create or replace function public.iniciar_setup_pagina(
  p_operacao uuid, p_maquina text, p_carreiras integer, p_repeticoes integer
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_op     public.ordem_operacoes%rowtype;
  v_sub    public.maquinas_sub%rowtype;
  v_qtd    numeric; v_um text; v_prod text; v_fc numeric; v_etiq numeric;
  v_img    numeric; v_vel numeric;
  v_pag_liq numeric; v_pag_rodar numeric;
  v_r_rodar numeric; v_r_dprod numeric; v_r_dsetup numeric;
begin
  -- BLOQUEIA a linha (evita corrida)
  select * into v_op from public.ordem_operacoes where id = p_operacao for update;
  if not found then raise exception 'Operacao nao encontrada'; end if;

  -- autorizacao: operador na maquina dele, ou gestor/editor
  if not (public.posso_editar() or public.grupo_na_minha_maquina(v_op.grupo)) then
    raise exception 'Sem permissao para esta operacao';
  end if;

  -- So ANTES de iniciar (status aguardando). PODE rodar de novo apos estorno (o
  -- status volta a aguardando): o calculo parte das ETIQUETAS da OS (invariante) e
  -- das RAZOES da propria op (cascata e desperdicio/qtd, preservadas na conversao),
  -- NAO do valor atual convertido. Logo recalcular nao compoe nem corrompe, e trocar
  -- carreiras/repeticoes reflete proporcionalmente.
  if v_op.status <> 'aguardando' then
    raise exception 'A etapa precisa estar aguardando (status atual: %)', v_op.status;
  end if;

  -- a maquina precisa ser uma sub POR PAGINA do grupo da op
  select * into v_sub from public.maquinas_sub
   where grupo = v_op.grupo and nome = p_maquina and por_pagina = true;
  if not found then raise exception 'Maquina nao configurada como por pagina'; end if;

  if coalesce(p_carreiras,0) <= 0 or coalesce(p_repeticoes,0) <= 0
     or p_carreiras > 10000 or p_repeticoes > 10000 then
    raise exception 'Carreiras e repeticoes invalidos (1..10000)';
  end if;
  v_img := p_carreiras::numeric * p_repeticoes::numeric;
  v_vel := coalesce(v_sub.velocidade_pagina, 0);

  -- ETIQUETAS da OS (INVARIANTE): qtd da ordem x fator de conversao da unidade.
  select o.qtd, upper(coalesce(o.um,'')), o.produto_codigo
    into v_qtd, v_um, v_prod
    from public.ordens o where o.id = v_op.ordem_id;
  select c.fator into v_fc from public.produto_conversoes c
    where c.produto_codigo = v_prod and upper(c.um) = v_um limit 1;
  if v_fc is null then
    v_fc := case when v_um in ('MI','MILHEIRO','MIL') then 1000 else 1 end;
  end if;
  v_etiq := coalesce(v_qtd,0) * coalesce(v_fc,1);

  -- razoes INVARIANTES da op (iguais em metro ou pagina, pois a conversao multiplica
  -- tudo pelo mesmo fator): cascata (rodar/liq) e desperdicios por unidade de liq.
  v_r_rodar  := case when coalesce(v_op.qtd_est,0) > 0 then v_op.qtd_rodar_est  / v_op.qtd_est else 1 end;
  v_r_dprod  := case when coalesce(v_op.qtd_est,0) > 0 then v_op.desp_prod_est  / v_op.qtd_est else 0 end;
  v_r_dsetup := case when coalesce(v_op.qtd_est,0) > 0 then v_op.desp_setup_est / v_op.qtd_est else 0 end;

  v_pag_liq   := case when v_img > 0 then v_etiq / v_img else 0 end;  -- n de paginas (liquido)
  v_pag_rodar := v_pag_liq * v_r_rodar;

  -- 1) insere o setup_inicio (trigger poe status=em_setup e re-snapshota em metro) ...
  insert into public.apontamentos(operacao_id, tipo, maquina)
    values (p_operacao, 'setup_inicio', p_maquina);

  -- 2) ... e aqui grava a estimativa em PAGINA (ganha do trigger).
  update public.ordem_operacoes set
    maquina        = p_maquina,
    carreiras      = p_carreiras,
    repeticoes     = p_repeticoes,
    unidade_est    = 'un',
    qtd_est        = v_pag_liq,
    qtd_rodar_est  = v_pag_rodar,
    desp_prod_est  = v_pag_liq * v_r_dprod,
    desp_setup_est = v_pag_liq * v_r_dsetup,
    vel_est        = case when v_vel > 0 then v_vel else vel_est end,
    prod_est_min   = case when v_vel > 0 then v_pag_rodar / v_vel * 60 else prod_est_min end
  where id = p_operacao;
end $$;

grant execute on function public.iniciar_setup_pagina(uuid,text,integer,integer) to authenticated;

-- =====================================================================
-- FIM DO 26_vorei_pagina.sql
-- =====================================================================
