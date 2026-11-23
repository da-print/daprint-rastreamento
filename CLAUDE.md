# PCP — Monitoramento de Produção (estado atual)

Documento técnico/handoff do projeto PCP. Leia antes de continuar o trabalho.
Última atualização: 2026-11-22.

## 1. Visão geral

O PCP começou como um **rastreador de pedidos** ("foto do dia": `app.html` + Supabase,
tabelas substituídas a cada upload) e está evoluindo para **monitoramento de produção
com apontamentos e KPIs** (tempo real vs estimado, desperdício, disponibilidade, OEE).

**Decisões base:**
- Apontamento **por operação/máquina** (não por OS inteira).
- Ficha técnica de produtos em **cadastro manual** (ou import Excel).
- **Estender o projeto atual** (mesmo Supabase + mesmo `app.html`), não criar sistema novo.
- Ordem de trabalho: **frontend primeiro, backend depois**.
- Protótipo de validação da UX: `producao.html` (localStorage, isolado). Já serviu seu
  propósito — a implementação real está no `app.html`.

Repositório/remoto: `github.com/da-print/daprint-rastreamento`. Deploy: Vercel.

## 2. Regras de trabalho (IMPORTANTE)

- **Deploy é 100% manual do usuário.** Nunca fazer `git push` nem acionar deploy.
  Entregar os arquivos; o usuário publica no GitHub/Vercel (publicar substitui a produção,
  então ele não publica em horário de trabalho).
- **Usuário costuma estar conectado remotamente** e sem acesso à pasta. Para entregar
  arquivos para teste/publicação, usar `SendUserFile` (manda o arquivo na conversa).
- Aplicar migrations/alterar RLS/funções no banco de produção exige **autorização explícita
  por ação**. O schema é entregue como arquivo `.sql` para o usuário aplicar.
- Segurança: escapar todo valor vindo do banco em HTML (`esc()`/`apEsc()`); nunca expor
  dados pessoais além do necessário.

## 3. Arquitetura — duas camadas convivendo

1. **Camada-foto (legada)**: `pedidos_abertos`, `pcp`, `faturamento`, `overrides`,
   substituídas a cada upload. Boa para "onde está agora" no fluxo antigo.
2. **Camada-apontamento (nova, permanente)**: `produtos` (ficha), `ordens` (OS persistente),
   `ordem_operacoes`, `apontamentos` (log append-only). **Nunca apagada por upload.**

**Chave de ligação:** `pedido+item`. A OS (`ordens`) é identificada por pedido+item; o
roteiro vem da ficha do produto; o status vem dos apontamentos.

**Mudança de upload (decidida):** o usuário sobe **só "pedidos em aberto"** (não sobe mais
o PCP). O upload chama `sincronizar_ordens()` que cria/atualiza `ordens` a partir de
`pedidos_abertos` (merge por pedido+item, nunca apaga).

## 4. Backend — `13_producao_apontamentos.sql` (idempotente)

Arquivo único, re-executável (drop-if-exists nas policies, `add column if not exists`,
enums em do-block). Cria/altera:

- **maquinas_grupos** (ALTER, sobre `09_maquinas.sql`): + `modo` (enum `modo_maquina`:
  por_cor | fixo | unidade | validacao), `velocidade` (nominal do grupo), `desp_prod_pct`,
  `setup_min_cor`, `desp_m_cor`, `desp_un`, `aplica_verniz`, `aplica_laminacao`,
  `acab_min`, `acab_desp`, **`apontamento_ativo`** (CHAVE do rollout híbrido, default false).
  Mantém `setup_min`/`desperdicio_m` (base do modo fixo).
  Seed de exemplo: FLEXO=por_cor (verniz+laminação), BATIDA=unidade, PRE-IMPRESSAO=validacao,
  CORTE BROTECH/VOREY=fixo+acabamento; demais fixo. **Ajustar números reais pela aba Máquinas.**
  `apontamento_ativo` é semeado true p/ PRE-IMPRESSAO, DIGITAL e CORTE BROTECH / VOREY **só na 1ª
  aplicação** (do-block guard: se nenhum grupo está ON ainda) — reaplicar não sobrescreve as chaves.
- **Realtime (parte G)**: publica `apontamentos` e `ordem_operacoes` na `supabase_realtime`
  (idempotente) p/ o painel do gestor acompanhar ao vivo.
- **maquinas_sub**: já tem `velocidade` por máquina física (do 09).
- **produtos** (ficha): codigo_pa (PK), descricao, substrato, larg_substrato, larg_etiqueta,
  alt_etiqueta, **gap_etiqueta** (passo = alt+gap), cores.
- **produto_conversoes**: (produto_codigo, um, fator) — unidade da base → etiquetas (ex. MI=1000).
- **produto_etapas**: roteiro (produto_codigo, ordem, grupo, carreiras, acab_verniz, acab_laminacao).
- **ordens**: OS persistente (pedido, item, produto_codigo SOFT ref — SEM FK, pode não ter
  ficha), descricao_origem, qtd, um, entrega, pedido_cliente, **cliente_codigo, cliente_nome**
  (preenchidos pelo `sincronizar_ordens` a partir de pedidos_abertos+clientes; p/ KPIs). unique(pedido,item).
- **ordem_operacoes**: uma por etapa materializada (grupo, carreiras, acab, maquina, status
  enum `status_operacao`: aguardando|em_setup|setup_ok|em_producao|parado|finalizada) +
  **estimado em snapshot** (unidade_est, qtd_est, setup_est_min, prod_est_min, desp_setup_est,
  desp_prod_est, vel_est, **qtd_rodar_est** = quanto precisa RODAR com cascata). `prod_est_min`
  e baseado no `qtd_rodar_est` (tempo p/ rodar o necessario), nao no liquido.
- **apontamentos**: log append-only (operacao_id, tipo enum `tipo_apontamento`:
  setup_inicio/fim, prod_inicio/fim, parada_inicio/fim, lancamento, validada, reabertura;
  ts, operador_id default auth.uid(), maquina, motivo, qtd).
- **motivos_parada** (semeado).
- **Funções/triggers:**
  - `sincronizar_ordens()` (gestor): merge de `ordens` a partir de `pedidos_abertos`
    (`distinct on` pedido+item; left join `clientes` p/ cliente_codigo/cliente_nome).
    Só roda com gestor logado (NÃO pelo SQL Editor).
  - `aplicar_apontamento()` (AFTER INSERT em apontamentos): traduz o evento em status/maquina
    da operação. **O operador não faz UPDATE direto em ordem_operacoes** — o status é dirigido
    por este trigger (evita escalonamento de privilégio). No `setup_inicio` com máquina, faz o
    **re-snapshot da velocidade**: `vel_est` = velocidade da sub-máquina (maquinas_sub) e
    `prod_est_min` = qtd_rodar_est ÷ vel × 60 (ex.: VOREY 600 vs BROTECH 2000). Também no
    `apontamento_manual`. (Gestor atribuindo máquina na fila recalcula igual, no cliente.)
  - `apont_forca_valores()` (BEFORE INSERT): para não-gestor, força `ts=now()`,
    `operador_id=auth.uid()` e valida a `maquina` contra o grupo (integridade do log).
  - `apontamento_manual(operacao, bloco, ini, fim, metros, operador?, motivo?)` (SECURITY
    DEFINER): lançamento **retroativo**. Insere um bloco fechado (setup = inicio+fim; produção
    = prod_inicio+lancamento+prod_fim) com o `ts` informado. Faz a própria autorização (RLS
    bypassada): operador só na sua máquina e em seu nome; gestor/editor pode indicar o operador
    e usar qualquer data (limite 365d gestor / 30d operador). Usa a GUC transacional
    `app.apont_manual='1'` para que os dois triggers acima **preservem** o ts/operador e não
    mexam no status evento-a-evento; o status é recalculado por `status_operacao_log()`.
  - `status_operacao_log(operacao)`: deduz o status pelo **último evento por ts** (não pela
    ordem de inserção) — usado após o lançamento manual para não regredir o estado atual.
  - `excluir_ultimo_apontamento(operacao)` e `excluir_observacao(id)` (SECURITY DEFINER, só gestor):
    correção de erro de lançamento. O primeiro apaga o evento **operacional** mais recente (LIFO,
    ignora observações) e **recalcula o status** por `status_operacao_log`; chamar várias vezes p/
    desfazer vários (do último ao primeiro). O segundo remove uma observação avulsa (não mexe no status).
  - Enum `tipo_apontamento` ganhou **`observacao`** (nota livre do operador por etapa; texto em `motivo`;
    não afeta status — cai no `else` dos triggers). `apont_forca_valores` força ts/operador p/ não-gestor.
- **RLS**: reaproveita `meu_papel()`, `sou_gestor()`, `posso_editar()`, `ve_tudo()`,
  `minhas_maquinas()`; helper `grupo_na_minha_maquina()`. Operador vê/aponta só a máquina dele.
- **Views KPI** (com `security_invoker=true`): `v_operacao_kpi` (estimado × real por operação,
  com datas `inicio_prod`/`fim_prod`/`ultimo_evento`/`data_ref` p/ filtro de período, e ainda
  `vel_est`, `qtd_rodar_est`, `cliente_codigo`, `cliente_nome`, `descricao` [produto|origem]),
  `v_kpi_maquina`, `v_kpi_operador`, `v_parada_detalhe` (cada parada pareada: motivo, máquina,
  operador, minutos — base do KPI "paradas por motivo"). OEE/Disponibilidade completos faltam
  (precisam de turnos). Grants de `select` às views para `authenticated`.

