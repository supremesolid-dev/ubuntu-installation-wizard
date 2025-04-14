#!/usr/bin/env bash

# === Configuração de Segurança e Robustez ===
set -euo pipefail

# === Constantes ===
readonly REQUIRED_PKGS=("snapd")
readonly LXD_SNAP_NAME="lxd"
readonly LXD_GROUP="lxd"
readonly DEFAULT_STORAGE_POOL="default"
readonly DEFAULT_NETWORK="lxdbr0"
readonly WAIT_TIMEOUT=60

# === Cores para Terminal ===
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

# === Funções de Log ===
log() { echo -e "${GREEN}[✔]${RESET} $1"; }
warn() { echo -e "${YELLOW}[⚠]${RESET} $1" >&2; }
error_exit() {
    echo -e "${RED}[✖]${RESET} $1" >&2
    exit 1
}
info() { echo -e "${BLUE}[ℹ]${RESET} $1"; }

# === Funções Auxiliares ===

# Verifica execução como root
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        error_exit "Este script precisa ser executado como root (ou com sudo)."
    fi
}

# Verifica e instala dependências do sistema
check_and_install_deps() {
    info "Verificando dependências do sistema (${REQUIRED_PKGS[*]})..."
    local missing_pkgs=()
    for pkg in "${REQUIRED_PKGS[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        warn "Dependências faltando: ${missing_pkgs[*]}"
        info "Tentando instalar dependências..."
        apt-get update -y || error_exit "Falha ao executar apt update."
        apt-get install -y "${missing_pkgs[@]}" || error_exit "Falha ao instalar dependências: ${missing_pkgs[*]}"
        log "Dependências instaladas com sucesso."
    else
        log "Dependências do sistema OK."
    fi
}

# Instala ou atualiza o LXD via snap
install_or_refresh_lxd() {
    info "Verificando instalação do LXD snap..."
    if snap list "${LXD_SNAP_NAME}" &>/dev/null; then
        log "LXD snap já está instalado. Atualizando para a última versão estável..."
        snap refresh "${LXD_SNAP_NAME}" || warn "Falha ao tentar atualizar o LXD snap. Continuando com a versão instalada."
    else
        log "Instalando LXD via snap (${LXD_SNAP_NAME})..."
        snap install "${LXD_SNAP_NAME}" || error_exit "Falha ao instalar o LXD snap."
        log "LXD snap instalado com sucesso."
    fi
}

# Adiciona o usuário que invocou sudo ao grupo lxd
add_user_to_group() {
    local target_user="${SUDO_USER:-}"

    if [[ -z "${target_user}" ]]; then
        target_user=$(logname 2>/dev/null || whoami)
        if [[ "${target_user}" == "root" ]]; then
            warn "Não foi possível determinar o usuário não-root para adicionar ao grupo '${LXD_GROUP}' (SUDO_USER não definido)."
            info "Adicione manualmente o usuário desejado: sudo usermod -aG ${LXD_GROUP} <username>"
            return
        fi
        warn "Variável SUDO_USER não encontrada. Tentando com o usuário '${target_user}'."
    fi

    info "Verificando se o usuário '${target_user}' está no grupo '${LXD_GROUP}'..."
    if groups "${target_user}" | grep -q "\b${LXD_GROUP}\b"; then
        log "Usuário '${target_user}' já pertence ao grupo '${LXD_GROUP}'."
    else
        log "Adicionando usuário '${target_user}' ao grupo '${LXD_GROUP}'..."
        usermod -aG "${LXD_GROUP}" "${target_user}" || error_exit "Falha ao adicionar '${target_user}' ao grupo '${LXD_GROUP}'."
        log "Usuário '${target_user}' adicionado. É necessário reiniciar a sessão ou usar 'newgrp ${LXD_GROUP}'."
    fi
}

