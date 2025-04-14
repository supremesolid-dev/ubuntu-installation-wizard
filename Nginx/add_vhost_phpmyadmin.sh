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
warn() { echo -e "${YELLOW}[⚠]${RESET} $1"; }
error_exit() {
  echo -e "${RED}[✖]${RESET} $1"
  exit 1
}
info() { echo -e "${BLUE}[ℹ]${RESET} $1"; }

# === Funções Auxiliares ===

# Exibe mensagem de ajuda
usage() {
  echo -e "${YELLOW}Uso:${RESET} $0 --vhost-server-ip=<IP> --vhost-server-port=<PORTA> --vhost-server-domain=<DOMAIN> --vhost-server-path=<PATH> --vhost-php-version=<VERSION>"
  echo ""
  echo -e "${BLUE}Opções:${RESET}"
  echo "  --vhost-server-ip=<IP>         Endereço IP para o Nginx escutar (ex: 192.168.1.100, 0.0.0.0)."
  echo "  --vhost-server-port=<PORTA>    Porta para o Nginx escutar (ex: 80, 8080)."
  echo "  --vhost-server-domain=<DOMAIN> Nome do domínio ou subdomínio (ex: meudominio.com, pma.local)."
  echo "  --vhost-server-path=<PATH>     Caminho absoluto para o diretório raiz do site (ex: /var/www/phpmyadmin)."
  echo "  --vhost-php-version=<VERSION>  Versão do PHP-FPM a ser usada (ex: 8.1, 8.2)."
  echo "  -h, --help                     Exibe esta mensagem de ajuda."
  exit 0 # Sair normalmente após ajuda
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
  IFS=' ' # Restaura IFS
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
  # Permite letras, números, hífens e pontos. Não valida estritamente TLDs ou posição de hífens/pontos.
  local domain_regex='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$'
  if ! [[ "${domain}" =~ ${domain_regex} ]]; then
    error_exit "Formato de domínio inválido: ${domain}"
  fi
}

# Verifica se o diretório existe
validate_path() {
  local path="${1}"
  if [[ ! -d "${path}" ]]; then
    error_exit "Diretório raiz não encontrado ou não é um diretório: ${path}"
  fi
  # Poderia adicionar verificação de permissões de leitura para www-data aqui se necessário
}

# Valida formato da versão PHP e existência do socket FPM
validate_php() {
  local version="${1}"
  local php_regex='^[0-9]+\.[0-9]+$'
  if ! [[ "${version}" =~ ${php_regex} ]]; then
    error_exit "Formato da versão PHP inválido: ${version}. Use X.Y (ex: 8.1)."
  fi

  local fpm_sock="/run/php/php${version}-fpm.sock"
  if [[ ! -S "${fpm_sock}" ]]; then
    error_exit "Socket PHP-FPM não encontrado para a versão ${version} em: ${fpm_sock}. Verifique se o serviço PHP-FPM está instalado e rodando."
  fi
  # Retorna o caminho do socket validado para uso posterior
  PHP_FPM_SOCK_VALIDATED="${fpm_sock}"
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
VHOST_SERVER_PATH=""
VHOST_PHP_VERSION=""

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
  --vhost-server-path=*)
    VHOST_SERVER_PATH="${1#*=}"
    shift
    ;;
  --vhost-php-version=*)
    VHOST_PHP_VERSION="${1#*=}"
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
if [[ -z "${VHOST_SERVER_IP}" || -z "${VHOST_SERVER_PORT}" || -z "${VHOST_SERVER_DOMAIN}" || -z "${VHOST_SERVER_PATH}" || -z "${VHOST_PHP_VERSION}" ]]; then
  error_exit "Todos os parâmetros (--vhost-server-ip, --vhost-server-port, --vhost-server-domain, --vhost-server-path, --vhost-php-version) são obrigatórios."
fi

validate_ipv4 "${VHOST_SERVER_IP}"
validate_port "${VHOST_SERVER_PORT}"
validate_domain "${VHOST_SERVER_DOMAIN}"
validate_path "${VHOST_SERVER_PATH}"
validate_php "${VHOST_PHP_VERSION}" # Define PHP_FPM_SOCK_VALIDATED se válido
log "Parâmetros validados com sucesso."