## 5. Frontend — `app.html` (produção)

SPA de abas, vanilla JS + Supabase (`config.js`) + XLSX (CDN). Login em `index.html`
(email/senha; redireciona para `app.html` relativo). Papéis: gestor, editor,
visualizador, visualizador_maquina (operador), representante.

### Abas
- **Painel de produção**: fila por máquina (agrupado por `r.grupo`). Dirigido pelo apontamento.
  **Rollout híbrido (`grupoApontamentoOn`)**: a etapa atual de uma OS só é dirigida por apontamento se o
  grupo dela tiver `apontamento_ativo=true`; grupo OFF → **programação manual** (`apManual`): item em
  produção no grupo (override do gestor ou grupo da etapa atual), **sem botão Apontamento**, gestor
  move a máquina e usa **Finalizar manual** p/ mandar a faturamento. A cadeia de apontamento para na 1ª
  etapa OFF; quando as etapas ON acabam e a atual cai num grupo OFF, o item vira manual. No modal, etapa
  de grupo OFF aparece como "Programação manual" (sem ações). **Chave** fica na aba Máquinas (liga/desliga
  por grupo) → `toggleApontamentoGrupo` salva e reprocessa o painel na hora.
  **Painel ao vivo**: gestor/editor/visualizador assinam Supabase Realtime (`iniciarRealtime`) em
  `apontamentos`+`ordem_operacoes`; qualquer mudança recarrega o painel com debounce (1,5s; adia se um
  modal está aberto). Operador fica de fora (recarrega sozinho ao apontar). Requer a parte G do `13_`.
  **Visão pessoal do operador** (`renderKpiOperador`): a aba KPIs já é visível ao operador; quando
  `_ehOperador`, mostra só o PRÓPRIO desempenho (filtra `operador_id = seu uid`, via `auth.getUser()`
  → `window._meuUid`): cards (horas produtivas, setup, paradas, metros, nº OS) + tabela "Minhas ordens".
  Os filtros de gestor (grupo/máquina/operador/cliente/OS) ficam ocultos; período continua. Sem mudança
  no banco — o RLS já restringe o operador às máquinas dele (lê ordens/ordem_operacoes/apontamentos do grupo).
  **Ordenar a fila (2026-11-16, `#painel-ordenar`/`ordComparePainel`):** seletor na barra de filtros ordena os
  itens DENTRO de cada máquina/sub-máquina por Prioridade (arrastar, padrão = `ordCompare`), Data de entrega,
  **Matéria-prima** (mapa `MP_NOME_POR_PA` produto→MP carregado no `recarregarDoBanco`, degrada se o 20_ ausente),
  Cliente, Produto ou Saldo. O **arrastar continua sempre ativo**; ao soltar, grava a ordem (`ordCompare` →
  `ordens.ordem`) e volta o seletor p/ "Prioridade" (fixa a ordem manual). Só visual/por sessão; nada no banco
  além do drag.
- **Máquinas**: config completa editável (modo, velocidade, % desperdício, setup/desperdício
  por modo, acabamento verniz/laminação + custo, velocidade por sub-máquina). Grava direto.
- **Fichas técnicas**: lista de produtos com coluna **Matéria-prima** (busca filtra código/descrição/MP),
  ações **Editar** e **Espelhar** (duplica a ficha num cadastro novo), "Novo produto" (código editável),
  "Produtos em OS sem ficha" (ignora PR/SE), **import por Excel** (botão Modelo + Importar). A ficha
  seleciona a **matéria-prima** (cadastro próprio; sem mais substrato texto livre) — ver §12.
- **KPIs**: aba (`renderKPIs`/`renderKpiTabelas`). Lê `v_operacao_kpi` + `v_parada_detalhe` e
  **agrega no cliente** com filtros de **período** (hoje/7d/30d/tudo/custom) + grupo/máquina/
  operador + **cliente** + **OS** (texto ped-item). Cards com **comparativos em %** (tempo rodando;
  paradas e %; produzido × a rodar; **dois desperdícios** — ver abaixo; desvio produção; desp. setup
  real × est). **Duas visões de desperdício (decisão 2026-11-10)**: (1) **Desperdício real** =
  rodado × **líquido** — o desperdício físico de verdade; (2) **Desp. vs previsto** = rodado ×
  `qtd_rodar_est` (meta com cascata) — desempenho contra o padrão. O **líquido por etapa NÃO é o
  líquido final** da OS: para a 1ª etapa e intermediárias, base = `qtd_est` da etapa escalado por
  `(prox.qtd_rodar_est / prox.qtd_est)` — ou seja, o que a etapa precisa **entregar boa à seguinte**;
  só a **última etapa** usa o líquido final (`qtd_est`). Isso evita que a cascata das etapas de baixo
  "suje" o desperdício de uma etapa de cima (ela roda mais de propósito p/ alimentar as próximas). A
  soma dos desperdícios reais por etapa (quando na mesma unidade) telescopa p/ a OS. Helpers `kBasesLiquidas()`
  (mapa `operacao_id→base`, calculado sobre TODAS as ops da OS, independe de filtros) e `kBase(o)`;
  `KPI_BASE` global. Tabelas (colunas **agrupadas em Tempo | Metros** com separadores): **por máquina**
  (ops; Tempo: **setup em minutos** — não contagem — + produção real/est. + **desvio prod.** em min e %;
  Metros: produzido real/est., desp. real, desp. vs prev, desp. setup; **vel. média × prevista**), **por operador** (ops, **setup**, horas
  produtivas, paradas, metros — setup incluído p/ não parecer ocioso), **paradas por motivo**
  (ocorrências + tempo) e **estimado × real por OS** (nº OS, cliente, produto; Metros: produzido real/est.,
  desp. real, desp. vs prev; tempo prod real/est.; **clique na linha → popup** `kpiAbrirOS` com detalhe por
  etapa/máquina, agrupado Tempo/Metros, com desp. real + desp. vs prev por etapa e totais; popup
  **ampliado** (min(1150px,96vw)×92vh, header fixo + corpo rolável) e com **"Ocorrências por etapa"**:
  histórico de apontamentos por etapa (reusa `apHistorico`; `kpiHistHtml`/`kpiOcorrenciasHtml`, `kpiAbrirOS`
  virou async e busca `apontamentos` dos `operacao_id` da OS) — data/hora, operador, metragem lançada,
  motivo de parada e **velocidade por trecho** (metros ÷ duração do trecho) + vel. média do bloco de produção). Base
  "a rodar" = `qtd_rodar_est` com fallback p/ `qtd_est` (`kRodar`) em OS antigas.
  **Metros NÃO somam entre etapas** (decisão 2026-11-10): é o mesmo job em sequência e cada etapa roda
  em carreiras diferentes (metros nem são comparáveis). Logo, no **resumo da OS** (cards, lista de OS e
  **Total** do popup) a metragem/desperdício usa a **1ª etapa de produção que rodou** de cada OS
  (`kOsMetros`: menor `etapa_idx` com `qtd_real>0`; se nenhuma rodou, a 1ª com meta a rodar — assim
  pré-impressão/validação, sem metragem, não zeram o resumo com "Todas as máquinas"), nunca a soma.
  No resumo, a base "líquido" é o **`qtd_est` (líquido do produto)** da etapa de referência — NÃO o
  `kBase` (o que ela entrega à seguinte). **Desperdício real = só OPERACIONAL** (decisão 2026-11-10): o
  é o **refugo de PRODUÇÃO** (operacional) — o setup fica **só** no card/coluna "Desp. setup", nunca
  descontado aqui. **É SOMA por etapa** sobre a seleção = `Σ (rodado − base)`, onde **base** (`kBase`/
  `kBasesLiquidas`) = o que a etapa entrega à seguinte = `qtd_rodar_est da próxima + desp_setup_est da
  próxima` (escalado por `qtd_est` p/ as carreiras); a **última etapa** = `qtd_est` (líquido do produto).
  Ou seja: refugo da etapa = rodado − (produção da próxima + acerto da próxima); a base **já embute o
  acerto da próxima**, por isso o setup próprio NÃO entra (senão duplicaria). Assim filtrar 1 máquina
  mostra só o refugo dela (ex. Digital `610−535,94=74,06`), e a soma da OS = `74,06+57,33+45,86=177,25`;
  a Revisão (última) não desconta setup. "Desp. vs previsto" = `Σ(rodado − qtd_rodar_est)`. % via
  `kPctD` ou % do rodado. "Produzido/líquido" (1ª etapa) e tempo seguem suas regras.
  Já **tempo** (setup/produção/paradas) e **desp. setup** continuam
  **somando** (aditivos). O detalhe por etapa (cada uma no seu metro) fica no popup. "Metragem líquida"
  de uma etapa = `(etiquetas ÷ carreiras da etapa) × passo ÷ 1000` = metros com ZERO desperdício p/
  entregar a qtd pedida; varia por etapa por causa das carreiras. OEE/Disponibilidade ficam p/ fase 2
  (exigem turnos). Degrada com aviso se o `13_` atualizado não estiver aplicado.
- Categorias, Vendedores, Usuários, Histórico (legadas).

