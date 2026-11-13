# PCP — Monitoramento de Produção (estado atual)

Documento técnico/handoff do projeto PCP. Leia antes de continuar o trabalho.
Última atualização: 2026-11-10.

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
- **Máquinas**: config completa editável (modo, velocidade, % desperdício, setup/desperdício
  por modo, acabamento verniz/laminação + custo, velocidade por sub-máquina). Grava direto.
- **Fichas técnicas**: lista de produtos (busca, editar), "Novo produto" (código editável),
  "Produtos em OS sem ficha" (ignora PR/SE), **import por Excel** (botão Modelo + Importar).
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

**Histórico de apontamentos** (por etapa, `apHistoricoHtml`): uma **linha por bloco** em
ordem cronológica — Setup / Produção / Parada (`dd/mm hh:mm → hh:mm` + duração + metros/motivo),
Validação / Reabertura / **Observação** — com o **nome do operador** (de `profiles.nome`, carregado em
`apCarregar` → `AP_OPERADORES`; degrada p/ "—" se a RLS não liberar). Em `<details>` recolhível.

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
**`18_papel_permissoes.sql`** (tabela `papel_permissoes`; idempotente, SEM seed).

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
