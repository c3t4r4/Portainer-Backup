#!/bin/bash

# Configurações
PORTAINER_HOST="https://painel.teste.com.br" # Altere para o host e porta do seu Portainer
USERNAME="${USERNAME:-nick}"
PASSWORD="${PASSWORD:-!\$boré}"
BACKUPDIR="BackupDocker"
DESTINATION="/root/${BACKUPDIR}"
VOLUMES="${DESTINATION}/Volumes"
DATE=$(date +"%Y-%m-%d")
DATE_TIME=$(date +"%Y%m%d_%H%M%S")
ZIP_FILE="${BACKUP_DIR}_${DATE_TIME}.zip"
ENCRYPTED_FILE="${ZIP_FILE}.enc"
PASSWORDENC="${PASSWORDENC:-calambinha}"
DOCKER_VOLUMES_DIR="/var/lib/docker/volumes"

# Cria o diretório de backup se ele não existir
mkdir -p "$DESTINATION"

# Autenticação - obtendo o JWT token
TOKEN=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"Username": "'"$USERNAME"'", "Password": "'"$PASSWORD"'"}' \
  "$PORTAINER_HOST/api/auth" | jq -r .jwt)

# Verifica se o token foi obtido
if [ -z "$TOKEN" ]; then
    echo "Falha ao obter o token de autenticação. Verifique as credenciais."
    exit 1
fi

# Obtendo a lista de stacks
STACKS=$(curl -s -H "Authorization: Bearer $TOKEN" "$PORTAINER_HOST/api/stacks" | jq -c '.[]')

if [ -z "$STACKS" ]; then
    echo "Nenhuma stack encontrada. Verifique o Portainer e tente novamente."
    exit 1
fi

# Exportando cada stack
echo "Iniciando o backup das stacks..."

# 1. Backup dos Volumes
EXCLUDED_DIRS=("portainer_data" "volume_swarm_certificates")

is_excluded() {
    local dir=$1
    for excluded in "${EXCLUDED_DIRS[@]}"; do
        if [[ "$dir" == "$excluded" ]]; then
        return 0  # Está na lista de exclusão
        fi
    done
    return 1  # Não está na lista de exclusão
}

mkdir -p "$VOLUMES"