### Apontamento (modal, botão por item EM_PRODUCAO)
Conversa com ordens/ordem_operacoes/apontamentos. Estados e ações: Iniciar setup
(escolhe máquina) → Finalizar setup (metros de setup) → Iniciar produção → Lançar trecho
(metragem) / Parada (com motivo) / Retomar → Finalizar. Validação (pré-impressão): só
"Validar e finalizar". Reabrir em etapas finalizadas (soma apontamentos). Mostra
total produzido, desperdício de setup e **cronômetro ao vivo** (ancorado no relógio do cliente).
A linha de **estimado** inclui (2026-11-16) o **setup em metros** (`desp_setup_est`), além de setup/produção
em min, rodar (cheio/líquido) e velocidade.
**Máquina no modal (2026-11-16):** escolher a sub-máquina no select da etapa `aguardando`
(`apAtribuirMaquina` → `atribuirMaquina`) já **move o item p/ a fila daquela máquina** no painel e re-snapshota
velocidade/tempo — igual ao painel; só gestor/editor (operador define ao iniciar o setup, por RLS). Antes o
select só era lido ao iniciar o setup.
**Trava de metragem zerada (2026-11-16, `apFinalizarProducao`/`apFinalizarSetup`):** Finalizar produção/setup
**aproveita a metragem ainda digitada no campo** (sem precisar clicar Lançar) e, se o total ficar **zerado**,
pede **confirmação** antes de gravar (caso legítimo: produção atendida a partir de estoque). Lançar e Parada já
consumiam/validavam o campo.

**Histórico de apontamentos** (por etapa, `apHistorico`/`apHistoricoHtml`; e no popup de KPI `kpiHistHtml`):
**hierárquico** (2026-11-16) — **Setup**, depois **Produção** (bloco com o **total** dos lançamentos + nº de
trechos) e **cada Lançamento aninhado** (indentado) como subgrupo da produção; Parada / Validação / Reabertura /
**Observação** como blocos próprios, em ordem cronológica (`dd/mm hh:mm → hh:mm` + duração + metros/motivo). O
bloco de produção é criado no `prod_inicio` (posição cronológica certa) e os lançamentos entram em `prod.lancs`
— antes eram linhas soltas ordenadas por horário e o 1º trecho empatava com o início da produção, caindo perto
do setup. Traz o **nome do operador** (de `profiles.nome` via `AP_OPERADORES`; degrada p/ "—" se a RLS não
liberar); no popup de KPI cada lançamento mostra a **velocidade por trecho**. Em `<details>` recolhível.

**Observação por etapa** (`apObservar` → apontamento `tipo='observacao'`, texto em `motivo`): campo de
texto em cada etapa p/ o impressor relatar ocorrência (ex.: "máquina patinando"). Aparece no histórico
e nas "Ocorrências por etapa" do popup de KPI. Gestor exclui uma observação avulsa (✕ no histórico →
`excluir_observacao`).

**Excluir apontamento** (`apExcluirUltimo` → RPC `excluir_ultimo_apontamento`): botão **só do gestor**,
remove o **último** evento operacional (LIFO) e recalcula o status; clicar de novo desfaz o anterior.
Para corrigir erro de lançamento. Destrutivo.

**Reabrir OS finalizada por apontamento** (`reabrirApontamento`): item que fecha todas as etapas vai p/
aguardando faturamento; o botão **Reabrir** no painel (gestor/editor; `r.apFinalizado` = APONT_ESTADO
todasFinalizadas) insere `reabertura` na **última etapa** (volta p/ produção). Dali o gestor corrige ou
**estorna** via "Excluir último apontamento". Separado do `reabrirItem` (que é p/ finalizado manual).

**Lançamento manual** (`apManualFormHtml`/`apManualRegistrar` → RPC `apontamento_manual`): botão
nas etapas acionáveis (e nas finalizadas, só gestor; escondido em validação). Form: bloco
(Produção/Setup), data, hora início, hora fim, metros; **gestor** ainda escolhe o **operador**
(`AP_USERS`). Converte para ISO e chama a RPC; se a função não existir no banco, avisa p/ aplicar
o `13_`. Para quem esqueceu de iniciar/finalizar; o status é recalculado cronologicamente.

### Regras-chave do painel/apontamento (já implementadas)
- **Fila dirigida pelo apontamento**: o item aparece na fila do grupo da **etapa atual**
  (1ª não-finalizada). Ao finalizar todas as etapas → sai de produção (aguardando faturamento).
- **Flag manual de máquina**: vira só-leitura para itens com apontamento; para itens
  **aguardando**, o gestor atribui a sub-máquina pela fila (sem iniciar setup) e ordena arrastando.
- **Produção parcial encadeada** (regra geral): assim que uma etapa **lança metragem**, a
  **próxima** fica disponível na fila dela com a tag "Parcial · etapa anterior em andamento";
  isso encadeia por todo o roteiro. Item aparece em várias filas ao mesmo tempo, cada uma com
  status/cronômetro/estimativa próprios. Modal libera as etapas da cadeia.
- **Status do apontamento na fila**: badge "Setup em processo / Setup concluído / Produção
  iniciada / Parado · <motivo>" + cronômetro, para todos os itens em produção.
- **Colunas do painel**: `M/L` (total estimado da etapa), `M/L rest.` (total − produzido),
  `Tempo rest.` (desconta setup feito + produção proporcional ao restante). Só leitura do
  apontamento; sem apontamento mostra "—"/cálculo antigo.
- **PR (revenda) e SE (serviço)** não são fichas de produto — ficam fora.
- Sub-máquina: operador escolhe no apontamento (não antes), porque cada trabalho vai para a
  máquina livre do grupo (ex. FLEXO 1/2/3, BROTECH/VOREY). Coluna mostra só a sub escolhida.

### Materialização
**No upload** (2026-11-12): após `sincronizar_ordens`, o fluxo chama `materializarPendentes()` —
materializa as OS cujo produto já tem ficha mas que ainda não têm `ordem_operacoes` (pedido novo
que chegou DEPOIS da ficha já existir). Sem isso o item ficava preso em "Em carteira" mesmo com
ficha (status EM_PRODUCAO só vem de ops materializadas — inclusive grupo OFF via `ae.manual`).
Usa `lerTabelaCompleta` (passa de 1000 linhas). Itens já presos destravam ao refazer um upload.

`materializarProduto(pa)` (ao salvar ficha / importar): para cada OS do produto sem operações
(ou com todas aguardando), cria `ordem_operacoes` com o **estimado calculado**. Base: etiquetas
= qtd × fatorConv(um); metros = (etiquetas÷carreiras)×passo÷1000 (passo = alt+gap); setup por cor
= min/cor × cores (+ acabamento). **Cascata (quanto rodar)**: `qtd_rodar_est` = produção líquida
÷ (1 − Σ desp% da etapa e das seguintes) + Σ acerto(setup) das etapas seguintes — assim a 1ª etapa
já roda o extra que as próximas vão desperdiçar (não falta material). `prod_est_min` = qtd_rodar_est
÷ velocidade × 60. Decisão do usuário (2026-11-10): desperdício em 2 momentos — (1) informativo
"quanto rodar" ao operador; (2) KPI = apontado × o que deveria rodar (= qtd_rodar_est). Velocidade
na ficha usa a nominal do grupo; o **re-snapshot pela sub-máquina** ocorre ao escolher a máquina no
apontamento (ver `aplicar_apontamento`).

## 6. Como testar localmente (sem publicar)

1. Baixar `index.html`, `app.html` e `config.js` na MESMA pasta.
2. Abrir `index.html`, fazer login (email/senha).
3. Cai no `app.html` local com dados do MESMO Supabase. Não toca no deploy de produção.
   Cuidado: escritas (apontar, salvar ficha, importar) vão para o banco real — mas quase tudo
   nas tabelas novas, que a produção antiga não usa. Evitar subir planilhas em horário de trabalho.

## 7. Pendências / próximos passos

- **KPIs/relatórios — v2 FEITO** (2026-11-10): filtros cliente/OS, tabelas por máquina/operador
  expandidas, popup de detalhe por OS, comparativos em %, **velocidade por sub-máquina** (re-snapshot
  no setup) e **desperdício em cascata** (`qtd_rodar_est`). **Fase 2 pendente: OEE/Disponibilidade**,
  que exigem **turnos/calendário por máquina** (tabela `maquina_turnos` ainda não modelada) para
  calcular tempo disponível. **Requer reaplicar o `13_`** (colunas novas + views).
- Remover de vez o **flag manual legado** quando tudo estiver no apontamento.
- Importar `qtd` e outros campos em consultas sempre que calcular produzido (bug já corrigido
  no painel; atenção ao replicar).

