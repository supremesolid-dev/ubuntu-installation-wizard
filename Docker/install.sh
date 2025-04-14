#!/bin/bash
set -euo pipefail

# Cores para mensagens
GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
NC="\033[0m"

# Funções de log
log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}
info() { echo -e "${BLUE}[NOTE]${NC} $1"; }

# Verificação de root
if [ "$EUID" -ne 0 ]; then
    error "Execute como root: sudo $0"
fi

# Verificação de sistema
if ! command -v apt-get &>/dev/null; then
    error "Sistema não suportado (apenas apt-get)"
fi

# 1. Parar e mascarar serviços Docker existentes
if systemctl is-active --quiet docker; then
    log "Parando serviços Docker existentes..."
    systemctl stop docker docker.socket containerd
fi

log "Mascarando serviços temporariamente..."
systemctl mask docker docker.socket containerd >/dev/null 2>&1 || warn "Não foi possível mascarar serviços (pode ser primeira instalação)"

# 2. Instalação básica
log "Atualizando pacotes..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -q

log "Instalando dependências..."
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg

# 3. Repositório Docker
log "Configurando repositório Docker..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null

apt-get update -q

# 4. Instalação controlada
log "Instalando pacotes Docker (sem iniciar serviço)..."

# Instala com política de não iniciar automaticamente
cat >/usr/sbin/policy-rc.d <<'EOL'
#!/bin/sh
exit 101
EOL
chmod +x /usr/sbin/policy-rc.d

apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# Remove a política após instalação
rm -f /usr/sbin/policy-rc.d

# 5. Configuração do daemon
log "Configurando daemon.json..."
mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<'EOL'
{
  "iptables": false,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOL

# 6. Remover máscara e habilitar serviços
log "Configurando serviços..."
systemctl unmask docker docker.socket containerd >/dev/null 2>&1
systemctl enable --now docker containerd

# 7. Adicionar usuário atual ao grupo docker (automático)
CURRENT_USER=${SUDO_USER:-$(logname 2>/dev/null || echo "${USER}")}
if [ -n "${CURRENT_USER}" ] && [ "${CURRENT_USER}" != "root" ]; then
    if ! grep -q docker /etc/group; then
        groupadd docker
    fi
    usermod -aG docker "${CURRENT_USER}" >/dev/null 2>&1 &&
        info "Usuário ${CURRENT_USER} adicionado ao grupo docker"
fi

# 8. Verificação final
if docker --version &>/dev/null; then
    log "Instalação concluída!"
    info "Versão: $(docker --version | awk '{print $3}' | tr -d ',')"
    info "Status: $(systemctl is-active docker)"
    info "Config iptables: $(docker info 2>/dev/null | grep -i 'iptables' || echo 'desativado')"
else
    error "Falha na verificação final do Docker"
fi
