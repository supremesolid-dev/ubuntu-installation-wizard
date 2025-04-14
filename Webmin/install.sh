#!/bin/bash
set -euo pipefail

# Cores para mensagens
GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
NC="\033[0m"

# Funções de log
log()   { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
info()  { echo -e "${BLUE}[NOTE]${NC} $1"; }

# Verificação de root
if [ "$EUID" -ne 0 ]; then
    error "Este script deve ser executado como root. Use: sudo $0"
fi

# Verificação de sistema
if ! command -v apt-get &> /dev/null; then
    error "Este script é apenas para sistemas baseados em Debian/Ubuntu"
fi

# Atualizar pacotes
log "Atualizando lista de pacotes..."
apt-get update -q || error "Falha ao atualizar os repositórios"

# Instalar dependências
log "Instalando dependências..."
apt-get install -y --no-install-recommends \
    curl \
    gnupg2 \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
    lsb-release || error "Falha ao instalar dependências"

# Adicionar repositório do Webmin
log "Configurando repositório do Webmin..."
bash <(curl -fsSL https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh) || error "Falha ao configurar o repositório"

# Instalar Webmin
log "Instalando Webmin..."
apt-get install -y webmin --install-recommends || error "Falha ao instalar o Webmin"

# Configuração pós-instalação
WEBMIN_PORT=$(grep "^port=" /etc/webmin/miniserv.conf | cut -d= -f2)
WEBMIN_SSL=$(grep "^ssl=" /etc/webmin/miniserv.conf | cut -d= -f2)

if [ "$WEBMIN_SSL" -eq 1 ]; then
    PROTO="https"
else
    PROTO="http"
    warn "Webmin está configurado sem SSL (não recomendado para produção)"
fi

# Verificar status
if systemctl is-active --quiet webmin; then
    log "Webmin instalado com sucesso!"
    info "Acesse em: ${PROTO}://$(hostname -I | awk '{print $1}'):${WEBMIN_PORT}"
    info "Use suas credenciais de root do sistema para fazer login"
else
    warn "Webmin instalado mas o serviço não está rodando"
    info "Tente iniciar manualmente: systemctl start webmin"
fi

