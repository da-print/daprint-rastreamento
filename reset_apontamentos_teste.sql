-- =====================================================================
-- PCP | reset_apontamentos_teste.sql
-- Zera a CAMADA DE APONTAMENTO (OS persistente + operacoes + log de
-- apontamentos) para testar com poucos pedidos.
--
-- MANTEM:
--   - fichas tecnicas (produtos / produto_etapas / produto_conversoes)
--   - configuracao de maquinas (maquinas_grupos / maquinas_sub)
--   - motivos de parada
--   - camada-foto (pedidos_abertos / pcp / faturamento / overrides)
--
-- ATENCAO: destrutivo e IRREVERSIVEL. Rode no SQL Editor do Supabase.
-- As FKs tem ON DELETE CASCADE (apagar `ordens` ja removeria
-- ordem_operacoes e apontamentos); aqui os deletes vao explicitos e
-- dentro de uma transacao, com conferencia de contagem no fim.
--
-- Depois do reset, para montar o cenario de teste:
--   1) suba uma planilha PEQUENA de pedidos em aberto (so os de teste);
--      o app chama sincronizar_ordens() e recria apenas essas OS;
--   2) cadastre/salve as fichas tecnicas desses produtos -> materializa
--      ordem_operacoes com o estimado (quanto rodar / velocidade);
--   3) faca os apontamentos e confira os resultados na aba KPIs.
-- =====================================================================
begin;

delete from public.apontamentos;      -- log append-only (eventos)
delete from public.ordem_operacoes;   -- operacoes por etapa (snapshot do estimado)
delete from public.ordens;            -- OS persistente

-- Conferencia: deve voltar 0, 0, 0
select
  (select count(*) from public.apontamentos)    as apontamentos,
  (select count(*) from public.ordem_operacoes) as ordem_operacoes,
  (select count(*) from public.ordens)          as ordens;

commit;

-- =====================================================================
-- FIM. (Nao apaga fichas, maquinas nem a foto de pedidos.)
-- =====================================================================