## 8. Arquivos SQL (ordem)
`01_schema.sql` → `02_ingestao_fix.sql` → `03_rls_papeis.sql` → ... → `09_maquinas.sql` →
`10..12` → **`13_producao_apontamentos.sql`** (monitoramento; idempotente, reaplicável) →
**`14_batida_repeticoes.sql`** (coluna `repeticoes` em `produto_etapas`, p/ batida; idempotente) →
**`15_ordem_pendencias.sql`** (tabela `ordem_pendencias`; idempotente) →
**`16_ordens_roteiro_custom.sql`** (coluna `ordens.roteiro_custom`; idempotente) →
**`17_pendencia_tipos.sql`** (tabela `pendencia_tipos` + policies de gestor em `motivos_parada`; idempotente) →
**`18_papel_permissoes.sql`** (tabela `papel_permissoes`; idempotente, SEM seed) →
**`19_pendencias_resp_obs.sql`** (coluna `ordem_pendencias.responsavel_id` + tabela `pendencia_observacoes`; idempotente) →
**`20_materias_primas.sql`** (tabela `materias_primas` + coluna `produtos.materia_prima_id` + view `v_ordem_materia`; idempotente) →
**`21_mp_fornecedor_snapshot.sql`** (coluna `fornecedor` em `materias_primas` + unicidade (nome,fornecedor); colunas de snapshot `mp_*` em `ordens`; `v_ordem_materia` lê snapshot c/ fallback; idempotente) →
**`22_custo_produto.sql`** (custo do produto vendido: `maquinas_sub.custo_hora`; colunas de custo em `produtos`; tabelas `acabamentos`, `produto_acabamentos`, `ribbons`, `custo_parametros`; idempotente — ver §13) →
**`23_operador_apontamento.sql`** (operador lê o roteiro inteiro das OS que tocam a máquina dele; idempotente — ver §14) →
**`24_operador_apontamento_perf.sql`** (RLS do operador por conjunto, evita timeout; idempotente — ver §14) →
**`25_operador_pedidos_apontamento.sql`** (`item_na_minha_maquina` passa a considerar a etapa atual do apontamento; idempotente — ver §14) →
**`26_vorei_pagina.sql`** (`maquinas_sub.por_pagina`/`velocidade_pagina`, `ordem_operacoes.repeticoes`, RPC `iniciar_setup_pagina`; idempotente — ver §15) →
**`27_prioridade.sql`** (coluna `overrides.prioridade`; idempotente — ver §15) →
**`28_batida_setup.sql`** (generaliza `iniciar_setup_pagina` p/ o grupo em `modo='unidade'`; idempotente — ver §15) →
**`29_recalcular_imagens.sql`** (`_recompute_imagens` interna + `recalcular_op_imagens` chamável; lançamento manual recalcula; idempotente — ver §15) →
**`30_setup_trechos.sql`** (evento `setup_lancamento` + `parada_fim`/`status_operacao_log` cientes da fase setup×produção; idempotente — ver §15) →
**`31_custo_mp.sql`** (CUSTO v2 — **substitui o `22_` órfão, NÃO aplicar o 22_**: `tipo`+campos de custo em `materias_primas`; colunas de custo em `produtos` incl. `impressao`/`carreiras`/`repeticoes`/`tinta_branca`; `produto_etapas.maquina_custo`; `produto_acabamentos`→materias_primas; `maquinas_sub_custo` [custo_hora + insumo_m2]; `custo_parametros`; dropa a FK antiga `produtos_ribbon_id_fkey` e reconcilia `produto_acabamentos`; idempotente — ver §17).

## 12. Matérias-primas + m² nos KPIs (2026-11-15)

**Status: TUDO EM PRODUÇÃO** — `20_` e `21_` aplicados no banco e `app.html` publicado (2026-11-16).
Usuário já cadastrou as matérias-primas e vinculou em todas as fichas.

Aba **Matérias-primas** (sidebar, só gestor/editor; cadastro em `PERM_GESTOR_TABS`/`PERM_ABAS` como
`ver_materias`). Migration `20_`: tabela `materias_primas` (nome único, `largura_mm` [largura PADRÃO],
`valor_m2` [BRUTO], `icms_pct`, `ipi_pct`, ativo) + coluna soft `produtos.materia_prima_id`
(FK `on delete set null`) + view `v_ordem_materia` (security_invoker; por pedido+item: produto,
`largura_mm` efetiva = `coalesce(larg_substrato, mp.largura_mm)`, mp_nome/valor/icms/ipi). RLS:
select p/ authenticated, escrita `posso_editar()`.

- **Cadastro** (`renderMaterias`/`mpNovo`/`mpEditar`/`mpSalvar`/`mpToggle`/`mpRemover`): lista + form
  (nome, largura, valor/m², ICMS%, IPI%). `MATERIAS_PRIMAS` global carregado no `recarregarDoBanco`
  (degrada se `20_` ausente); **`window._mpReady`** = tabela existe (⇒ coluna também) — gate p/ não
  quebrar `salvarFicha` antes do `20_` (só envia `materia_prima_id` com `_mpReady`).
- **Ficha**: select `f-mp` (`fichaMPOptions`/`fichaMPChange`) — ao escolher, puxa a largura padrão p/
  `larg_substrato` (**editável**, largura efetiva fica no PRODUTO). O campo de substrato texto livre foi
  REMOVIDO (ver §12.2); `substrato` (coluna do banco) agora deriva do nome da MP no save. Excel
  import/export NÃO mexe na MP (vínculo é só na UI).
- **Conversão** linear→m²: `m² = metros_lineares × (largura_mm ÷ 1000)`.
- **KPI "Por matéria-prima"** (`renderKpiTabelas`; `KPI_MAT` de `v_ordem_materia`; `kBRL`): por MP,
  **m² estimado** (`kRodar(ref)`), **m² rodado** (`qtd_real(ref)`), **m² a produzir** (est−real),
  **custo bruto** = m²_real × valor/m², **ICMS** = custo × icms%, **IPI** = custo × ipi% (impostos
  "por fora" sobre o bruto). Usa a 1ª etapa que rodou (`kOsMetros`), só quando `unidade_est='m'`
  (batida/validação em 'un' não convertem) e largura>0. **Independe** de máquina/operador/grupo
  (substrato consumido 1×/OS); respeita período + cliente + OS. Degrada com aviso se `20_` ausente.
- **Painel — botão "Ver ficha"** (ícone de documento, `btn-carr`, nos itens **EM_PRODUCAO** com
  `r.produto`, **todos os papéis**): `verFichaItem(pa,pedido,item)` abre popup **só-leitura**
  (`modal-verficha`, classes `modal-overlay`/`modal-box`; `fecharVerFicha`/`vfEsc`) com produto,
  **matéria-prima** (nome; cai p/ `substrato` texto se sem vínculo), largura, dimensões (L×A, gap,
  passo, cores), roteiro e conversões. **Valor/m², ICMS e IPI só para `window._podeEditar`**. Botão
  "Editar ficha" (gestor/editor) chama `abrirFicha`. Sem ficha → oferece cadastrar. Não depende do
  `20_` (só o nome da MP no popup depende). O campo "Substrato (texto livre)" já foi removido da ficha (§12.2).

### 12.1 Fornecedor + ciclo fechado (snapshot de custo) — migration `21_` (2026-11-15)

- **Fornecedor** no cadastro de MP (`materias_primas.fornecedor`; unicidade passa a ser (nome,fornecedor)).
  Decisão: **uma linha por material+fornecedor** (cada um com seu valor/ICMS/IPI). Seletores (ficha, config
  da OS, popup Ver ficha) mostram **"Material · Fornecedor"** (`fichaMPOptions`, `mp-forn` no form, coluna na lista).
- **Ciclo fechado (snapshot na OS)**: `ordens` ganha `mp_id/mp_nome/mp_fornecedor/mp_valor_m2/mp_icms_pct/
  mp_ipi_pct/mp_largura_mm`. Decisão: **congela ao DEFINIR a MP** — editar o cadastro depois só vale p/ OS
  novas; **OS finalizada nunca muda** (nada re-copia). Captura: (1) `materializarProduto` grava o snapshot
  do valor ATUAL do cadastro quando `o.mp_id` está vazio (não sobrescreve); (2) `salvarConfigOS` grava o
  snapshot escolhido no popup. Ambos em try/catch (degrada se `21_` ausente). `window._mpReady` gate.
- **Config da OS** (`abrirConfigOS`/`renderConfigOS`/`salvarConfigOS`; estado `OSR.mpId`/`OSR.mpLarg`):
  bloco **"Matéria-prima desta OS"** = select de MP + **largura editável** (override por OS, ex.: item de 2
  carreiras rodado em 1 com bobina diferente) + **indicativo do fornecedor** da MP escolhida (`osrSetMP`/
  `osrSetLarg`). Grava snapshot só nessa OS; não toca na ficha nem em outras OS.
- **`v_ordem_materia`** passa a ler o snapshot da OS com **fallback** (`coalesce(o.mp_*, ...cadastro ao vivo)`)
  p/ OS antigas sem snapshot. **KPI "Por matéria-prima"** agrupa por **material·fornecedor** e soma
  **custo/ICMS/IPI por OS** (cada OS usa o SEU snapshot de preço — `KPI_MAT[...].forn/valor/icms/ipi`).
  Largura do m² = `mp_largura_mm` (snapshot) com fallback p/ `larg_substrato`. Degrada se `21_` ausente.

### 12.2 Fichas: substrato removido, coluna MP e espelho (2026-11-15; só frontend)

- **Campo "Substrato (texto livre)" REMOVIDO** da ficha (a MP virou a fonte única). `salvarFicha` agora
  grava `produtos.substrato` derivado do **nome da MP selecionada** (coluna mantida no banco p/ compat).
  `fichaMPChange` não mexe mais em substrato (só puxa a largura).
- **Lista de fichas** (`renderFichas`/`renderFichasLista`) ganhou coluna **Matéria-prima** (de
  `materia_prima_id` via `MATERIAS_PRIMAS`, cai p/ `substrato`; rótulo "nome · fornecedor"); busca também
  filtra por MP. Ações da linha: **Editar** + **Espelhar**.
- **Espelhar** (`espelharFicha(pa)`): abre uma NOVA ficha (código em branco/editável) pré-preenchida com
  dimensões, cores, MP, conversões e roteiro do item de origem — p/ cadastrar produto parecido e ajustar.
  Onclicks de Editar/Espelhar usam `jsAttr()`.

