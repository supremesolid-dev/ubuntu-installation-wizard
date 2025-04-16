#!/usr/bin/env bash

# === Configuração Estrita ===
# -e: Sai imediatamente se um comando falhar.
# -u: Trata variáveis não definidas como erro.
# -o pipefail: O status de saída de um pipeline é o do último comando que falhou.
set -euo pipefail

# === Constantes ===
readonly MYSQL_CONFIG_FILE="/etc/mysql/mysql.conf.d/mysqld.cnf"
readonly REQUIRED_ARGS=2

# === Funções ===

# Exibe mensagem de uso e sai
usage() {
  echo "Uso: $0 <bind-address-ip> <bind-port>"
  echo "Exemplo: $0 192.168.1.100 3307"
  exit 1
}

# Exibe mensagem de erro e sai
error_exit() {
  echo "ERRO: $1" >&2
  exit 1
}

# Verifica se o script está sendo executado como root
check_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    error_exit "Este script precisa ser executado como root. Use 'sudo $0 ...'"
  fi
}

# === Validação de Argumentos ===
if [[ "$#" -ne ${REQUIRED_ARGS} ]]; then
  echo "ERRO: Número incorreto de argumentos."
  usage
fi

readonly BIND_ADDRESS="$1"
readonly BIND_PORT="$2"

# Validação simples do Port (deve ser um número)
if ! [[ "${BIND_PORT}" =~ ^[0-9]+$ ]] || [[ "${BIND_PORT}" -lt 1 ]] || [[ "${BIND_PORT}" -gt 65535 ]]; then
  error_exit "Porta inválida: '${BIND_PORT}'. Deve ser um número entre 1 e 65535."
fi

# === Verificação de Privilégios ===
check_root

# === Início da Execução ===
echo "Iniciando a configuração do MySQL Server..."
echo "  Endereço de Bind: ${BIND_ADDRESS}"
echo "  Porta de Bind:    ${BIND_PORT}"

# --- 1. Instalação do MySQL Server ---
echo "[1/4] Atualizando lista de pacotes..."
apt-get update || error_exit "Falha ao atualizar lista de pacotes (apt-get update)."

echo "[2/4] Instalando mysql-server..."
# Usar DEBIAN_FRONTEND=noninteractive para evitar prompts durante a instalação
export DEBIAN_FRONTEND=noninteractive
apt-get install -y mysql-server || error_exit "Falha ao instalar mysql-server."
unset DEBIAN_FRONTEND

# --- 2. Configuração do Bind Address e Porta ---
echo "[3/4] Configurando bind-address e port em ${MYSQL_CONFIG_FILE}..."

if [[ ! -f "${MYSQL_CONFIG_FILE}" ]]; then
  error_exit "Arquivo de configuração do MySQL não encontrado: ${MYSQL_CONFIG_FILE}"
fi

# Comenta configurações existentes de bind-address e port dentro da seção [mysqld]
# Isso evita duplicatas e garante que nossas configurações sejam usadas.
# O padrão busca linhas começando com 'bind-address' ou 'port', precedidas opcionalmente por espaços,
# dentro do bloco que começa com '[mysqld]' e termina antes do próximo bloco '['.
sed -i -e "/^\s*\[mysqld\]/,/^\s*\[/s/^\(\s*bind-address\s*=\)/#\1/" \
  -e "/^\s*\[mysqld\]/,/^\s*\[/s/^\(\s*port\s*=\)/#\1/" "${MYSQL_CONFIG_FILE}" ||
  error_exit "Falha ao comentar configurações existentes no arquivo ${MYSQL_CONFIG_FILE}."

# Adiciona as novas configurações logo após a linha [mysqld]
# Usamos um marcador único para evitar problemas se BIND_ADDRESS contiver barras '/'
# Substituímos \\n por uma nova linha real para sed multi-plataforma
readonly SED_INSERT_MARKER="##MYSQL_CONFIG_INSERT_POINT##"
sed -i "/^\s*\[mysqld\]/a ${SED_INSERT_MARKER}" "${MYSQL_CONFIG_FILE}"
sed -i "s|${SED_INSERT_MARKER}|bind-address = ${BIND_ADDRESS}\\nport         = ${BIND_PORT}|" "${MYSQL_CONFIG_FILE}" ||
  error_exit "Falha ao adicionar novas configurações bind-address/port em ${MYSQL_CONFIG_FILE}."

echo "Reiniciando o serviço MySQL para aplicar as configurações..."
systemctl restart mysql || error_exit "Falha ao reiniciar o serviço MySQL."
systemctl status mysql --no-pager # Mostra o status para verificação rápida

# --- 3. Configuração do Plugin auth_socket e Usuário Root ---
echo "[4/4] Configurando autenticação auth_socket para root@localhost..."

# Nota: Em muitas instalações recentes do MySQL no Ubuntu, o auth_socket
# já é o padrão para root@localhost e o plugin já está ativo/compilado.
# Estes comandos garantem o estado desejado. O comando INSTALL PLUGIN pode
# falhar se o plugin já estiver ativo ou for built-in, o que geralmente é seguro ignorar
# nesse contexto específico, pois o objetivo final é usar o ALTER USER.

# Usamos um Here Document para passar os comandos SQL para o cliente mysql
# Executamos como root do sistema, que geralmente pode se conectar via socket sem senha
if ! sudo mysql <<-EOF; then
    -- Tenta instalar/carregar o plugin. Pode falhar se já ativo/built-in (geralmente OK).
    -- Em caso de erro aqui, verificar os logs do MySQL se a autenticação falhar depois.
    INSTALL PLUGIN IF NOT EXISTS auth_socket SONAME 'auth_socket.so';

    -- Altera o método de autenticação para root@localhost
    ALTER USER 'root'@'localhost' IDENTIFIED WITH auth_socket;

    -- Aplica as alterações de privilégio
    FLUSH PRIVILEGES;
EOF
  error_exit "Falha ao executar comandos SQL para configurar auth_socket. Verifique os logs do MySQL (/var/log/mysql/error.log)."
fi

echo "---"
echo "Configuração do MySQL concluída com sucesso!"
echo "O servidor MySQL está escutando em ${BIND_ADDRESS}:${BIND_PORT}."
echo "O usuário 'root'@'localhost' está configurado para usar autenticação via socket (auth_socket)."
echo "Você pode se conectar como root usando: sudo mysql"

exit 0
