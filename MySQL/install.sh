#!/usr/bin/env bash

set -euo pipefail

BIND_IP=""
BIND_PORT=""
MYSQL_ROOT_PASSWORD=""

readonly MYSQL_CONFIG_FILE="/etc/mysql/mysql.conf.d/mysqld.cnf"

error_exit() {
  echo "ERRO: ${1}" >&2
  exit 1
}

usage() {
  echo "Uso: ${0} --bind-address-ip=<IP> --bind-port=<PORTA> --password-root=<SENHA>"
  echo
  echo "  Parâmetros Obrigatórios:"
  echo "    --bind-address-ip=<IP>    Endereço IP para o MySQL escutar (ex: 0.0.0.0 para todos)."
  echo "    --bind-port=<PORTA>       Porta para o MySQL escutar (ex: 3306)."
  echo "    --password-root=<SENHA>   Senha desejada para o usuário 'root'@'localhost'."
  echo
  echo "  AVISO DE SEGURANÇA: Passar a senha via argumento é inseguro."
  exit 1
}

validate_ip() {
  local ip="${1}"
  local ip_regex='^((([0-9]{1,3}\.){3}[0-9]{1,3})|0\.0\.0\.0)$'

  if ! [[ "${ip}" =~ ${ip_regex} ]]; then
    error_exit "Formato de endereço IP inválido: ${ip}. Use X.X.X.X ou 0.0.0.0."
  fi

  if [[ "${ip}" != "0.0.0.0" ]]; then
      local IFS='.'
      read -ra octets <<< "${ip}"
      for octet in "${octets[@]}"; do
          if ! [[ "${octet}" =~ ^[0-9]+$ ]] || (( octet < 0 || octet > 255 )); then
              error_exit "Endereço IP inválido: ${ip}. Octeto '${octet}' fora do intervalo 0-255."
          fi
      done
      IFS=' '
  fi
}

validate_port() {
  local port="${1}"
  if ! [[ "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    error_exit "Porta inválida: ${port}. Use um número entre 1 e 65535."
  fi
}

if [[ $# -eq 0 ]]; then
    usage
fi

while [[ $# -gt 0 ]]; do
  case "${1}" in
    --bind-address-ip=*)
      BIND_IP="${1#*=}"
      shift
      ;;
    --bind-port=*)
      BIND_PORT="${1#*=}"
      shift
      ;;
    --password-root=*)
      MYSQL_ROOT_PASSWORD="${1#*=}"
      shift
      ;;
    *)
      error_exit "Argumento desconhecido: ${1}"
      ;;
  esac
done

if [[ -z "${BIND_IP}" ]]; then
  echo "ERRO: Parâmetro --bind-address-ip é obrigatório." >&2
  usage
fi
if [[ -z "${BIND_PORT}" ]]; then
  echo "ERRO: Parâmetro --bind-port é obrigatório." >&2
  usage
fi
if [[ -z "${MYSQL_ROOT_PASSWORD}" ]]; then
  echo "ERRO: Parâmetro --password-root é obrigatório." >&2
  usage
fi

validate_ip "${BIND_IP}"
validate_port "${BIND_PORT}"

if [[ ${EUID} -ne 0 ]]; then
   error_exit "Este script precisa ser executado como root (ou com sudo)."
fi

echo ">>> Iniciando instalação e configuração do MySQL Server..."
echo ">>> Pré-configurando senha root para instalação não interativa..."
debconf-set-selections <<< "mysql-server mysql-server/root_password password ${MYSQL_ROOT_PASSWORD}"
debconf-set-selections <<< "mysql-server mysql-server/root_password_again password ${MYSQL_ROOT_PASSWORD}"

echo ">>> Senha root pré-configurada."

echo ">>> Atualizando lista de pacotes (apt update)..."
apt-get update -y || error_exit "Falha ao executar apt update."

echo ">>> Instalando MySQL Server (apt install mysql-server)..."

export DEBIAN_FRONTEND=noninteractive
apt-get install -y mysql-server mysql-client || error_exit "Falha ao instalar o MySQL Server."

echo ">>> Configurando bind-address e port em ${MYSQL_CONFIG_FILE}..."
if [[ ! -f "${MYSQL_CONFIG_FILE}" ]]; then
    error_exit "Arquivo de configuração do MySQL não encontrado: ${MYSQL_CONFIG_FILE}"
fi

if grep -qE "^\s*\[mysqld\]" "${MYSQL_CONFIG_FILE}"; then
    if grep -qE "^\s*[#]?\s*bind-address\s*=" "${MYSQL_CONFIG_FILE}"; then
        sed -i -E "s/^\s*[#]?\s*bind-address\s*=.*/bind-address = ${BIND_IP}/" "${MYSQL_CONFIG_FILE}"
    else
        sed -i "/^\s*\[mysqld\]/a bind-address = ${BIND_IP}" "${MYSQL_CONFIG_FILE}"
    fi

    if grep -qE "^\s*[#]?\s*port\s*=" "${MYSQL_CONFIG_FILE}"; then
        sed -i -E "s/^\s*[#]?\s*port\s*=.*/port = ${BIND_PORT}/" "${MYSQL_CONFIG_FILE}"
    else
        sed -i "/^\s*bind-address\s*=/a port = ${BIND_PORT}" "${MYSQL_CONFIG_FILE}"
    fi
else
    error_exit "Seção [mysqld] não encontrada em ${MYSQL_CONFIG_FILE}. Não é possível configurar bind-address/port."
fi

echo ">>> Configuração de rede atualizada."

echo ">>> Verificando/Redefinindo senha root via SQL (usando auth_socket se disponível)..."

mysql --execute="ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}'; FLUSH PRIVILEGES;" || echo "AVISO: Falha ao redefinir senha via SQL (pode já estar correta ou auth_socket não funcionou). Verifique manualmente."

echo ">>> Reiniciando e habilitando o serviço MySQL (systemctl)..."

systemctl restart mysql || error_exit "Falha ao reiniciar o serviço MySQL."
systemctl enable mysql || error_exit "Falha ao habilitar o serviço MySQL na inicialização."

echo ">>> Instalação e configuração do MySQL Server concluídas com sucesso!"
echo ">>> MySQL está configurado para escutar em: ${BIND_IP}:${BIND_PORT}"

echo ">>> Senha para 'root'@'localhost' definida (verifique se o comando SQL acima foi bem-sucedido)."

exit 0