**Ajustes 2026-11-14:** (1) **Bug finalizar manual:** item com ficha em grupo manual continuava na fila com
"finalizado manual". Corrigido no cálculo de status — `if(ae&&ae.temOps && !(ov&&ov.finalizado_em))`: a
marcação manual VENCE a fila do apontamento → vai p/ aguardando faturamento. (2) **Pendências: responsável**
(`responsavel_id`, select de `profiles` no cadastro e editável na lista; `PEND_USERS`/`carregarPendUsers`/
`pendSetResp`). (3) **Observações = histórico** (tabela `pendencia_observacoes`, append-only c/ autor_id/criado_em):
botão "Obs" (`pendEditObs`) mostra todas + adiciona nova (`pendObsSalvar` insere, não sobrescreve); `obs` da
pendência vira "observação inicial". (4) **Hambúrguer mobile** = SVG inline de 3 traços (a fonte `ti ti-menu-2`
saía como barra branca — mesmo problema da engrenagem; usar SVG inline nesses botões).

**Aba Permissões** (sidebar, só gestor): matriz papéis (editor/visualizador/visualizador_maquina/representante;
gestor sempre full, fora da matriz) × flags — `ver_<aba>` (painel/entregas/pendencias/kpis/fichas/maquinas/
vendedores/usuarios/historico/listas) e ações (`acao_editar`→window._podeEditar, `acao_upload`→painel de upload,
`acao_apontar`→botão Apontamento). `perm(chave)` (gestor=true; senão `_PERMS[papel][chave]` ou `permDefault`),
`permDe`, `carregarPermissoes` (antes de `aplicarPermissoesUI`). SEM seed = ausência de linha usa o padrão atual
(nada muda até editar). `aplicarPermissoesUI` dirige upload/_podeEditar/sidebar por `perm()`. **Flags = só UI;
proteção real = RLS.** Ampliar gravação de um papel exige ajuste de RLS em .sql à parte.

**Aba Listas** (sidebar, só gestor; `renderListas`/`listaAdicionar`/`listaToggle`/`listaRemover`): edita
sem código os **Motivos de parada** (`motivos_parada`) e os **Tipos de pendência** (`pendencia_tipos`,
antes fixos em `PEND_TIPOS` — agora carregados do banco no `recarregarDoBanco`, com fallback). Categorias
de observação seguem na aba **Categorias** (`categorias_obs`). Operações por `nome` (add/ativar-inativar/excluir).

## 10. Carreiras por rodada + Pendências (2026-11-12)

**Ajuste de carreiras da rodada** (frontend, SEM schema): engrenagem (SVG inline, com texto
"Carreiras") à direita de cada item EM_PRODUCAO no painel, só gestor/editor (`window._podeEditar`),
só enquanto a etapa atual NÃO iniciou produção (status aguardando/em_setup/setup_ok). Popup
`abrirCarreiras(opId)` → `carrCalc`/`salvarCarreiras`: recalcula a estimativa SÓ daquela operação
(metros ∝ 1/carreiras; cascata reconstruída dos próprios valores gravados — pct=desp_prod_est/qtd_est,
setupNext=Σ desp_setup_est das próximas na mesma unidade) e dá UPDATE em `ordem_operacoes`
(carreiras, qtd_est, qtd_rodar_est, prod_est_min, desp_prod_est), igual ao padrão do `atribuirMaquina`.
NÃO altera a ficha nem outras OS. Registra observação no histórico da etapa. Exposto via `APONT_ESTADO[].opAtual`
e `r.opAtual` (ON e manual). Serve p/ batida também (imagens ∝ carreiras).

**Pendências / impedimentos** (tabela `15_`): `ordem_pendencias` (ordem_id, tipo, obs, status
aberta/resolvida, criado/resolvido_por/em). Tipos: Solicitar faca, Solicitar clichê, Aguardando
material, Outro. RLS: select p/ authenticated; insert/update p/ `posso_editar()`; delete p/ `sou_gestor()`.
Front: `PEND[pedido|item]` carregado no `recarregarDoBanco` (degrada se `15_` ausente). Botão "⚠ Pend."
nos itens EM_PRODUCAO/EM_CARTEIRA (gestor/editor) → `abrirPendencia` (popup abrir/resolver; com **Data de
solicitação** e **Previsão de chegada**). Badge âmbar no item. **Aba "Pendências" na sidebar** (não mais
quadro no topo — `pendPanelHtml` ficou sem uso): `renderPendencias` = tabela (Pedido-Item, PA, Descrição,
Cliente, Entrega, Pendência, Aberta em, Solicitação, Previsão) + filtros tipo/situação/busca + Resolver,
via embed `ordem_pendencias.select('*, ordens(...)')`. `15_` inclui as colunas `data_solicitacao`/
`previsao_chegada` (reaplicável). Roteamento automático à pré-impressão fica p/ iteração 2.

**Configurações desta OS** (engrenagem icon-only no painel, gestor/editor; tabela `16_`): abre
mini-ficha SÓ daquela OS (`abrirConfigOS`/`renderConfigOS`/`salvarConfigOS`, estado `OSR`). OS **não
iniciada** (todas ops `aguardando`) → edita o roteiro todo (trocar grupo/máquina — ex.: rodar fora da
ficha —, carreiras, repetições[batida], acabamento, add/remover/reordenar); salvar **reconstrói** o
`ordem_operacoes` só dessa OS (`osrComputarRows` = mesma lógica de `materializarProduto`: estimarEtapa +
cascata) e marca `ordens.roteiro_custom=true`. OS **já iniciada** → roteiro travado, só carreiras/
repetições das etapas `aguardando` (UPDATE das ops pendentes). **`materializarProduto` pula OS com
`roteiro_custom=true`** (não sobrescreve). Reaproveita `MAQUINAS_GRUPOS_DB`/`GRUPOS`/`estimarEtapa`.
Substituiu o popup antigo só-de-carreiras (funções `abrirCarreiras`/`carrCalc` ficaram, sem uso).
Aplicar `16_` antes de publicar. Limitação v1: repetições por OS não persistem na op (pré-preenche da
ficha ao reabrir).

## 9. Batida — imagens por repetição (2026-11-12)

`produto_etapas.repeticoes` (int, default 1; migration `14_`). **Só** afeta etapas de batida
(grupo em `modo='unidade'`). Regra: `imagens = carreiras × repeticoes`; `nº de batidas =
etiquetas ÷ imagens`; tempo = batidas ÷ velocidade (velocidade do grupo BATIDA já em **batidas/h**,
golpes/h). `estimarEtapa` (modo unidade): `qtd = tot/imagens`, `unit='un'` (= nº de batidas).
Demais grupos inalterados (carreiras seguem dividindo só a metragem nos modos em metro).
Ficha: etapa de batida mostra campo **Repetições** + linha "Imagens = carr × rep". Excel
(modelo/import/backup): roteiro da batida como `BATIDA:carreiras:repeticoes` (ex.: `BATIDA:2:2`);
o parse pega dígitos como repetições e letras (V/L) como acabamento. **Aplicar `14_` antes de
publicar o app.html** (os inserts de `produto_etapas` passam a enviar `repeticoes`).

Fichas técnicas também ganharam: contador de produtos cadastrados, **Backup (baixar)** = Excel
no formato do import (reimportável), e **overlay de progresso** no import (`mostrarProgresso`/
`fecharProgresso`).

## 11. UX / Layout / Pendências v2 / Performance (2026-11-14 a 15) — TUDO EM PRODUÇÃO

- **Ícones = SVG inline.** A fonte Tabler (`ti ti-*`) NÃO carrega no ambiente (saía como caixa/barra
  branca). Trocados por SVG inline: engrenagem do painel, hambúrguer mobile (`.tb-burger`), botão de
  recolher da sidebar (`.sb-burger`) e os **11 ícones da sidebar** (um por aba, `currentColor` → herdam
  cor e o vermelho do ativo). **Regra:** novos ícones nesses pontos = SVG inline, não a fonte.
- **Sidebar/menu:** hambúrguer do topo (mobile) é botão pequeno à direita; no desktop/iPad o botão no topo
  da sidebar recolhe/expande (`sb-collapsed`, estado em `localStorage`), alargando o conteúdo.
- **Painel enxuto:** removidas as imagens das máquinas (`imagemGrupoHtml` retorna ''); densidade reduzida
  via overrides em `#painel-view` (headers baixos, sem "caixa", linhas estreitas).
- **Telas em lista:** **Máquinas** redesenhada como lista (1 linha/máquina + expandir p/ o editor que já
  existia; `maq-row`/`toggleMaqGrupo`/`_maqAberto`). **Vendedores e Usuários** ganharam largura cheia
  (`.cat-box` full-width à esquerda) mas AINDA no layout antigo por dentro — PENDENTE pô-los em lista
  como as Máquinas.
- **Entregas por data = tabela ÚNICA** (estilo ERP): cabeçalho fixo no topo, cada data é uma **faixa
  full-width azul forte** dentro da tabela (`ent-band`), itens em **1 linha** (produto+desc inline,
  ellipsis+title), **zebra azul suave** reiniciando por data. Sem subtotal. Coluna **Observações reflete a
  pendência** (tipo da pendência aberta, ex. "Solicitar faca", ou "sem observação").
- **Categorias → aba Listas** (3º card `categorias_obs`, `temAtivo:false`); a aba Categorias saiu da sidebar.
  "Produtos em OS sem ficha" virou card **recolhível** (`toggleSemFicha`).