# Espera o daemon LXD ficar pronto
wait_lxd_ready() {
    info "Aguardando o daemon LXD ficar pronto (timeout: ${WAIT_TIMEOUT}s)..."

    export PATH=$PATH:/snap/bin

    if lxd waitready --timeout="${WAIT_TIMEOUT}"; then
        log "Daemon LXD está pronto."
    else
        error_exit "LXD daemon não ficou pronto dentro do tempo limite (${WAIT_TIMEOUT}s)."
    fi
}

# Verifica se o LXD já foi inicializado (heurística)
is_lxd_initialized() {
    if lxd storage list --format=json | grep -q "\"name\":\"${DEFAULT_STORAGE_POOL}\"" &&
        lxd network list --format=json | grep -q "\"name\":\"${DEFAULT_NETWORK}\""; then
        return 0
    else
        return 1
    fi
}

# Inicializa o LXD usando preseed se ainda não foi inicializado
initialize_lxd() {
    info "Verificando se o LXD já foi inicializado..."
    if is_lxd_initialized; then
        log "LXD parece já estar inicializado (pool '${DEFAULT_STORAGE_POOL}' e rede '${DEFAULT_NETWORK}' encontrados)."
    else
        warn "LXD não parece estar inicializado. Executando 'lxd init --preseed'..."
        local lxd_preseed_config
        read -r -d '' lxd_preseed_config <<EOF || true
config:
  # Define um intervalo razoável para atualização automática de imagens
  images.auto_update_interval: 60
  core.https_address: 192.168.0.215:9999
networks:
  # Configura a bridge padrão lxdbr0
- name: ${DEFAULT_NETWORK}
  type: bridge
  config:
    ipv4.address: 10.0.0.1/24 # Rede privada padrão
    ipv4.nat: true           # Habilita NAT para acesso à internet
    ipv4.dhcp: true          # Habilita servidor DHCP na bridge
    ipv4.dhcp.ranges: 10.0.0.2-10.0.0.254 # Faixa de IPs para containers
    ipv6.address: none       # Desabilita IPv6 por padrão (pode ser habilitado se necessário)
storage_pools:
  # Configura o pool de armazenamento padrão usando diretório
- name: ${DEFAULT_STORAGE_POOL}
  driver: dir # Simples e funciona em qualquer lugar, mas BTRFS/ZFS são melhores se disponíveis
profiles:
  # Configura o perfil padrão para usar a rede e o pool criados
- name: default
  config: {}
  description: Default LXD profile
  devices:
    root: # Dispositivo de disco raiz
      path: /
      pool: ${DEFAULT_STORAGE_POOL}
      type: disk
    eth0: # Dispositivo de rede padrão
      name: eth0
      network: ${DEFAULT_NETWORK}
      type: nic
# Desabilita clustering por padrão para configuração single-node
cluster: null
EOF
        echo "${lxd_preseed_config}" | lxd init --preseed || error_exit "Falha ao executar 'lxd init --preseed'."
        log "LXD inicializado com sucesso usando configuração preseed."
    fi
}

# === Função Principal ===
main() {
    check_root
    check_and_install_deps
    install_or_refresh_lxd
    add_user_to_group
    wait_lxd_ready
    initialize_lxd

    echo ""
    log "Instalação e configuração básica do LXD concluídas!"
    info "Para que as permissões do grupo '${LXD_GROUP}' tenham efeito para o usuário adicionado,"
    info "é necessário ${YELLOW}fazer logout e login novamente${RESET} ou executar o comando:"
    info "  ${YELLOW}newgrp ${LXD_GROUP}${RESET} (aplica apenas ao shell atual)"
    echo ""
    info "Você pode começar a usar o LXD com comandos como:"
    info "  lxc launch ubuntu:22.04 meu-primeiro-container"
    info "  lxc list"
    info "  lxc exec meu-primeiro-container -- bash"
    info "  lxc stop meu-primeiro-container"
    info "  lxc delete meu-primeiro-container"
}

# === Execução ===
main "$@"

exit 0