# Iterar por cada item em $DOCKER_VOLUMES_DIR
for item in "$DOCKER_VOLUMES_DIR"/*; do
    # Verificar se é um diretório
    if [[ -d $item ]]; then
        # Obter o nome do diretório (basename)
        VOLUME_NAME=$(basename "$item")

        # Verificar se o diretório está na lista de exclusão
        if is_excluded "$VOLUME_NAME"; then
        echo "Ignorando o volume: $VOLUME_NAME"
        continue
        fi

        # Criar o arquivo tar.gz com o nome do volume e a data no destino de backup
        BACKUP_FILE="${VOLUMES}/${VOLUME_NAME}_backup.zip"
        echo "Criando backup do volume: $DOCKER_VOLUMES_DIR/$VOLUME_NAME -> $BACKUP_FILE"

        # Compactar o conteúdo do volume em formato tar.gz
        zip -r "$BACKUP_FILE" "$DOCKER_VOLUMES_DIR/$VOLUME_NAME"
    fi
done

for STACK in $STACKS; do
    STACK_ID=$(echo "$STACK" | jq -r .Id)
    STACK_NAME=$(echo "$STACK" | jq -r .Name)

    echo "Resposta da STACK ID $STACK_ID"

    echo "Resposta da STACK NAME $STACK_NAME"

    # Verifica se o ID e o Nome da stack foram obtidos
    if [ -z "$STACK_ID" ] || [ -z "$STACK_NAME" ]; then
        echo "Erro ao obter informações da stack. Verifique a configuração no Portainer."
        continue
    fi

    # Cria um diretório para a stack específica
    STACK_DIR="$DESTINATION/$STACK_NAME"
    mkdir -p "$STACK_DIR"

    # Obter os valores de Public e AdministratorsOnly em uma única chamada
    #curl -s -H "Authorization: Bearer $TOKEN" "$PORTAINER_HOST/api/stacks/$STACK_ID" | jq '{Public: .ResourceControl.Public, AdministratorsOnly: .ResourceControl.AdministratorsOnly}' > $STACK_DIR/ResourceControl.json

    # Fazer a chamada curl para obter ResourceControl
    RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" "$PORTAINER_HOST/api/stacks/$STACK_ID")

    # Extrair valores usando jq, se disponíveis
    PUBLIC=$(echo "$RESPONSE" | jq -r '.ResourceControl.Public // empty')
    ADMIN=$(echo "$RESPONSE" | jq -r '.ResourceControl.AdministratorsOnly // empty')

    # Verificar se os valores foram extraídos corretamente, caso contrário definir valores padrão
    if [[ -z "$PUBLIC" ]]; then
        PUBLIC=true
    fi

    if [[ -z "$ADMIN" ]]; then
        ADMIN=false
    fi

    # Construir o JSON final com os valores
    cat <<EOF > "$STACK_DIR/ResourceControl.json"
        {
        "Public": $PUBLIC,
        "AdministratorsOnly": $ADMIN
        }
EOF


    # 2. Exportando a configuração JSON da stack
    CONFIG=$(curl -s -H "Authorization: Bearer $TOKEN" "$PORTAINER_HOST/api/stacks/$STACK_ID/file" | jq -c .)
    
    if [ -n "$CONFIG" ]; then
        echo "$CONFIG" > "$STACK_DIR/${STACK_NAME}_config_$DATE.json"
        echo "Configuração da stack $STACK_NAME salva em $STACK_DIR."
    else
        echo "Erro ao obter a configuração da stack $STACK_NAME."
    fi

    # 3. Backup do arquivo .env, se existir
    ENV_CONTENT=$(curl -s -H "Authorization: Bearer $TOKEN" "$PORTAINER_HOST/api/stacks/$STACK_ID" | jq -r '.Env[] | "\(.name)=\(.value)"')
    
    if [ -n "$ENV_CONTENT" ]; then
        echo "$ENV_CONTENT" > "$STACK_DIR/${STACK_NAME}_env_$DATE.env" || echo "Erro ao salvar o conteúdo do arquivo .env para a stack $STACK_NAME."
        echo "Arquivo .env da stack $STACK_NAME salvo em $STACK_DIR."
    else
        echo "Nenhum arquivo .env encontrado para a stack $STACK_NAME."
    fi

    echo -e "Backup da stack $STACK_NAME completo.\n\n"
done

echo "Backup completo de todas as stacks concluído em $DESTINATION"

echo "Criando arquivo ZIP"

zip -r "$ZIP_FILE" "$BACKUPDIR" || { echo "Erro ao criar o arquivo zip."; exit 1; }

# Verifica se o zip foi criado com sucesso
if [ -f "$ZIP_FILE" ]; then
    echo "Backup criado com sucesso: $ZIP_FILE"
    
    # Criptografa o arquivo zip usando AES-256-CBC com uma senha e IV
    openssl enc -aes-256-cbc -salt -pbkdf2 -k "$PASSWORDENC" -in "$ZIP_FILE" -out "$ENCRYPTED_FILE" || { echo "Erro ao criptografar o arquivo."; exit 1; }
    echo "Arquivo criptografado com sucesso: $ENCRYPTED_FILE"

    # Remove o arquivo zip original após a criptografia
    rm "$ZIP_FILE"
    
    # Limpa o conteúdo da pasta BackupDocker após o backup e criptografia
    rm -rf "${BACKUPDIR:?}/"*
    echo "Conteúdo da pasta $BACKUP_DIR limpo."
else
    echo "Falha ao criar o arquivo zip."
fi