- **Pendências v2 (migration `19_`):** **responsável** (`ordem_pendencias.responsavel_id`, select de
  `profiles`, editável na lista; `PEND_USERS`/`carregarPendUsers`/`pendSetResp`); **histórico de
  observações** com autor (`pendencia_observacoes` append-only; `pendEditObs` lista+adiciona, não
  sobrescreve; RLS insert exige `autor_id = auth.uid()`). No **painel**, a pendência saiu do Status e a
  coluna **Observações** virou fixa = pendência/"sem observação". Aba Pendências: **filtro por responsável**,
  **badge vermelho** com contador na sidebar (`atualizarBadgePendencias`, pendências abertas do usuário) e
  **toast** de aviso ao entrar (`notificarPendencias`, 1×/sessão). `window._meuUid` setado cedo.
- **Finalizar manual (bug):** `if(ae&&ae.temOps && !(ov&&ov.finalizado_em))` — marcação manual vence a fila.
- **Performance — recarga LEVE:** `recarregarDoBanco(silencioso, light)`. Com `light=true` (todas as ações
  do dia a dia + realtime, via `recarregarDoBanco(true,true)`) PULA as 4 tabelas GRANDES
  (clientes/pedidos_abertos/pcp/faturamento — só mudam no upload) e relê só o resto (overrides/categorias/
  vendedores/máquinas) + camada de apontamento. Upload e botão "Recarregar do banco" seguem completos.
  Próximo passo de escala (quando a base crescer): consultas por período + índices + retenção/arquivamento
  dos `apontamentos`.

**PENDENTE:** Vendedores e Usuários em lista (padrão das Máquinas); fase de escala (índices/retenção).

## 13. Custo do produto vendido (2026-11-16) — ⚠️ SUPERADO pela §17

**NÃO use esta seção nem o `22_custo_produto.sql`.** A arquitetura de custo foi **refeita** (unificada
nas matérias-primas por tipo, ficha única, motor detalhado) — ver **§17**. O `22_` ficou **órfão** (não
aplicar) e o `31_` o substitui. O texto abaixo é histórico (fórmulas de clichê/tinta/ribbon seguem válidas,
só mudou ONDE os dados são cadastrados e lidos).

**Status: desenvolvido LOCAL, NÃO publicado.** Migration `22_custo_produto.sql` ainda **não aplicada**
no banco e `app.html` **não publicado** (aguarda teste do usuário). Tudo aditivo e com gate
`window._custoReady` (tabela `acabamentos` existe) — o app degrada com aviso sem o `22_`. **Não altera
o cálculo de produção/apontamento existente.**

**Ingredientes (decisões validadas):** custos **variáveis** (escalam com a qtd): substrato (já existia),
hora-máquina, tinta, acabamentos (laminação/verniz/stamping), ribbon. Custos **fixos** (1× por pedido):
clichê, faca, zinco (ferramental do hot stamping). Apresentação: **fixo à parte + variável por unidade**
(cards: fixos, variáveis, totais/unitário c/ fixo diluído).

**Banco (`22_`, idempotente):**
- `maquinas_sub_custo` (R$/h **por submáquina**, tabela **separada e restrita** — leitura só gestor/editor, pois `maquinas_sub` é lida por todos; `CUSTO_HORA_SUB` no app).
- `produtos`: `espaco_carreiras`, `esqueleto_lateral` (mm, clichê), `chapado` (bool, sem clichê de cor),
  `custo_faca` (R$ fixo), `ocupacao_tinta` (% média), `ribbon_id` (soft FK), `carreiras_ribbon`.
- `acabamentos` (cadastro de tipos): `tipo_calculo` ∈ {filme, verniz, stamping}; `valor_m2` (filme/fita),
  `gramatura`+`preco_kg` (verniz), `setup_m` (metros de acerto que soma ao setup), `gera_cliche`
  (verniz localizado/cold → +1 clichê), `gera_zinco` (hot → zinco).
- `produto_acabamentos` (quais a ficha usa + params por produto: `ocupacao`, `fita_larg_mm`/`fita_alt_mm`
  [stamping], `valor_zinco`).
- `ribbons` (nome, tipo cera/misto/resina/outro, `largura_mm` [só cadastro], `comprimento_m`, `valor_rolo`).
- `custo_parametros` (linha única id=1): `preco_cliche_cm2` (default 0,17), `tinta_gramatura` (fração kg/m²),
  `tinta_preco_kg`. RLS: select authenticated, escrita `posso_editar()`.

**Fórmulas (motor único `custoProduto` no app, reusado por ficha/simulador/KPI):**
- **Clichê** (fixo, 1 por cor; 0 se chapado; +1 por acabamento `gera_cliche`):
  `Larg_cm = PISO[(larg_etiqueta*carreiras + espaco_carreiras*(carreiras−1) + esqueleto_lateral)/10] + 4`;
  `Alt_cm = ARRED[((alt+gap)*repetições)/10] + 4`; `custo = Larg_cm*Alt_cm*nClichês*preco_cliche_cm2`.
  Carreiras/repetições vêm da **1ª etapa `por_cor`** (impressão).
- **Tinta/verniz:** `m²_com_desp × gramatura × ocupação% × preco_kg` (gramatura já é fração do quilo;
  **não** divide por 1000). Tinta ainda **× nº cores**.
- **Hora-máquina:** Σ etapas `(prod_min + setup_min)/60 × R$/h`, onde `prod_min = qtd_rodar/vel`,
  `setup_min = metros_acerto/vel` (metros_acerto = base do grupo + Σ `setup_m` dos acabamentos na etapa de
  impressão). R$/h da estimativa = **média** das subs com `custo_hora>0` do grupo (o real por OS usaria a
  sub que rodou — hoje o KPI mostra a estimativa pela ficha).
- **Ribbon:** `metros = (etiquetas_líquidas/carreiras_ribbon) × passo/1000`; `custo = metros × valor_rolo/comprimento_m`.
- **Acabamentos:** filme `m²×valor_m2`; verniz (fórmula gramatura); stamping fita `(larg×alt mm²→m²)×etiquetas×valor_m2`.
- Substrato reaproveita a MP (`valor_m2`+ICMS+IPI) × m²_com_desp da 1ª etapa em metros.
- **Cascata** "quanto rodar" (`custoEsts`) **espelha** `materializarProduto` (replicada p/ não mexer na
  produção — anotar se um dia unificar).

**Frontend (`app.html`):**
- **Ficha**: campos novos (espaço/esqueleto, chapado, faca, ocupação de tinta, ribbon + carreiras de ribbon)
  + seção "Acabamentos aplicados" (checkbox por tipo, com params) + **prévia de custo para 1.000 etiquetas**
  (`renderFichaCusto`/`fichaProdLive`). `abrirFicha`/`espelharFicha` carregam `produto_acabamentos`;
  `salvarFicha` grava campos e `produto_acabamentos` só com `_custoReady`.
- **Aba Custo** (sidebar, gestor/editor via `ver_custo` em `PERM_ABAS`/`PERM_GESTOR_TABS`): parâmetros globais,
  cadastro de **acabamentos** e **ribbons**, e **simulador** (produto + qtd/um → custo). `renderCusto`.
- **Máquinas**: input **R$/h por submáquina** (`atualizarCustoHoraSub`).
- **KPI · popup da OS** (`kpiAbrirOS`): bloco "Custo estimado (ficha atual)" para a qtd do pedido.
- Bloco de resumo reutilizável `custoResumoHtml`; dados carregados por `ensureCustoData` (lazy, degrada).

**PENDENTE/próximo:** custo **real** por OS usando o apontado (sub que rodou, metros reais) — hoje o KPI
mostra o estimado pela ficha; ocupação de tinta por cor (hoje média por ficha); validar fórmulas com um
caso real do usuário.

## 14. Operador vê/aponta a máquina dele + MP no painel/impressão (2026-11-17) — EM PRODUÇÃO

**Status:** `23_`/`24_`/`25_` aplicados no banco e `app.html` publicado (2026-11-17).

**Problema:** o operador (`visualizador_maquina`) só via os itens **sem ficha** da máquina dele;
os itens **com ficha** sumiam. Ele deve ver **e apontar** os itens, mas **só quando estão na etapa
dele** (regra do usuário: CORTE vê CORTE, Digital vê Digital, etc.).

**Causa raiz (RLS, 2 camadas) — diagnóstico via impersonação no SQL Editor:**
1. **Leitura da camada de apontamento era por grupo:** o operador só lia as `ordem_operacoes` do
   **próprio grupo**, então para uma OS com roteiro ele recebia só a etapa dele e o `APONT_ESTADO`
   (fila/etapa atual) saía incompleto.
2. **`item_na_minha_maquina(ped,it)`** (gate da policy `SELECT` de `pedidos_abertos` p/ o operador)
   olhava **só a camada legada** (override + `pcp.grupo_maquinas`) e **ignorava o apontamento**. Um
   item com ficha cujo `pcp` está numa etapa anterior retornava `false` → o item **nem entrava na
   lista base** do painel (que é montada a partir de `pedidos_abertos`), mesmo com `APONT_ESTADO`
   pronto e a etapa atual sendo a máquina dele. Os sem ficha apareciam porque o `pcp` deles já está
   na máquina do operador.
   **ATENÇÃO:** a policy real de produção de `pedidos_abertos` **divergia do `03_rls_papeis.sql`**
   (no arquivo era leitura livre p/ o operador; na produção é `item_na_minha_maquina`). Sempre
   conferir o banco real (`pg_policies`, `pg_get_functiondef`) — ver regra geral no topo deste doc.

**Correções (idempotentes, reaplicáveis; escrita/apontamento INALTERADOS):**
- **`23_operador_apontamento.sql`**: operador passa a ler o roteiro **inteiro** das OS que tocam a
  máquina dele (helpers `os_toca_minha_maquina`/`apont_os_toca_minha`, SECURITY DEFINER). IDs são
  **uuid** (ordens/ordem_operacoes/apontamentos), não bigint.
