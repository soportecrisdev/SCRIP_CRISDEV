# BTUN pré-ZTUN 1.0.44 — instalador AIO offline

Este pacote instala localmente BHTTP, SSH_XHTTP e BTUN, sem ZTUN e sem baixar
arquivos da internet. Ele já contém os binários Linux AMD64 e ARM64, os testes,
o gerador de certificado, o menu `bhttp` e a source completa usada na compilação.

## Instalação

Envie o ZIP para a VPS, entre como `root` e execute:

```bash
mkdir -p /root/btun-offline
cd /root/btun-offline
unzip /root/BTUN-pre-ZTUN-OFFLINE-AIO-v1.0.44.zip
bash install.sh
```

Não use `--host`: o instalador detecta automaticamente o endereço da própria
máquina. Para trocar apenas a porta SSH local, use:

```bash
bash install.sh --ssh-port 22
```

Portas padrão:

- `80/tcp`: BHTTP para SSH
- `443/tcp`: SSH_XHTTP e BTUN compartilhados por TLS
- `7080/tcp`: BTUN sobre BHTTP
- `7300/tcp` e `7300/udp`: BTUN nativo
- `7443/tcp`: BTUN sobre XHTTP dedicado

Após instalar, execute `bhttp` para abrir o menu ou `bhttp status` para consultar
o serviço principal.

## Requisitos locais da VPS

O pacote não precisa de internet, compilador, Go nem OpenSSL. A imagem base da VPS
precisa ter Linux AMD64 ou ARM64, `systemd`, OpenSSH, PAM/glibc, `iproute2`,
`iptables`, `/dev/net/tun` e o comando `unzip`. Esses componentes normalmente já
existem em Ubuntu Server 22.04/24.04 e Debian 12 com OpenSSH instalado.

O instalador verifica tudo antes de alterar os serviços. Se algo estiver ausente,
ele termina com uma mensagem clara; como a instalação é offline, o componente de
sistema deve ser incluído previamente na imagem da VPS.

## Conteúdo

- `bin/amd64/`: binários pré-compilados para x86-64
- `bin/arm64/`: binários pré-compilados para AArch64
- `sources/bilola_go_port/`: source completa da versão pré-ZTUN 1.0.44
- `tools/certgen/main.go`: source do gerador de certificado incorporado
- `bhttp-menu`: menu local de gerenciamento
- `SHA256SUMS`: hashes para verificar todos os arquivos do pacote

Para conferir a integridade após descompactar:

```bash
sha256sum -c SHA256SUMS
```

O instalador salva a configuração existente em
`/root/bhttp-preztun-backup-AAAAMMDD-HHMMSS` antes de substituí-la.

## Instalação rápida e sem perguntas (setup.sh)

Se preferir um passo único e não interativo, use o `setup.sh`: ele verifica a
integridade, repara as permissões dos binários, executa o `install.sh`
(deteção automática de IP/arquitetura), garante o login por senha no SSH
(sem exigir chave/key) e cria um usuário opcional sem prompts.

```bash
sudo bash setup.sh
# opcional, sem perguntas:
SETUP_SSH_PORT=22 SETUP_USERNAME=cliente SETUP_PASSWORD='sua-senha' sudo bash setup.sh
```
