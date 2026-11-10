-- =====================================================================
-- PCP | diagnostico_sync_ordens.sql
-- A mensagem "Esta OS ainda não existe na camada de apontamento" aparece
-- quando a tabela public.ordens nao tem a linha do pedido+item. Isso ocorre
-- se o sincronizar_ordens nao populou a ordens no upload (o app engolia esse
-- erro). Rode no SQL Editor do Supabase (roda como postgres, sem a trava de
-- gestor que a funcao tem).
-- =====================================================================

-- 1) DIAGNOSTICO: ha pedidos na foto mas nenhuma OS?
select
  (select count(*) from public.ordens)           as ordens,
  (select count(*) from public.pedidos_abertos)  as pedidos_abertos,
  (select count(*) from public.ordem_operacoes)  as operacoes;
-- Se ordens = 0 e pedidos_abertos > 0  -> a sincronizacao nao rodou. Siga p/ (2).


-- 2) SINCRONIZACAO MANUAL (recria as OS a partir da foto atual).
--    NAO apaga nada: merge por (pedido,item). Mesma logica da funcao, porem
--    sem a trava de gestor (aqui voce e postgres). So os campos essenciais;
--    cliente_nome/cliente_codigo serao preenchidos no proximo upload normal
--    (depois do 13_ atualizado aplicado).
insert into public.ordens (pedido, item, produto_codigo, descricao_origem, qtd, um, entrega, pedido_cliente)
select distinct on (pa.pedido, pa.item)
       pa.pedido, pa.item,
       upper(substring(coalesce(pa.produto,'') from '[A-Za-z]{2}[0-9]{3,}')),
       pa.produto_desc, pa.saldo, pa.um, pa.entrega, pa.pedido_cliente
from public.pedidos_abertos pa
order by pa.pedido, pa.item
on conflict (pedido, item) do update set
  produto_codigo   = excluded.produto_codigo,
  descricao_origem = excluded.descricao_origem,
  qtd              = excluded.qtd,
  um               = excluded.um,
  entrega          = excluded.entrega,
  pedido_cliente   = excluded.pedido_cliente,
  atualizado_em    = now();

-- 3) CONFERE: agora deve haver OS.
select count(*) as ordens_depois from public.ordens;

-- Depois disto: no app, SALVE a ficha tecnica do produto que vai testar
-- (isso materializa as operacoes da OS) e o apontamento ja aparece.
-- =====================================================================