- **`24_operador_apontamento_perf.sql`**: troca as funções **por-linha** do `23_` por **conjuntos
  calculados uma vez** (`minhas_ordens_ids()`/`minhas_operacoes_ids()`, usados com `id in (select …)`)
  nas policies de SELECT de `ordens`/`ordem_operacoes`/`apontamentos`. (A suspeita de timeout na
  leitura não se confirmou, mas a versão por conjunto é mais eficiente e ficou.)
- **`25_operador_pedidos_apontamento.sql`** (a correção decisiva): estende `item_na_minha_maquina`
  para **também** retornar `true` quando a **etapa ATUAL** (1ª `ordem_operacoes` não finalizada por
  `etapa_idx`) da OS está numa máquina do operador. Mantém as 2 regras antigas (override/pcp) e a
  escrita intactas. Assim os itens com ficha na etapa do operador entram na lista base e aparecem;
  os que estão a montante continuam ocultos (a regra do usuário).

**Frontend (`app.html`):**
- **Painel do operador:** filtra os grupos exibidos por `PERFIL.maquinas_permitidas` (reforço visual;
  o RLS já recorta). Operador só vê os cards das máquinas dele.
- **Coluna "Matéria-prima" no painel** (`linhaHtml`/`tabelaHtml`, de `MP_NOME_POR_PA`).
- **Impressão/PDF**: colunas **PA** (código do produto) e **Matéria-prima** (`linhaImpressaoHtml`/
  `blocoGrupoImpressaoHtml`; colspan da sub-linha ajustado p/ 10).
- Apontamento do operador já funcionava por `perm('acao_apontar')` (default true) + RLS de insert
  restrito ao grupo dele.

**Limitação conhecida:** itens que saíram de `pedidos_abertos` mas ainda têm etapa pendente em
`ordens` (ex.: 11596-1, 11597-1) **não aparecem** no painel, porque ele é montado a partir de
`pedidos_abertos`. Para cobrir esses, seria preciso montar a linha do painel também a partir de
`ordens` (não feito).

## 15. Prioridade, Ações, página/batida no setup e setup por trechos (2026-11-18 a 20)

**Status:** branch `feat/acoes-prioridade` (acumula tudo abaixo). Migrations `26_`–`30_`.
Validado localmente pelo usuário item a item; **aplicar as migrations e publicar o `app.html`
pelo fluxo manual** (deploy é do usuário). Tudo aditivo/retrocompatível — **não** altera a
produção/apontamento legados nem OS antigas.

### Rollout híbrido — encaminhar p/ a FRENTE (não voltar)
Quando uma etapa ON (ex. CORTE) finaliza e a PRÓXIMA está num grupo OFF (programação manual, ex.
REVISORA), o item **avança** p/ a etapa manual seguinte em vez de "voltar" p/ a etapa ON anterior
(ex. DIGITAL). A cadeia segue a ordem do roteiro; a etapa atual é sempre a 1ª não-finalizada
(mesmo OFF). Itens em grupo OFF ganharam **"Reabrir etapa"** (gestor/editor) p/ desfazer a
finalização manual de uma etapa (distinto do `reabrirApontamento`/`reabrirItem`).

### Filtro de Situação (painel)
Seletor na barra de filtros do painel: **aguardando / em setup / em produção / parado / falta de
material** (pendência de material aberta). Só visual; recorta os itens exibidos pela situação do
apontamento.

### Prioridade na fila — `27_prioridade.sql`
Flag `overrides.prioridade` (bool, default false). Gestor/editor marca o item (pelo popup **Ações**)
→ ele vai p/ o **topo** da fila da máquina dele, com ❗. Entre os priorizados, a ordem do arraste
vale (`ordCompare`/`ordComparePainel` colocam prioridade primeiro, depois a ordem manual). Decisão
do usuário: "indico prioridade e lá eu arrasto". Escrita de `overrides` já é `posso_editar()`.

### Popup "Ações" — `abrirAcoes`
Consolidou os botões por item do painel (**Ver ficha, Configurações da OS, Pendência, Prioridade**)
num **único** botão "Ações" que abre um popup com essas opções. O botão **Apontamento** fica
separado (ação principal). Reduz a poluição da linha do painel.

### M/L inclui o setup
A coluna **M/L** do painel passou a mostrar o **total estimado da etapa = setup (em metros) +
produção com desperdício** (`desp_setup_est + qtd_rodar_est`), não só a produção.

### VOREY por página — `26_vorei_pagina.sql`
A sub-máquina **VOREY** (grupo CORTE) calcula **por página**, como a batida: `páginas =
etiquetas ÷ (carreiras × repetições)`; velocidade em **páginas/h** (`maquinas_sub.velocidade_pagina`,
flag `maquinas_sub.por_pagina`). **BROTECH** segue em metro. O operador informa carreiras × repetições
**ao iniciar o setup** (RPC `iniciar_setup_pagina`, SECURITY DEFINER: valida permissão + status
`aguardando`, insere o `setup_inicio` e recalcula a etapa). Coluna `ordem_operacoes.repeticoes`.
Helpers no app: `subEhPagina`, `grupoEhUnidade`, `setupPorImagens`, `grupoTemPagina`, `apUnidadeLabel`.
**Idempotente:** recalcula sempre das **ETIQUETAS da OS** (invariante = `ordens.qtd × conversão`) e
das **razões** da op (`qtd_rodar/qtd_est`, `desp/qtd`), então reabrir/trocar os valores recalcula
proporcional, **não compõe** (bug de composição corrigido ao reescrever a RPC a partir do invariante).

### Batida — carreiras × repetições no setup — `28_batida_setup.sql`
Generaliza `iniciar_setup_pagina` p/ o grupo em `modo='unidade'` (batida): mesma matemática, com
velocidade da **sub-máquina** (batidas/h) e fallback na velocidade do grupo. O operador informa
carreiras × repetições **no setup** (antes só na ficha). Igual à VOREY (idempotente pelo invariante).

### Lançamento manual recalcula + rótulos + prévia — `29_recalcular_imagens.sql`
- **`29_`** (endurecida em 2 revisões de segurança): separa o recálculo numa função **interna**
  `_recompute_imagens` (**sem grant** a authenticated/anon/public; revalida permissão por defesa em
  profundidade) e expõe a chamável `recalcular_op_imagens` (`FOR UPDATE`, valida permissão +
  `status='aguardando'` **antes** de qualquer efeito, depois chama a interna). Serve p/ o
  **lançamento manual** de VOREY/batida (`apManualRegistrar`) também recalcular a etapa (máquina +
  carreiras × repetições) antes de gravar o bloco, igual ao Iniciar setup. A `iniciar_setup_pagina`
  foi realinhada ao mesmo padrão (valida antes, insere `setup_inicio`, recalcula).
- **Rótulos de unidade** (`apUnidadeLabel(op)`): o modal mostra **"metros" / "páginas" / "batidas"**
  conforme a etapa, não "metros" fixo — vale p/ lançar, finalizar e lançamento manual.
- **Prévia em tempo real** (`apPreviaCalc`/`apPreviaSetup`): ao digitar carreiras/repetições no setup
  de VOREY/batida, mostra ao vivo a estimativa resultante (páginas/batidas + tempo).

### Setup com trechos + paradas — `30_setup_trechos.sql` (2026-11-20)
O **setup** ganhou o **mesmo módulo da produção**: **lançar acerto por trecho**, **parada com
motivo** durante o setup e **finalizar** somando os trechos + o valor final (opcional). Para setups
longos. `30_` (idempotente):
- Novo evento **`setup_lancamento`** (enum `tipo_apontamento`): **não muda status** (cai no `else`
  dos triggers, mantém `em_setup`).
- **`parada_fim` ciente da fase**: se ainda **não** houve `prod_inicio` na op, volta p/ `em_setup`;
  se já houve, volta p/ `em_producao` (como antes). Aplicado em `aplicar_apontamento` e em
  `status_operacao_log` (que também **ignora** `setup_lancamento`/`lancamento`/`observacao` ao deduzir).
- **A view de KPI NÃO muda**: o desperdício de setup segue lido do **`setup_fim.qtd`**, onde o app
  grava o **TOTAL** (Σ trechos + final) em `apFinalizarSetup`.
- App: estado `em_setup` com Lançar (`apSetupLancar` → `setup_lancamento`) / Parada (`apSetupParada`)
  / Finalizar setup (`apFinalizarSetup`, trava zerado com confirmação, aproveita o campo digitado);
  estado `parado` **ciente da fase** (mostra *Acerto* × *Produzido*; botão "Retomar setup/produção",
  via `apTemProdInicio`). **Histórico** (`apHistorico`): `setup` virou **bloco** com `lancs` e cada
  trecho (`slanc`) aninhado sob ele, como os lançamentos na produção (modal `apHistoricoHtml` e popup
  de KPI `kpiHistHtml`). Helper `apSomaSetupLanc`.

**PENDENTE desta leva:** aplicar `26_`–`30_` no banco e publicar o `app.html` da branch
`feat/acoes-prioridade`; retomar os **custos** (§17).

## 16. KPIs — nível-OS físico, MP+setup, setup real/est (2026-11-20 a 22)

Tudo na branch `feat/acoes-prioridade`; só frontend (sem schema). Validado pelo usuário.

