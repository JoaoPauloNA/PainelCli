# BUG-PC-ACTION-UI-001 — identificação e consistência das ações compactas

- Data: 2026-10-16. Responsável visual: Mac_Layout. Teste de usuário: João.
- Baseline: `1563fe5`; bundle anterior 0.0.0.27.
- Origem: pedido de João para padronizar todas as ações em ícones; inspeção estática encontrou desinstalação e remoção com o mesmo `trash`, e valor acessível da remoção baseado em origem manual, mesmo quando o controle estava bloqueado.
- Estado: regressão técnica/estática corrigida; aceitação visual/interativa pendente.

## Reprodução

1. Inspecionar a linha manual Codex instalada no baseline: a ação Desinstalar usa `trash`, como Remover cadastro.
2. Inspecionar a remoção de um manual em operação concorrente: `isEnabled` pode ser falso, mas o valor acessível declara `Disponível` por depender só de `isManualEntry`.
3. A configuração das imagens não é normalizada num único padrão de tamanho/posição.

Esperado: ícones sem texto, tamanho consistente; desinstalação representada por pacote e remoção por lixeira; estado acessível da remoção baseado no `isEnabled` já calculado. Disponibilidade, handlers, UUID e operações não são responsabilidade da apresentação.

Observado: inconsistências acima confirmadas somente por inspeção estática. Não foi acionado nenhum controle na sessão real.

## Correção visual

- Helper `applyActionAppearance(_:)` normaliza somente estilo, imagem e tamanho do símbolo (14 pt), sem mudar target/action/tag/isEnabled.
- Controles preservam 28 × 28 pt e espaçamento de 8 pt.
- Sair: `power`; Desinstalar: `shippingbox`; Remover: `trash`; Instalar: `arrow.down.circle`.
- Login habilitado verde, logout/cancelar/desinstalar laranja, remover vermelho; desativados cinza semântico.
- Confirmações e semântica de preservação de dados/credenciais mantidas literalmente.

## Regressão

REGRESSION_TEST: `Tests/manual_install_ui_contract.py`, bloco BUG-PC-ACTION-UI-001, acrescido sem remover verificações funcionais existentes.
INITIAL_STATE: fontes de `1563fe5`, sem fixtures reais, sem UI.
TEST_COMMAND: `python3 Tests/manual_install_ui_contract.py`; suíte exigida `bash scripts/ci-check.sh`.
BEFORE_FIX: FAIL por ausência de padronização, ícone duplicado e valor acessível incorreto; log em DadosTeste da rodada .28.
AFTER_FIX: PASS no mesmo teste e na suíte existente; evidência `DadosTeste/2072-PainelCli-0.0.0.28-AcoesVisuais`.
AFFECTED_SUITE: suíte AppKit + testes sintéticos de armazenamento/instalador/auth + contratos UI/ícones existentes.
AUTOMATION_LIMITATIONS: contrato estático não mede renderização, contraste ou usabilidade; João faz teste visual/interativo.
RETEST_VERDICT: pendente de João. Sem claim de execução real de login/logout/desinstalação.
