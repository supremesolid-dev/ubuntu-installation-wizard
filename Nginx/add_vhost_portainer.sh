#!/usr/bin/env bash

# === Configuração de Segurança e Robustez ===
set -euo pipefail

# === Constantes ===
readonly NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
readonly NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
readonly NGINX_LOG_DIR="/var/log/nginx"

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

# Exibe mensagem de ajuda
usage() {
  echo -e "${YELLOW}Uso:${RESET} $0 --vhost-server-ip=<IP> --vhost-server-port=<PORTA> --vhost-server-domain=<DOMAIN> --vhost-proxy-target=<TARGET> [--vhost-proxy-ssl=<yes|no>]"
  echo ""
  echo -e "${BLUE}Opções:${RESET}"
  echo "  --vhost-server-ip=<IP>         Endereço IP para o Nginx escutar (ex: 192.168.1.100, 0.0.0.0)."
  echo "  --vhost-server-port=<PORTA>    Porta para o Nginx escutar (ex: 80, 443)."
  echo "  --vhost-server-domain=<DOMAIN> Nome do domínio ou subdomínio (ex: portainer.meudominio.com)."
  echo "  --vhost-proxy-target=<TARGET>  Alvo do proxy reverso (ex: 127.0.0.1:9000, meuapp.local:8080, unix:/path/to/socket.sock)."
  echo "  --vhost-proxy-ssl=<yes|no>     O alvo do proxy usa HTTPS? (Padrão: no). Importante para o protocolo em 'proxy_pass'."
  echo "  -h, --help                     Exibe esta mensagem de ajuda."
  exit 0
}

# Valida formato de IP v4
validate_ipv4() {
  local ip="${1}"
  local ip_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
  if ! [[ "${ip}" =~ ${ip_regex} ]]; then
    error_exit "Formato de endereço IP inválido: ${ip}. Use o formato X.X.X.X."
  fi
  local IFS='.'
  read -ra octets <<<"${ip}"
  for octet in "${octets[@]}"; do
    if ! [[ "${octet}" =~ ^[0-9]+$ ]] || ((octet < 0 || octet > 255)); then
      error_exit "Endereço IP inválido: ${ip}. Octeto '${octet}' fora do intervalo 0-255."
    fi
  done
  IFS=' '
}

# Valida formato da porta
validate_port() {
  local port="${1}"
  if ! [[ "${port}" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
    error_exit "Porta inválida: ${port}. Use um número entre 1 e 65535."
  fi
}

# Valida formato do domínio (básico)
validate_domain() {
  local domain="${1}"
  local domain_regex='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$'
  if ! [[ "${domain}" =~ ${domain_regex} ]]; then
    error_exit "Formato de domínio inválido: ${domain}"
  fi
}

# Valida formato do alvo do proxy (básico)
validate_proxy_target() {
  local target="${1}"
  # Aceita host:port, IP:port, unix:/path/to/socket ou apenas host/IP (assumindo porta padrão)
  # Esta validação é simples, Nginx fará a validação final.
  if [[ -z "$target" ]]; then
    error_exit "Alvo do proxy (--vhost-proxy-target) não pode ser vazio."
  fi
  # Poderia adicionar regex mais complexo se necessário, mas pode ser excessivo.
}

# Valida opção SSL
validate_proxy_ssl() {
  local ssl_option="${1}"
  case "$(echo "$ssl_option" | tr '[:upper:]' '[:lower:]')" in
  yes | no) return 0 ;; # Válido
  *) error_exit "Valor inválido para --vhost-proxy-ssl: '${ssl_option}'. Use 'yes' ou 'no'." ;;
  esac
}

# === Verificação Inicial ===
check_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    error_exit "Este script precisa ser executado como root (ou com sudo)."
  fi
}

check_nginx_installed() {
  if ! command -v nginx &>/dev/null; then
    error_exit "Comando 'nginx' não encontrado. O Nginx está instalado e no PATH?"
  fi
}

# === Processamento dos Argumentos ===
VHOST_SERVER_IP=""
VHOST_SERVER_PORT=""
VHOST_SERVER_DOMAIN=""
VHOST_PROXY_TARGET=""
VHOST_PROXY_SSL="no" # Valor padrão

