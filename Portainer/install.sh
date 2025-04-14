#!/usr/bin/env bash

# === Configuração de Segurança e Robustez ===
set -euo pipefail

# === Constantes ===
readonly PORTAINER_IMAGE="portainer/portainer-ce:latest"
readonly PORTAINER_NAME="portainer"
readonly PORTAINER_VOLUME="portainer_data"
readonly DEFAULT_IP_ADDRESS="0.0.0.0"

# === Cores para Terminal ===
GREEN="\033[1;32m"
RED="\033[1;31m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
NC="\033[0m" # No Color

# === Funções de Log ===
log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; } # Avisos vão para stderr
error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
  exit 1
} # Erros vão para stderr
info() { echo -e "${BLUE}[NOTE]${NC} $1"; }

# === Funções Auxiliares ===

# Exibe mensagem de ajuda
usage() {
  echo "Instala ou atualiza o Portainer CE via Docker."
  echo ""
  echo -e "${YELLOW}Uso:${NC} $0 [opções]"
  echo ""
  echo -e "${BLUE}Opções:${NC}"
  echo "  --ip=<IP_ADDRESS>   Endereço IP para expor as portas do Portainer (padrão: ${DEFAULT_IP_ADDRESS})."
  echo "                      Use 127.0.0.1 para acesso apenas local."
  echo "  -h, --help          Mostra esta mensagem de ajuda."
  exit 0
}

# Verifica privilégios de root
check_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    error "Este script precisa ser executado como root (ou com sudo)."
  fi
}

# Verifica se o Docker está instalado e rodando
check_docker() {
  if ! command -v docker &>/dev/null; then
    error "Comando 'docker' não encontrado. Instale o Docker Engine primeiro: https://docs.docker.com/engine/install/"
  fi
  if ! docker info >/dev/null 2>&1; then
    error "Não foi possível conectar ao daemon do Docker. O Docker está rodando?"
  fi
  log "Docker encontrado e respondendo."
}

# Valida formato de IP v4
validate_ipv4() {
  local ip="${1}"
  local ip_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
  if ! [[ "${ip}" =~ ${ip_regex} ]]; then
    error "Formato de endereço IP inválido: ${ip}. Use o formato X.X.X.X."
  fi
  local IFS='.'
  read -ra octets <<<"${ip}"
  for octet in "${octets[@]}"; do
    if ! [[ "${octet}" =~ ^[0-9]+$ ]] || ((octet < 0 || octet > 255)); then
      error "Endereço IP inválido: ${ip}. Octeto '${octet}' fora do intervalo 0-255."
    fi
  done
  IFS=' ' # Restaura IFS
}

# Função de limpeza em caso de interrupção (Ctrl+C)
# Tenta remover o container *se* ele foi criado por este script (ou já existia e foi parado)
cleanup_on_interrupt() {
  warn "Script interrompido. Tentando limpar o container ${PORTAINER_NAME}..."
  # Verifica se o container existe antes de tentar remover
  if docker ps -a --filter "name=^/${PORTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${PORTAINER_NAME}$"; then
    log "Removendo container ${PORTAINER_NAME} devido à interrupção..."
    docker rm -f "${PORTAINER_NAME}" >/dev/null || warn "Não foi possível remover o container ${PORTAINER_NAME} na limpeza."
  else
    info "Container ${PORTAINER_NAME} não encontrado para remoção na limpeza."
  fi
  # Nota: Não removemos o volume em interrupções para evitar perda de dados acidental.
  exit 1 # Sai com status de erro após interrupção
}

# === Configuração Inicial ===
IP_ADDRESS="${DEFAULT_IP_ADDRESS}" # Define o padrão

# Processar argumentos da linha de comando
while [[ $# -gt 0 ]]; do
  case "$1" in
  --ip=*)
    IP_ADDRESS="${1#*=}"
    shift
    ;;
  --help | -h)
    usage
    ;;
  *)
    # Ignora opções desconhecidas ou passa para o help? Vamos ser estritos.
    error "Opção inválida: $1. Use -h ou --help para ver as opções válidas."
    ;;
  esac
done

# === Validações ===
check_root
check_docker
validate_ipv4 "${IP_ADDRESS}"

# === Configurar Trap para Interrupções ===
# Usamos um trap mais específico para SIGINT/SIGTERM
trap cleanup_on_interrupt SIGINT SIGTERM
# set -e cuidará da saída em erro (sem trap ERR)

# === Processo de Instalação/Atualização ===

info "Configuração:"
info "  - Imagem:      ${PORTAINER_IMAGE}"
info "  - Nome Cont.: ${PORTAINER_NAME}"
info "  - Volume:      ${PORTAINER_VOLUME}"
info "  - IP Bind:     ${IP_ADDRESS}"
info "  - Portas:      ${IP_ADDRESS}:8000 -> 8000 | ${IP_ADDRESS}:9443 -> 9443"