- **Desperdício no NÍVEL-OS = FÍSICO** (card do topo, coluna da tabela "por OS" e Total do popup).
  Antes somava o refugo por etapa (contava o mesmo substrato 2×). Agora:
  **Desp. real** = `rodado da 1ª etapa − líquido` (`kOsMetros.qtd_real − qtd_est`); **Desp. vs previsto** =
  `rodado da 1ª etapa − previsto a rodar da 1ª etapa` (o previsto da 1ª etapa já embute a cascata).
  **%**: Desp. real sobre o **líquido** ("a mais que o líquido"); vs previsto sobre o **previsto**.
  As linhas **por máquina** e **por etapa** (popup) seguem o **refugo operacional por etapa** (`rodado − kBase`),
  então a soma por máquina NÃO bate com o card da OS — proposital (medidas diferentes; há legenda).
- **KPI "Por matéria-prima" inclui o SETUP** no m²: `m² rodado = (qtd_real + desp_setup_real) × largura`;
  `m² estimado = (previsto a rodar + desp_setup_est) × largura` (o acerto também consome substrato).
- **Setup em metros com comparativo real/est** nas tabelas **por máquina** e **por OS** e no **popup**
  (coluna "Desp. setup real/est"); o card do topo já trazia estim.+%. Setup continua **somando** entre etapas.

**Parser de OP → fichas (`tools/importar_fichas_op.py`): ABORTADO.** Chegou a ler os PDFs de OP do ERP e
gerar a planilha no formato do import de fichas, mas o usuário **desistiu** (risco de leitura/dado errado).
O script existe na branch, inerte; não é o caminho atual.

## 17. Custo do produto vendido — v2, UNIFICADO nas matérias-primas (2026-11-21 a 22)

**Status:** branch `feat/acoes-prioridade`; `31_custo_mp.sql` **aplicado em teste**, `app.html` **não publicado**.
Validado item a item pelo usuário. **SUBSTITUI a §13/`22_`** (órfão — não aplicar). **Produção/painel 100%
INTOCADOS**: os campos novos são aditivos e lidos **só** pelo motor de custo; o painel segue lendo
`produto_etapas`/`produtos`/`pcp` como sempre. Gates: `window._mpTipoReady` (31_ aplicado) + `_podeEditar`.

### Decisão de arquitetura
**Tudo se cadastra nas Matérias-primas, por `tipo`.** Não há "parâmetros globais". `materias_primas.tipo` ∈
`substrato | laminacao | verniz | tinta | cliche | ribbon | stamping`, cada tipo com seus campos de cálculo
(`20_`/`21_` + `31_`). A **ficha do produto é ÚNICA** (produção + custo no mesmo form). A **aba Custo** fica
só com o **simulador**. `31_` é idempotente e reconcilia resíduos do `22_` (dropa a FK antiga
`produtos_ribbon_id_fkey`; ajusta `produto_acabamentos`).

### Matérias-primas por tipo (campos de cálculo)
- **substrato**: `valor_m2` (BRUTO, R$/m²), `largura_mm`, `icms_pct`, `ipi_pct`.
- **laminação / stamping (fita)**: `valor_m2` (R$/m²).
- **verniz**: `gramatura` (**g/m²**) + `preco_kg` (R$/kg); flag `gera_cliche` (localizado/cold → +1 clichê).
- **tinta**: aplicação **flexo** (`gramatura` g/m² + `preco_kg`) OU **digital** (`valor_m2` R$/m² + `sub_id`
  = sub-máquina digital + flag `tinta_branca` = add-on de branco sobre o base da mesma sub).
- **clichê**: `valor_m2` = **R$/cm²**.
- **ribbon**: `comprimento_m` (m/rolo) + `valor_rolo` (R$/rolo) + `largura_mm`.
- Comuns a acabamentos: `setup_m` (acerto), `gera_cliche`, `gera_zinco` (hot → zinco).
- A lista mostra o valor na unidade certa por tipo (`mpValorCol`: /kg verniz/tinta-flexo, /rolo ribbon,
  /cm² clichê, /m² demais). Form: campos trocam por tipo (`mpAplicarTipo`), com aplicação flexo/digital p/ tinta.

### Ficha única (ordem das seções + gatilho)
`renderFicha`: **Dados técnicos** (PA, descrição, **Impressão** [gatilho: sem/digital/flexo], larg/alt/gap, e
— só flexo — espaço entre carreiras, **nº de carreiras**, **repetições**, esqueleto) → **Cores e processos**
(só impresso; nº cores, ocupação de tinta, chapado, tinta branca[digital]) → **Acabamentos**
(`produto_acabamentos`: verniz/laminação/cold/hot; verniz localizado → ocupação; stamping → fita L×A; hot →
valor do zinco) → **Matéria-prima** (substrato + largura) → **Ribbon** (MP tipo ribbon + carreiras de ribbon) →
**Conversões** → **Roteiro de produção** (inalterado; cada etapa ganhou **"Máq. custo"** = sub só p/ custo,
`produto_etapas.maquina_custo`) → **Custos** (faca R$) → **Prévia de custo (1.000 et.)**.
O gatilho **`impressao`** (`produtos.impressao`) esconde seções (`fichaAplicarImpressao`): *sem impressão* →
sem cores/clichê/tinta; *digital* → sem clichê de cor; *flexo* → com clichê. **carreiras/repetições do CLICHÊ
ficam nos dados técnicos** (`produtos.carreiras`/`repeticoes`), não na etapa do roteiro. `salvarFicha` grava
produtos (campos de custo) + `produto_acabamentos` + `produto_etapas.maquina_custo`, tudo com gate.

### Motor `custoProduto(prod,etapas,conv,acabs,qtd,um)`
- **m² (substrato)** = `[ (etiquetas/carreiras × passo/1000) ÷ (1 − Σdesp%) + Σ setup(m) de TODAS as etapas ]
  × largura_substrato/1000` — i.e. `metrosRodar = qtdRodar(1ª etapa) + acerto da própria 1ª etapa`; largura =
  **do substrato** (não do produto). Cada etapa roda o SEU metro da cascata (a revisora NÃO roda o total da flexo).
- **Hora-máquina** por etapa = **Acerto** (`setup_min → h × R$/h`) + **Execução** (`metros a rodar da etapa ÷
  velocidade × R$/h`). R$/h e velocidade vêm da **sub de custo** (`maquina_custo`) da etapa; sem sub → média do
  grupo. (Acerto é TEMPO de setup, não desperdício÷velocidade — bug corrigido.)
- **Clichê** (fixo): `PISO[(larg_et×carr + espaço×(carr−1) + esqueleto)/10]+4 × ARRED[((alt+gap)×rep)/10]+4 ×
  nº clichês × R$/cm²`; R$/cm² da **MP tipo clichê** (fallback `custo_parametros.preco_cliche_cm2`=0,17).
  nº clichês = cores (0 se `chapado` **ou** impressão ≠ flexo) + acabamentos `gera_cliche`. carr/rep dos dados técnicos.
- **Tinta**: flexo = `m²×(gramatura/1000)×ocupação%×R$/kg` — **NÃO × cores**, e **só da MP tinta flexo** (sem
  fallback a parâmetro global); digital = `m²×(insumo base + branca)` das MPs tinta por sub.
- **Acabamentos**: laminação `m²×valor/m²`; verniz `m²×(gram/1000)×ocupação×R$/kg` (ocupação 100% se verniz
  total); stamping `(fita L×A mm²→m²)×etiquetas×valor/m²`. Zinco (hot) = fixo.
- **Ribbon**: `metros=(etiquetas/carreiras_ribbon)×passo/1000`; `rolos=teto(metros/comprimento_rolo)`;
  `custo=rolos×valor_rolo`.
- **Substrato = BRUTO** (sem ICMS/IPI no custo). **Crédito de ICMS** sai como **DEDUÇÃO** à parte: cada material
  com `icms_pct>0` gera `crédito = total × icms%`; **Custo líquido = bruto − Σ crédito ICMS**. (IPI/DRE completo
  fica p/ depois.)
- **Detalhamento** (`custoResumoHtml`): tabela com seções **Fabricação** (acerto/execução por máquina, com
  metros e velocidade), **Materiais**, **Deduções (crédito de ICMS)** e **Fixos**; colunas Tipo (F/V), Un., Qtd,
  R$ unit., Total e %; totais bruto/líquido/unitário; e "detalhes do cálculo" (metros líq/rodado, m² líq/rodado,
  perda m e %). Espelha o Relatório de Custos do ERP do usuário.

### Aba Custo + Máquinas
- **Aba Custo** (sidebar `ver_custo`, gestor/editor): só o **simulador** (campo de busca por código/descrição →
  `custoProduto` → detalhamento). `renderCusto`/`custoSimular`. Sem card de parâmetros globais.
- **Máquinas**: input **R$/h por sub-máquina** (`atualizarCustoHoraSub` → `maquinas_sub_custo.custo_hora`;
  `CUSTO_HORA_SUB` carregado no `recarregarDoBanco`). `maquinas_sub_custo` também tem `insumo_m2` (não usado —
  a tinta digital ficou como MP).
- `ensureCustoData` carrega `custo_parametros` + `CUSTO_HORA_SUB` (lazy, degrada). `custoAcabsNorm` monta os
  acabamentos (MP→{tipo_calculo, valores, icms_pct, params do produto}). Prévia: `custoFichaPreview`/`prodFromFicha`.

**PRÓXIMO (visão do usuário):** **KPI de margem** — o Excel de pedidos que já é subido passa a trazer
**preço/emissão**, e o sistema mostra faturamento × custo = **margem** por item e por mês.