# Se nenhum argumento for passado, exibe ajuda
if [[ $# -eq 0 ]]; then
  usage
fi

while [[ $# -gt 0 ]]; do
  case "${1}" in
  --vhost-server-ip=*)
    VHOST_SERVER_IP="${1#*=}"
    shift
    ;;
  --vhost-server-port=*)
    VHOST_SERVER_PORT="${1#*=}"
    shift
    ;;
  --vhost-server-domain=*)
    VHOST_SERVER_DOMAIN="${1#*=}"
    shift
    ;;
  --vhost-proxy-target=*)
    VHOST_PROXY_TARGET="${1#*=}"
    shift
    ;;
  --vhost-proxy-ssl=*)
    VHOST_PROXY_SSL="${1#*=}"
    shift
    ;;
  --help | -h)
    usage
    ;;
  *)
    error_exit "Argumento desconhecido: ${1}"
    ;;
  esac
done

# === Validação dos Parâmetros ===
info "Validando parâmetros..."
if [[ -z "${VHOST_SERVER_IP}" || -z "${VHOST_SERVER_PORT}" || -z "${VHOST_SERVER_DOMAIN}" || -z "${VHOST_PROXY_TARGET}" ]]; then
  error_exit "Os parâmetros --vhost-server-ip, --vhost-server-port, --vhost-server-domain, e --vhost-proxy-target são obrigatórios."
fi

validate_ipv4 "${VHOST_SERVER_IP}"
validate_port "${VHOST_SERVER_PORT}"
validate_domain "${VHOST_SERVER_DOMAIN}"
validate_proxy_target "${VHOST_PROXY_TARGET}"
validate_proxy_ssl "${VHOST_PROXY_SSL}"
log "Parâmetros validados com sucesso."

# Determina o protocolo para o proxy_pass
PROXY_PROTOCOL="http"
if [[ "$(echo "$VHOST_PROXY_SSL" | tr '[:upper:]' '[:lower:]')" == "yes" ]]; then
  PROXY_PROTOCOL="https"
fi