# 1. Verificar/Parar/Remover Container Existente (Idempotência/Atualização)
if docker ps -a --filter "name=^/${PORTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${PORTAINER_NAME}$"; then
  warn "Container ${PORTAINER_NAME} já existe."
  log "Parando o container ${PORTAINER_NAME} para atualização/recriação..."
  docker stop "${PORTAINER_NAME}" >/dev/null || warn "Não foi possível parar o container (pode já estar parado)."
  log "Removendo o container ${PORTAINER_NAME}..."
  docker rm "${PORTAINER_NAME}" >/dev/null || error "Falha ao remover o container existente ${PORTAINER_NAME}."
  log "Container existente removido."
else
  log "Nenhum container ${PORTAINER_NAME} existente encontrado."
fi

# 2. Criar Volume (se não existir)
if ! docker volume ls --filter "name=^${PORTAINER_VOLUME}$" --format '{{.Name}}' | grep -q "^${PORTAINER_VOLUME}$"; then
  log "Criando volume Docker '${PORTAINER_VOLUME}'..."
  docker volume create "${PORTAINER_VOLUME}" || error "Falha ao criar o volume ${PORTAINER_VOLUME}."
  log "Volume ${PORTAINER_VOLUME} criado."
else
  log "Volume ${PORTAINER_VOLUME} já existe."
fi

# 3. Baixar/Atualizar Imagem
log "Baixando/Atualizando a imagem Portainer CE (${PORTAINER_IMAGE})..."
# Removemos >/dev/null para mostrar o progresso do pull
docker pull "${PORTAINER_IMAGE}" || error "Falha ao baixar a imagem ${PORTAINER_IMAGE}."
log "Imagem ${PORTAINER_IMAGE} baixada/atualizada com sucesso."

# 4. Iniciar Novo Container
log "Iniciando novo container Portainer (${PORTAINER_NAME})..."
# Removemos >/dev/null para ver o ID do container ou erros
container_id=$(docker run -d \
  -p "${IP_ADDRESS}:8000:8000" \
  -p "${IP_ADDRESS}:9443:9443" \
  --name "${PORTAINER_NAME}" \
  --restart=unless-stopped \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${PORTAINER_VOLUME}:/data" \
  "${PORTAINER_IMAGE}")

# Verificar se o comando docker run falhou (retorna $? != 0)
# set -e já cuidaria disso, mas uma verificação explícita é mais clara
if [[ $? -ne 0 ]]; then
  # Rollback específico para falha no run: tenta remover o container recém-criado se ele chegou a ser criado
  error "Falha ao iniciar o container Portainer. Verifique as mensagens de erro do Docker acima. Pode haver conflito de portas ou problemas com o docker.sock."
  # O trap não será mais chamado aqui porque saímos com error()
fi

log "Container ${PORTAINER_NAME} iniciado com ID: ${container_id:0:12}" # Mostra ID curto

# 5. Verificar Status do Container (Pequena espera pode ser necessária)
info "Aguardando o container iniciar completamente..."
sleep 5 # Pequena pausa para dar tempo ao container de iniciar

if ! docker ps --filter "name=^/${PORTAINER_NAME}$" --filter "status=running" --format '{{.Names}}' | grep -q "^${PORTAINER_NAME}$"; then
  # Se falhar, mostrar logs pode ajudar no diagnóstico
  warn "Container ${PORTAINER_NAME} não está no estado 'running'. Verificando logs..."
  docker logs "${PORTAINER_NAME}" || warn "Não foi possível obter logs do container ${PORTAINER_NAME}."
  error "Falha ao verificar o status 'running' do container ${PORTAINER_NAME}."
fi

log "Container ${PORTAINER_NAME} está em execução."

# 6. Informações Finais
echo ""
log "Portainer CE instalado/atualizado com sucesso!"
info "Acesso Web (pode levar um momento para estar totalmente pronto):"
echo -e "  - ${YELLOW}HTTPS (Recomendado):${NC} https://${IP_ADDRESS}:9443"
echo -e "  - HTTP:              http://${IP_ADDRESS}:8000"
echo ""
info "${YELLOW}Importante:${NC}"
info "  - Na primeira vez, você precisará criar um usuário administrador."
info "  - Certifique-se de que as portas 8000 e 9443 (TCP) estejam abertas no seu firewall para o IP ${IP_ADDRESS}."
echo ""
info "Comandos Úteis:"
echo -e "  - Ver logs:   ${BLUE}docker logs ${PORTAINER_NAME}${NC}"
echo -e "  - Parar:      ${BLUE}docker stop ${PORTAINER_NAME}${NC}"
echo -e "  - Iniciar:    ${BLUE}docker start ${PORTAINER_NAME}${NC}"
echo -e "  - Reiniciar:  ${BLUE}docker restart ${PORTAINER_NAME}${NC}"
echo -e "  - Remover:    ${BLUE}sudo $0 --ip=${IP_ADDRESS} # (executar de novo para parar/remover container); então docker volume rm ${PORTAINER_VOLUME}${NC}"
info "Documentação Oficial: https://docs.portainer.io/"

# Desativar o trap se tudo correu bem para evitar limpeza acidental
trap - SIGINT SIGTERM EXIT

exit 0
