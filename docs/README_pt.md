<div align="right"><a href="../README.md">English</a> · <a href="README_zh.md">中文</a> · <a href="README_ja.md">日本語</a> · <a href="README_ko.md">한국어</a> · <a href="README_ru.md">Русский</a> · <strong>Português</strong></div>

# vphone-cli

Inicializa um iPhone virtual com o Virtualization.framework da Apple e a infraestrutura de pesquisa PCC VM.

![iPhone virtual no macOS](demo.jpeg)

O fluxo público de firmware agora oferece **apenas JB**. Ele aplica os patches de sistema necessários e instala o vphoned para controle pelo host. O ambiente do usuário no guest permanece vazio: não instala gerenciador de pacotes, SSH, VNC nem bootstrap no primeiro boot.

## Início rápido

É necessário um Mac com Apple Silicon e macOS 15 ou posterior. O host precisa permitir VMs de pesquisa PV=3 e os direitos privados do `vphone-vm`; veja a [configuração do host](guides/host-setup.md).

```sh
vphone-cli vm create myphone \
  --iphone-source /path/to/iPhone17,3_Restore.ipsw \
  --cloudos-source /path/to/cloudOS.ipsw

vphone-cli vm launch myphone
```

`vm create` prepara e aplica os patches, restaura via DFU, instala o CFW e confirma um ping real do vphoned no primeiro boot. **A VM usada nessa verificação é encerrada após o sucesso.** Execute `vm launch` para continuar usando-a. A restauração precisa de rede; a instalação do CFW pede autenticação de administrador.

Com cloudOS 26.4 (`23E5207q`), iPhone17,3 iOS 26.6.2 (`23G90`) e 27.0 (`24A435`) chegaram à tela bloqueada e responderam ao ping do vphoned. Veja o alcance desses testes na [compatibilidade](guides/compatibility.md).

## Instalação e compilação

O `.app` distribuído roda sem Homebrew, Python, Xcode ou outro ambiente de execução. A compilação a partir do código-fonte requer Xcode com o SDK do iPhoneOS para compilar o vphoned.

```sh
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git
cd vphone-cli
make build
.build/release/vphone-cli host preflight
```

Se o host usar a lista de permissões AMFI, execute `make amfi_allow` novamente após cada compilação. O [índice da documentação](README.md) reúne os guias atuais e as notas de pesquisa. Os guias detalhados estão em inglês no momento.