# === Lógica Principal ===
main() {
  check_root
  check_nginx_installed

  local vhost_file_name="${VHOST_SERVER_DOMAIN}.conf" # Adiciona .conf
  local vhost_file_path="${NGINX_SITES_AVAILABLE}/${vhost_file_name}"
  local vhost_symlink_path="${NGINX_SITES_ENABLED}/${vhost_file_name}"

  info "Verificando se o arquivo de configuração já existe: ${vhost_file_path}"
  if [[ -f "${vhost_file_path}" ]]; then
    warn "Arquivo de configuração ${vhost_file_path} já existe. Ele será sobrescrito."
    # Backup poderia ser adicionado aqui: cp "${vhost_file_path}" "${vhost_file_path}.bak_$(date +%F_%T)"
  fi

  log "Criando arquivo de configuração Nginx para ${VHOST_SERVER_DOMAIN} (Proxy Reverso)..."

  # Cria o diretório de logs Nginx se não existir
  mkdir -p "${NGINX_LOG_DIR}" || error_exit "Falha ao criar diretório de logs: ${NGINX_LOG_DIR}"

  # Heredoc para criar o arquivo de configuração
  cat >"${vhost_file_path}" <<EOF || error_exit "Falha ao escrever no arquivo de configuração ${vhost_file_path}"
# Configuração de Proxy Reverso para ${VHOST_SERVER_DOMAIN}
# Gerado por script em $(date)
# Alvo do Proxy: ${PROXY_PROTOCOL}://${VHOST_PROXY_TARGET}

server {
    listen ${VHOST_SERVER_IP}:${VHOST_SERVER_PORT};
    server_name ${VHOST_SERVER_DOMAIN};

    # Logs específicos
    access_log ${NGINX_LOG_DIR}/${VHOST_SERVER_DOMAIN}.access.log;
    error_log ${NGINX_LOG_DIR}/${VHOST_SERVER_DOMAIN}.error.log warn; # Nível 'warn' pode ser útil para proxy

    # Aumentar o tamanho máximo do corpo da solicitação, se necessário (ex: uploads via Portainer)
    client_max_body_size 100m;

    # --- Bloco Principal do Proxy Reverso ---
    location / {
        # Define o alvo do proxy
        proxy_pass ${PROXY_PROTOCOL}://${VHOST_PROXY_TARGET};

        # --- Cabeçalhos Essenciais para o Backend ---
        # Preserva o Host original solicitado pelo cliente
        proxy_set_header Host \$host;
        # Passa o IP real do cliente
        proxy_set_header X-Real-IP \$remote_addr;
        # Adiciona IPs de proxies intermediários (incluindo este Nginx)
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        # Informa o protocolo original (http ou https) usado pelo cliente
        proxy_set_header X-Forwarded-Proto \$scheme;

        # --- Configurações de Timeout (ajuste conforme necessário) ---
        proxy_connect_timeout 60s;
        proxy_send_timeout    60s;
        proxy_read_timeout    60s;
        send_timeout          60s;

        # --- Suporte a WebSocket (Necessário para Portainer e muitos apps modernos) ---
        proxy_http_version 1.1; # Necessário para WebSocket
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # --- Segurança (Opcional, mas recomendado) ---
        # Impede que o site seja embutido em iframes de outros domínios
        add_header X-Frame-Options SAMEORIGIN always;
        # Proteção contra XSS
        add_header X-Content-Type-Options nosniff always;
        # HSTS (somente se você estiver usando HTTPS neste vhost Nginx - requer configuração adicional)
        # add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

        # --- Tratamento de SSL para o Backend (se --vhost-proxy-ssl=yes) ---
        # Nota: Para backends com certificados auto-assinados, você pode precisar descomentar
        # proxy_ssl_verify off;
        # ou configurar 'proxy_ssl_trusted_certificate'.
        # Para certificados válidos, Nginx verificará por padrão.
        # proxy_ssl_server_name on; # Geralmente necessário se o backend usa SNI
    }

    # Opcional: Localização para verificações de saúde (se aplicável)
    # location /health {
    #   access_log off;
    #   return 200 "OK";
    #   add_header Content-Type text/plain;
    # }
}
EOF

  log "Arquivo ${vhost_file_path} criado."

  info "Ativando o site (criando link simbólico)..."
  ln -sf "${vhost_file_path}" "${vhost_symlink_path}" || error_exit "Falha ao criar link simbólico em ${NGINX_SITES_ENABLED}."
  log "Site ${VHOST_SERVER_DOMAIN} ativado."

  info "Testando configuração do Nginx..."
  if nginx -t; then
    log "Configuração do Nginx OK."
    info "Recarregando configuração do Nginx..."
    if systemctl reload nginx; then
      log "Nginx recarregado com sucesso."
    else
      error_exit "Falha ao recarregar o Nginx (systemctl reload nginx)."
    fi
  else
    error_exit "Teste de configuração do Nginx falhou. Verifique os erros acima."
  fi

  echo ""
  log "VirtualHost (Proxy Reverso) para ${VHOST_SERVER_DOMAIN} configurado com sucesso!"
  info "Detalhes:"
  info "  - Escutando em: ${VHOST_SERVER_IP}:${VHOST_SERVER_PORT}"
  info "  - Domínio: ${VHOST_SERVER_DOMAIN}"
  info "  - Alvo do Proxy: ${PROXY_PROTOCOL}://${VHOST_PROXY_TARGET}"
  info "  - Arquivo Conf: ${vhost_file_path}"
  info "  - Link Ativo: ${vhost_symlink_path}"
  info "  - Logs: ${NGINX_LOG_DIR}/${VHOST_SERVER_DOMAIN}.*"

  # Tenta determinar um protocolo http/https para a mensagem final de acesso ao Nginx
  local access_protocol="http"
  if [[ "${VHOST_SERVER_PORT}" == "443" ]]; then
    access_protocol="https"
    # Nota: Este script não configura o lado SSL do Nginx (certificados, etc.).
    # A porta 443 aqui é apenas um palpite para a URL de acesso.
    info "${YELLOW}AVISO:${RESET} A porta ${VHOST_SERVER_PORT} foi detectada, mas este script NÃO configurou SSL para o Nginx. Configuração SSL adicional é necessária."
  fi

  local access_url="${access_protocol}://${VHOST_SERVER_DOMAIN}"
  if [[ "${VHOST_SERVER_PORT}" != "80" && "${VHOST_SERVER_PORT}" != "443" ]]; then
    access_url+=":${VHOST_SERVER_PORT}"
  fi
  info "${YELLOW}Acesse o serviço através do Nginx (após configurar DNS/hosts se necessário):${RESET} ${access_url}"

}

# === Execução ===
main "$@"

exit 0
