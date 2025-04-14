#!/usr/bin/env bash

set -euo pipefail

VHOST_IP=""
VHOST_PORT=""
readonly NGINX_CONFIG_DIR="/etc/nginx"
readonly NGINX_SITES_AVAILABLE="${NGINX_CONFIG_DIR}/sites-available"
readonly NGINX_SITES_ENABLED="${NGINX_CONFIG_DIR}/sites-enabled"
readonly DEFAULT_VHOST_NAME="default"

error_exit() {
  echo "ERRO: ${1}" >&2
  exit 1
}

usage() {
  echo "Uso: ${0} --vhost-server-ip=<IP> --vhost-server-port=<PORTA>"
  echo
  echo "  Parâmetros Obrigatórios:"
  echo "    --vhost-server-ip=<IP>"
  echo "    --vhost-server-port=<PORTA>"
  exit 1
}

validate_ip() {
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

validate_port() {
  local port="${1}"
  if ! [[ "${port}" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
    error_exit "Porta inválida: ${port}. Use um número entre 1 e 65535."
  fi
}

if [[ $# -eq 0 ]]; then
  usage
fi

while [[ $# -gt 0 ]]; do
  case "${1}" in
  --vhost-server-ip=*)
    VHOST_IP="${1#*=}"
    shift
    ;;
  --vhost-server-port=*)
    VHOST_PORT="${1#*=}"
    shift
    ;;
  *)
    error_exit "Argumento desconhecido: ${1}"
    ;;
  esac
done

if [[ -z "${VHOST_IP}" ]]; then
  echo "ERRO: Parâmetro --vhost-server-ip é obrigatório." >&2
  usage
fi

if [[ -z "${VHOST_PORT}" ]]; then
  echo "ERRO: Parâmetro --vhost-server-port é obrigatório." >&2
  usage
fi

validate_ip "${VHOST_IP}"
validate_port "${VHOST_PORT}"

if [[ ${EUID} -ne 0 ]]; then
  error_exit "Este script precisa ser executado como root (ou com sudo)."
fi

echo ">>> Iniciando instalação e configuração do Nginx..."

echo ">>> Atualizando lista de pacotes (apt update)..."
apt-get update -y || error_exit "Falha ao executar apt update."

echo ">>> Instalando Nginx (apt install nginx)..."
apt-get install -y nginx || error_exit "Falha ao instalar o Nginx."

CONFIG_FILE_PATH="${NGINX_SITES_AVAILABLE}/${DEFAULT_VHOST_NAME}"
echo ">>> Criando arquivo de configuração: ${CONFIG_FILE_PATH}"

bash -c "cat > ${CONFIG_FILE_PATH}" <<EOF
server {
    listen ${VHOST_IP}:${VHOST_PORT} default_server;

    root /var/www/html;

    index index.html index.htm index.nginx-debian.html;

    server_name _;

    location / {
        try_files \$uri \$uri/ =404;
    }

    access_log /var/log/nginx/${DEFAULT_VHOST_NAME}.access.log;
    error_log /var/log/nginx/${DEFAULT_VHOST_NAME}.error.log;
}
EOF

echo ">>> Habilitando ${DEFAULT_VHOST_NAME}..."

ln -sf "${CONFIG_FILE_PATH}" "${NGINX_SITES_ENABLED}/${DEFAULT_VHOST_NAME}"

echo ">>> Testando a configuração do Nginx (nginx -t)..."
nginx -t || error_exit "Falha no teste de configuração do Nginx. Verifique os arquivos em ${NGINX_CONFIG_DIR}."

echo ">>> Reiniciando e habilitando o serviço Nginx (systemctl)..."
systemctl restart nginx || error_exit "Falha ao reiniciar o serviço Nginx."
systemctl enable nginx || error_exit "Falha ao habilitar o serviço Nginx na inicialização."

echo ">>> Instalação e configuração do Nginx concluídas com sucesso!"
echo ">>> Nginx está escutando em: ${VHOST_IP}:${VHOST_PORT} (IPv4)"

exit 0
