# Contrato de isolamento do Claude Code manual

Cada registro manual usa seu UUID como identidade local. O rótulo `ClaudeCLI 0`, `ClaudeCLI 1` etc. é apenas apresentação; reutilizar um ordinal sempre gera outro UUID e outra árvore de dados.

O PainelCli instala `@anthropic-ai/claude-code@latest` do registry npm oficial usando um prefixo local dentro da instalação do UUID. O prefixo, cache npm, HOME, XDG, temporário, configuração e histórico ficam sob essa raiz. Node.js 22+ e npm são pré-requisitos existentes; o app não instala nem altera runtimes globais. A instalação registra a versão real do CLI e só é reconhecida quando o executável canônico e a configuração privada do UUID passam pela validação.

O runtime passa `CLAUDE_CONFIG_DIR` apontando para `installation/claude-config` do UUID e não herda variáveis de autenticação/API key do app. A documentação oficial descreve `CLAUDE_CONFIG_DIR` como diretório de settings, credenciais, histórico e plugins; no macOS, o CLI usa Keychain criptografado e vincula sua entrada ao caminho desse diretório, com fallback para `.credentials.json` privado dentro dele quando o Keychain não pode gravar. A verificação exige `claude auth status --json` (Claude Code 2.1.268+) e aceita somente `authMethod: "claude.ai"` cujo `configDirectory` resolva para o diretório do mesmo UUID. `none` significa não autenticado. API keys, tokens OAuth, helpers e outros providers resultam em estado incompatível/indeterminado, nunca em autenticado.

O login usa o comando oficial `claude auth login`, sem `--console`, setup-token ou credenciais copiadas. O PainelCli passa Safari como preferência somente para aquele subprocesso (`BROWSER`) e nunca altera o navegador padrão do macOS; Anthropic não documenta `BROWSER` como opção estável da CLI, portanto a abertura do Safari precisa ser confirmada pelo teste humano. Nenhum login é iniciado no startup/build. O logout usa `claude auth logout` com o mesmo ambiente e reconsulta o status. O provedor pode invalidar uma credencial durante o logout; a UI não promete revogar todas as sessões remotas.

Desinstalar remove apenas `package/` e `install.json`, preservando configuração, histórico, cache e credencial para reinstalação. A lixeira requer a CLI instalada para executar o logout oficial e limpar a credencial escopada no Keychain antes de apagar a raiz UUID. Se o pacote já foi desinstalado, a operação falha e mantém cadastro e dados: apagar só o diretório não prova a remoção da entrada externa no Keychain. Reinstale o pacote gerenciado e repita a lixeira. Nenhuma API privada do Keychain nem inspeção de segredo é usada.

## Fontes oficiais

- [Authentication](https://code.claude.com/docs/en/authentication): múltiplos `CLAUDE_CONFIG_DIR`, armazenamento de credenciais, login/ logout e ressalva de Console sem API key.
- [Environment variables](https://code.claude.com/docs/en/env-vars): semântica de `CLAUDE_CONFIG_DIR`.
- [CLI reference](https://code.claude.com/docs/en/cli-reference): `claude auth login`, `claude auth logout`, `claude auth status --json` e versão mínima de `configDirectory`.
- [Advanced setup](https://code.claude.com/docs/en/setup): requisitos, distribuição npm, binário nativo e verificação de integridade.

## Limites da evidência

Os testes de PainelCli usam executáveis e respostas sintéticos; não executam npm, CLI Claude, Keychain, login/logout real ou pedido a modelo. Eles provam apenas que os argumentos, o ambiente, o parser, os locks e a limpeza por UUID obedecem ao contrato implementado. João deve validar uma instalação/login real com sua conta e confirmar que o Safari abre, que `auth status` mostra Claude.ai nessa configuração e que duas contas ficam independentes. O mecanismo Keychain é sustentado pela documentação oficial atual, não por leitura de itens/segredos nem por uma autenticação real nesta tarefa.
