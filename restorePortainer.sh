#!/bin/bash

# Função para exibir ajuda caso o usuário não forneça o nome do arquivo
function show_help {
    echo "Uso: $0 <arquivo_de_backup.enc>"
    echo "Exemplo: $0 BackupDocker_20231201_123456.zip.enc"
    exit 1
}

# Verificar se o nome do arquivo foi passado como argumento
if [ $# -ne 1 ]; then
    echo "Erro: Nenhum arquivo de backup foi fornecido."
    show_help
fi

# Variáveis de Configuração
ENCRYPTED_FILE="$1" # Nome do arquivo de backup passado como argumento
PASSWORDENC="${PASSWORDENC:-calambinha}"
UNZIP_DIR="RestoredDocker"
DEST_DIR="/root/${UNZIP_DIR}"
PORTAINER_HOST="http://localhost:9000" # Altere para o novo host do Portainer
USERNAME="${USERNAME:-nick}"
PASSWORD="${PASSWORD:-!\$boré}"
DOCKER_VOLUMES_DIR="/var/lib/docker/volumes"

# Verificar se o arquivo de backup existe
if [ ! -f "$ENCRYPTED_FILE" ]; then
    echo "Erro: O arquivo '$ENCRYPTED_FILE' não foi encontrado."
    exit 1
fi

# Criar diretório de destino se não existir
mkdir -p "$DEST_DIR"

# Descriptografar o arquivo de backup
echo "Descriptografando o arquivo: $ENCRYPTED_FILE..."
openssl enc -aes-256-cbc -d -salt -pbkdf2 -k "$PASSWORDENC" -in "$ENCRYPTED_FILE" -out "RestoredBackup.zip"

# Verificar se o arquivo foi descriptografado com sucesso
if [ ! -f "RestoredBackup.zip" ]; then
    echo "Erro: Não foi possível descriptografar o arquivo de backup."
    exit 1
fi

# Descompactar o backup
echo "Descompactando backup..."
unzip -o "RestoredBackup.zip" -d "$UNZIP_DIR"

# Validar se o descompactamento foi bem-sucedido
if [ $? -ne 0 ]; then
    echo "Erro ao descompactar o backup."
    exit 1
fi

# Corrigir o nível extra de diretório (se existir BackupDocker/)
if [ -d "$UNZIP_DIR/BackupDocker" ]; then
    echo "Corrigindo estrutura de diretórios..."
    mv "$UNZIP_DIR/BackupDocker/"* "$UNZIP_DIR/"  # Move o conteúdo para o diretório correto
    rm -rf "$UNZIP_DIR/BackupDocker"             # Remove o diretório adicional
fi

# Limpar arquivo compactado (opcional)
rm "RestoredBackup.zip"

# Restaurando Volumes
# Iterar sobre cada arquivo de backup no diretório de backups
for backup_file in "$VOLUMES_DIR"/*.zip; do
    # Verificar se existem arquivos .zip
    if [[ ! -e $backup_file ]]; then
        echo "Não foram encontrados arquivos de backup no diretório $VOLUMES_DIR."
        exit 0
    fi

    # Obter o nome do volume a partir do nome do arquivo de backup
    # Exemplo: "volume_name_backup.zip" -> "volume_name"
    backup_filename=$(basename "$backup_file")
    volume_name=$(echo "$backup_filename" | sed -E 's/_backup.zip//')

    echo "Processando o arquivo de backup: $backup_file"
    echo "Volume a ser restaurado: $volume_name"

    # Verificar se já existe um volume com o mesmo nome
    if [[ -d "$DOCKER_VOLUMES_DIR/$volume_name" ]]; then
        echo "Aviso: Já existe um volume com o nome '$volume_name' em $DOCKER_VOLUMES_DIR."
        echo "Você deseja substituir o volume existente? (s/n)"
        read -r replace

        if [[ "$replace" != "s" && "$replace" != "S" ]]; then
        echo "Pulado: O volume '$volume_name' não será restaurado."
        continue
        else
        # Remover o volume existente antes de restaurar
        echo "Removendo o volume existente: $DOCKER_VOLUMES_DIR/$volume_name"
        rm -rf "$DOCKER_VOLUMES_DIR/$volume_name"
        fi
    fi

    # Restaurar o volume a partir do backup
    echo "Restaurando o volume $volume_name..."
    unzip -o "$backup_file" -d "/"

    # Confirmar se a restauração foi bem-sucedida
    if [[ $? -eq 0 ]]; then
        echo "Restauração concluída para o volume: $volume_name."
    else
        echo "Erro: Falha ao restaurar o volume: $volume_name."
    fi
done

# Autenticação no novo Portainer - obtendo JWT token
echo "Autenticando no novo host do Portainer..."
TOKEN=$(curl -s -X POST -H "Content-Type: application/json" \
    -d '{"Username": "'"$USERNAME"'", "Password": "'"$PASSWORD"'"}' \
    "$PORTAINER_HOST/api/auth" | jq -r .jwt)

# Validar autenticação
if [ -z "$TOKEN" ]; then
    echo "Erro ao autenticar no Portainer. Verifique as credenciais."
    exit 1
fi

# Função para converter o conteúdo do arquivo .env em JSON
function env_to_json {
    local env_file="$1"
    jq -nR '[inputs | split("=") | {name: .[0], value: .[1]}]' < "$env_file"
}

# Função para reformar o conteúdo do arquivo JSON e remover quebras de linha
function reform_json {
    local json_file="$1"
    jq -r '.StackFileContent' < "$json_file" | jq -sRr @json
}

# Processar cada stack no backup
echo "Iniciando a restauração das stacks..."
STACKS_DIR="$UNZIP_DIR"

for STACK_PATH in "$STACKS_DIR"/*; do
    if [ -d "$STACK_PATH" ]; then
        STACK_NAME=$(basename "$STACK_PATH")
        CONFIG_FILE=$(find "$STACK_PATH" -type f -name "${STACK_NAME}_config_*.json")

        # Verificar se o arquivo foi encontrado
        if [ -f "$CONFIG_FILE" ]; then
            echo "Arquivo de configuração encontrado: $CONFIG_FILE"
            CONFIG_CONTENT=$(reform_json "$CONFIG_FILE")
            echo "$CONFIG_CONTENT"

            # Restaurar variáveis de ambiente (.env)
            ENV_FILE=$(find "$STACK_PATH" -type f -name "${STACK_NAME}_env_*.env")
            if [ -f "$ENV_FILE" ]; then
                echo "Restaurando variáveis .env para a stack $STACK_NAME..."
                ENV_CONTENT=$(env_to_json "$ENV_FILE")
                echo "$ENV_CONTENT"
            else
                ENV_CONTENT="[]"
                echo "Nenhum arquivo .env encontrado para a stack $STACK_NAME."
            fi

            # Criar a stack no novo host do Portainer
            RESPONSE=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
                        -d "{
                                \"Name\": \"$STACK_NAME\",
                                \"fromAppTemplate\": false,
                                \"StackFileContent\": $CONFIG_CONTENT,
                                \"Env\": $ENV_CONTENT,
                                \"Prune\": false
                        }" \
                        "$PORTAINER_HOST/api/stacks/create/swarm/string?endpointId=1")
            echo "Response for stack $STACK_NAME: $RESPONSE"
        else
            echo "Arquivo de configuração não encontrado para a stack $STACK_NAME em $STACK_PATH."
        fi

        echo -e "Restauração da stack $STACK_NAME concluída.\n"
    fi
done

echo "Todas as stacks foram processadas!"

# Finalizar limpeza
echo "Limpando diretórios temporários..."
rm -rf "$UNZIP_DIR"

echo "Restauração concluída com sucesso!"

echo "Restauração completa de todas as stacks concluída."