# === Lógica Principal ===
main() {
  check_root
  check_nginx_installed

  local vhost_file_name="${VHOST_SERVER_DOMAIN}.conf" # Adiciona .conf para clareza
  local vhost_file_path="${NGINX_SITES_AVAILABLE}/${vhost_file_name}"
  local vhost_symlink_path="${NGINX_SITES_ENABLED}/${vhost_file_name}"

  info "Verificando se o arquivo de configuração já existe: ${vhost_file_path}"
  if [[ -f "${vhost_file_path}" ]]; then
    warn "Arquivo de configuração ${vhost_file_path} já existe. Ele será sobrescrito."
    # Poderia adicionar uma opção --force ou perguntar ao usuário aqui
  fi

  log "Criando arquivo de configuração Nginx para ${VHOST_SERVER_DOMAIN}..."

  # Cria o diretório de logs Nginx se não existir
  mkdir -p "${NGINX_LOG_DIR}" || error_exit "Falha ao criar diretório de logs: ${NGINX_LOG_DIR}"

  # Heredoc para criar o arquivo de configuração
  cat >"${vhost_file_path}" <<EOF || error_exit "Falha ao escrever no arquivo de configuração ${vhost_file_path}"
# Configuração para ${VHOST_SERVER_DOMAIN}
# Gerado por script em $(date)

server {
    listen ${VHOST_SERVER_IP}:${VHOST_SERVER_PORT};
    server_name ${VHOST_SERVER_DOMAIN};

    root ${VHOST_SERVER_PATH};
    index index.php index.html index.htm;

    charset utf-8;

    # Logs específicos para este vhost
    access_log ${NGINX_LOG_DIR}/${VHOST_SERVER_DOMAIN}.access.log;
    error_log ${NGINX_LOG_DIR}/${VHOST_SERVER_DOMAIN}.error.log;

    # Roteamento padrão e tratamento de arquivos não encontrados
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string; # Comum para frameworks/CMS
        # Se for apenas arquivos estáticos + PHP: try_files \$uri \$uri/ =404;
    }

    # Negar acesso a arquivos ocultos (ex: .htaccess, .git)
    location ~ /\. {
        deny all;
    }

    # Processamento de arquivos PHP via FPM
    location ~ \.php$ {
        include snippets/fastcgi-php.conf; # Snippet padrão do Ubuntu com boas práticas
        fastcgi_pass unix:${PHP_FPM_SOCK_VALIDATED};
        # fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name; # Geralmente já incluído no fastcgi-php.conf ou fastcgi_params
        include fastcgi_params; # Inclui parâmetros CGI básicos
    }

    # Cache para arquivos estáticos
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot|otf)$ {
        expires 1M; # Cache de 1 mês
        access_log off; # Opcional: desliga log para estáticos
        add_header Cache-Control "public";
    }
}
EOF

  log "Arquivo ${vhost_file_path} criado."

  info "Ativando o site (criando link simbólico)..."
  # Usar -sf para forçar a criação/substituição do link
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
    # nginx -t já imprime os erros detalhados no stderr
    error_exit "Teste de configuração do Nginx falhou. Verifique os erros acima."
  fi

  echo ""
  log "VirtualHost para ${VHOST_SERVER_DOMAIN} configurado com sucesso!"
  info "Detalhes:"
  info "  - Escutando em: ${VHOST_SERVER_IP}:${VHOST_SERVER_PORT}"
  info "  - Domínio: ${VHOST_SERVER_DOMAIN}"
  info "  - Raiz do Site: ${VHOST_SERVER_PATH}"
  info "  - PHP-FPM: ${PHP_FPM_SOCK_VALIDATED} (Versão ${VHOST_PHP_VERSION})"
  info "  - Arquivo Conf: ${vhost_file_path}"
  info "  - Link Ativo: ${vhost_symlink_path}"
  info "  - Logs: ${NGINX_LOG_DIR}/${VHOST_SERVER_DOMAIN}.*"

  # Tenta determinar um protocolo http/https para a mensagem final
  local access_protocol="http"
  if [[ "${VHOST_SERVER_PORT}" == "443" ]]; then
    access_protocol="https"
  fi
  # Nota: Este script não configura SSL. A porta 443 aqui é apenas um palpite.

  echo ""
  info "${YELLOW}Acesse o site (após configurar DNS/hosts se necessário):${RESET} ${access_protocol}://${VHOST_SERVER_DOMAIN}:${VHOST_SERVER_PORT}"
  # Adiciona a porta apenas se não for 80 (http) ou 443 (https)
  local access_url="${access_protocol}://${VHOST_SERVER_DOMAIN}"
  if [[ "${VHOST_SERVER_PORT}" != "80" && "${VHOST_SERVER_PORT}" != "443" ]]; then
    access_url+=":${VHOST_SERVER_PORT}"
  fi
  info "${YELLOW}Acesse o site (após configurar DNS/hosts se necessário):${RESET} ${access_url}"

}

# === Execução ===
main "$@"

exit 0
