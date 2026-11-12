# D&A Print — Referências e diretrizes do redesign

## Escopo visual validado
- Sidebar azul-marinho à esquerda com botão hambúrguer, expandir/recolher, item ativo em vermelho.
- Barra superior com busca, tema, usuário e sair (respeitar as funcionalidades reais).
- Fundo claro, cartões brancos, linhas e bordas suaves, hierarquia visual, indicadores legíveis.
- Responsividade desktop/tablet; acessibilidade; estados de carregamento, vazio e erro.
- Preservar tema escuro existente e permitir alternância consistente.

## Mapeamento real do ZIP recebido
- `app.html`: SPA principal com abas `tab-painel`, `tab-categorias`, `tab-vendedores`, `tab-maquinas`, `tab-fichas`, `tab-kpis`, `tab-usuarios`, `tab-historico`.
- `index.html`: acesso/login (não confundir com uma nova página Dashboard).
- `rastreio.html`: rastreamento externo; não redesenhar sem aprovação adicional.
- `producao.html`: protótipo local, não é a implementação principal; não substituir `app.html` por ele.
- `CLAUDE.md`: fonte principal de regras e decisões; ler integralmente antes de mexer.
- `13_producao_apontamentos.sql`: backend já desenvolvido; não alterar/aplicar migrações sem aprovação.

## Páginas e referência de imagem
- Painel: `02_painel_producao.png` (layout principal de ordens e fluxo).
- Fila por equipamento: `09_visao_geral_e_fila_por_equipamento.png` (concepção do menu lateral + acesso destacado; **não substituir a fila real por um resumo superficial**).
- Categorias: `03_categorias.png`.
- Vendedores: `04_vendedores.png`.
- Máquinas: `05_maquinas.png`.
- Fichas técnicas: `06_fichas_tecnicas.png`.
- KPIs: `01_kpis.png` (referência visual original aprovada).
- Usuários: `07_usuarios.png`.
- Histórico: `08_historico.png`.

## Fila por equipamento — requisito CRÍTICO
O `CLAUDE.md` já documenta agrupamento e movimentação das ordens por máquina, ordenação e seleção de sub-máquina. Deve continuar funcional com qualquer novo layout:
1. Manter agrupamento por grupo/sub-máquina e ordenação existente (incluindo arrastar para reordenar quando permitido).
2. Mostrar OS, cliente/produto, status, etapa atual, metragem da etapa, metragem restante, tempo restante, alertas e próxima etapa quando os dados existirem.
3. Com lançamento parcial em uma etapa, a OS pode aparecer também na fila da próxima com aviso claro **"Parcial · etapa anterior em andamento"**. Permanecer na fila da etapa anterior até encerramento real; não duplicar OS nos totais globais.
4. Configurar destaque para `em_setup`, `setup_ok`, `em_producao`, `parado`, `finalizada` e `aguardando` conforme estados existentes; sem inventar novos estados persistidos.
5. Manter ações e autorização por papel, operador, máquina e RLS.
6. Permitir alternância entre uma visualização por máquinas (cards/colunas com agrupamento original) e lista, sem perder as funções de movimentação e detalhes.

## Dados, métricas e limites
- Mockups são referências **visuais** com números e exemplos fictícios. Não usar valores, e-mails ou nomes dos mockups como seeds ou dados reais.
- Manter as fórmulas vigentes, principalmente KPI desperdício real vs previsto, cascata da quantidade a rodar e regra de não somar metros entre etapas.
- Não exibir OEE ou disponibilidade como indicadores finais sem calendários/turnos validados.
- Não trocar nomes de objetos SQL nem duplicar banco/funções para atender ao visual.
- Não publicar nem fazer push/deploy sem autorização explícita.

## Ordem sugerida de implementação
1. Auditar `app.html` e produzir inventário das abas, funções JS, eventos, seletores e permissões (sem editar).
2. Criar shell compartilhada: sidebar/hambúrguer, topbar, design tokens, comportamento responsivo, navegação atual.
3. Implementar Painel e Fila por Equipamento, com todos os controles preservados.
4. Implementar KPIs mantendo cálculos/filtragens e detalhes por OS.
5. Implementar Máquinas, Fichas Técnicas, Categorias, Vendedores, Usuários e Histórico.
6. Validar tema escuro, mobile/tablet, permissões e regressão de fluxos operacionais.

## Critérios de aceitação
- Nenhum clique/ação anterior desaparece sem justificativa e aprovação.
- Upload das bases, processar/recarregar e fluxo de ordens continuam funcionando.
- Apontamento em etapas (setup, produção, parada, lançamento de metragem, finalizar, manual) continua funcionando.
- A fila mantém agrupamento, sequência, estados e atualização após lançamentos parciais.
- KPIs conservam métricas, fórmulas, filtros e popup por OS.
- Fichas técnicas e configurações de máquinas mantêm todos os campos e cálculos.
- Usuários e permissões mantidos; histórico disponível.
- Sem alteração do banco, dados ou deploy nesta fase visual.
