#!/bin/bash

# Configurações
PORTAINER_HOST="https://painel.teste.com.br" # Altere para o host e porta do seu Portainer
USERNAME="${USERNAME:-nick}"
PASSWORD="${PASSWORD:-!\$boré}"
BACKUPDIR="BackupDocker"
DESTINATION="/root/BackupPortainer"
DATE=$(date +"%Y-%m-%d")
DATE_TIME=$(date +"%Y%m%d_%H%M%S")
ZIP_FILE="${BACKUP_DIR}_${DATE_TIME}.zip"
ENCRYPTED_FILE="${ZIP_FILE}.enc"
PASSWORDENC="${PASSWORDENC:-calambinha}"

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

    # 1. Exportando a configuração JSON da stack
    CONFIG=$(curl -s -H "Authorization: Bearer $TOKEN" "$PORTAINER_HOST/api/stacks/$STACK_ID/file" | jq .)
    
    if [ -n "$CONFIG" ]; then
        echo "$CONFIG" > "$STACK_DIR/${STACK_NAME}_config_$DATE.json"
        echo "Configuração da stack $STACK_NAME salva em $STACK_DIR."
    else
        echo "Erro ao obter a configuração da stack $STACK_NAME."
    fi

    # 2. Backup do volume associado à stack
    VOLUMES=$(docker stack ps "$STACK_NAME" --filter "desired-state=running" --format "{{.ID}}" | xargs -I {} docker inspect {} | jq -r '.[].Spec.ContainerSpec.Mounts[]? | select(.Type=="volume") | .Source')

    if [ -n "$VOLUMES" ]; then
        for VOLUME in $VOLUMES; do
            VOLUME_DIR="$STACK_DIR/volumes/$VOLUME"
            mkdir -p "$VOLUME_DIR"
            
            # Realizando o backup do volume
            docker run --rm -v "$VOLUME:/volume_data" -v "$VOLUME_DIR:/backup" alpine \
                sh -c "cd /volume_data && tar -czf /backup/${VOLUME}_backup_$DATE.tar.gz ."
            
            echo "Volume $VOLUME da stack $STACK_NAME salvo em $VOLUME_DIR."
        done
    else
        echo "Nenhum volume encontrado para a stack $STACK_NAME."
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