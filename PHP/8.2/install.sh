#!/usr/bin/env bash

# === Configuração de Segurança e Robustez ===
set -euo pipefail

# === Variáveis e Constantes ===
readonly PHP_VERSION="8.2"
readonly PHP_PPA="ppa:ondrej/php"
readonly PHP_MODS_AVAILABLE="/etc/php/${PHP_VERSION}/mods-available"
readonly PAM_INI_FILE="${PHP_MODS_AVAILABLE}/pam.ini"
readonly PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"

# === Funções ===

# Função para exibir mensagens de erro e sair
error_exit() {
  echo "ERRO: ${1}" >&2
  exit 1
}

# Função para verificar execução como root
check_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    error_exit "Este script precisa ser executado como root (ou com sudo)."
  fi
}

# Função para verificar se o PHP já está instalado
check_already_installed() {
  # Verifica se o pacote phpX.Y-cli está instalado e ok
  if dpkg-query -W -f='${Status}' "php${PHP_VERSION}-cli" 2>/dev/null | grep -q "ok installed"; then
    echo "INFO: PHP ${PHP_VERSION} (php${PHP_VERSION}-cli) parece já estar instalado. Saindo."
    exit 0 # Sair normalmente, não é um erro
  fi
  echo ">>> PHP ${PHP_VERSION} não encontrado. Prosseguindo com a instalação."
}

# Função principal de instalação
main() {
  check_root
  check_already_installed

  echo ">>> 1. Adicionando PPA ${PHP_PPA}..."
  apt-get update -y || error_exit "Falha ao atualizar lista de pacotes antes de adicionar PPA."
  apt-get install -y software-properties-common || error_exit "Falha ao instalar software-properties-common."
  add-apt-repository -y "${PHP_PPA}" || error_exit "Falha ao adicionar o PPA ${PHP_PPA}."

  echo ">>> 2. Atualizando lista de pacotes após adicionar PPA..."
  apt-get update -y || error_exit "Falha ao executar apt update após adicionar PPA."

  # Lista de extensões PHP a serem instaladas
  local php_extensions=(
    "cli" "fpm" "dev" "common" "bcmath" "imap" "redis" "snmp" "zip"
    "curl" "bz2" "intl" "gd" "mbstring" "mysql" "xml" "sqlite3" "pgsql"
  )
  local packages_to_install=()
  for ext in "${php_extensions[@]}"; do
    packages_to_install+=("php${PHP_VERSION}-${ext}")
  done

  echo ">>> 3. Instalando PHP ${PHP_VERSION} e extensões (${packages_to_install[*]})..."
  apt-get install -y "${packages_to_install[@]}" || error_exit "Falha ao instalar PHP ${PHP_VERSION} e/ou extensões."

  echo ">>> 4. Instalando dependências para a extensão PAM (PECL)..."
  # libpam0g-dev: Necessário para compilar a extensão PAM.
  # php-pear: Contém o comando 'pecl'.
  apt-get install -y libpam0g-dev php-pear || error_exit "Falha ao instalar dependências para PECL/PAM."

  echo ">>> 5. Instalando extensão PAM via PECL..."
  # 'pecl install' pode ser interativo em alguns casos, mas tentamos prosseguir.
  # Erros aqui podem indicar problemas de compilação ou dependências faltando.
  pecl install pam || error_exit "Falha ao instalar a extensão PAM via PECL."

  echo ">>> 6. Habilitando extensão PAM para CLI e FPM..."
  # PECL geralmente cria o arquivo .ini em mods-available.
  # Verificamos se ele existe antes de tentar habilitar.
  if [[ ! -f "${PAM_INI_FILE}" ]]; then
    # Se PECL não criou, podemos tentar criar (menos comum hoje em dia)
    echo "AVISO: Arquivo ${PAM_INI_FILE} não encontrado após 'pecl install'. Tentando criar."
    # Esta linha pode não ser necessária se pecl install funcionou corretamente.
    echo "extension=pam.so" >"${PAM_INI_FILE}" || error_exit "Falha ao criar ${PAM_INI_FILE}."
  fi
  # Habilita o módulo para todos os SAPIs disponíveis (CLI, FPM, etc.)
  phpenmod pam || error_exit "Falha ao executar phpenmod para a extensão PAM."

  echo ">>> 7. Limpando cache do APT..."
  apt-get clean || echo "AVISO: Falha ao limpar o cache do APT."

  echo ">>> Verificando instalação..."
  echo "-------------------------------------"
  php -v
  echo "-------------------------------------"
  echo "Módulos PHP carregados:"
  php -m | sort
  echo "-------------------------------------"
  echo "Extensões PECL instaladas:"
  pecl list
  echo "-------------------------------------"
  echo "Status do serviço PHP-FPM (${PHP_FPM_SERVICE}):"
  # Reiniciar para garantir que a extensão PAM seja carregada pelo FPM
  systemctl restart "${PHP_FPM_SERVICE}" || echo "AVISO: Falha ao reiniciar ${PHP_FPM_SERVICE}. Verifique manualmente."
  systemctl status "${PHP_FPM_SERVICE}" --no-pager || echo "AVISO: Falha ao obter status de ${PHP_FPM_SERVICE}."
  echo "-------------------------------------"

  echo ""
  echo "Instalação do PHP ${PHP_VERSION} e extensão PAM concluída com sucesso!"
  echo ""
  echo "Para gerenciar o serviço PHP-FPM:"
  echo "  sudo systemctl [start|stop|restart|status] ${PHP_FPM_SERVICE}"
  echo "Configurações principais do PHP estão em: /etc/php/${PHP_VERSION}/"
  echo "Verifique se a extensão 'pam' está listada em 'php -m'."
  echo "Lembre-se de configurar os pools do PHP-FPM em /etc/php/${PHP_VERSION}/fpm/pool.d/ conforme necessário."
}

# === Execução ===
main "$@"

exit 0
