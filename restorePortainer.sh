#!/bin/bash

# Configurações
PORTAINER_HOST="https://painel.teste.com.br"  # Altere para o host do seu Portainer
USERNAME="${USERNAME:-nick}"
PASSWORD="${PASSWORD:-!\$boré}"
ENCRYPTED_BACKUP="$1"  # Caminho para o arquivo de backup criptografado
RESTORE_DIR="/root/RestorePortainer"
PASSWORDENC="${PASSWORDENC:-calambinha}"  # Usa a variável de ambiente para a senha de criptografia

# Verifica se o arquivo criptografado foi fornecido
if [ -z "$ENCRYPTED_BACKUP" ]; then
    echo "Uso: $0 <caminho_para_o_arquivo_criptografado>"
    exit 1
fi

# Cria o diretório de restauração se não existir
mkdir -p "$RESTORE_DIR"

# Descriptografa o arquivo de backup
DECRYPTED_FILE="${RESTORE_DIR}/backup_restaurado.zip"
openssl enc -d -aes-256-cbc -pbkdf2 -k "$PASSWORDENC" -in "$ENCRYPTED_BACKUP" -out "$DECRYPTED_FILE" || { echo "Erro ao descriptografar o arquivo."; exit 1; }
echo "Arquivo descriptografado com sucesso."

# Descompacta o backup
unzip "$DECRYPTED_FILE" -d "$RESTORE_DIR" || { echo "Erro ao descompactar o arquivo."; exit 1; }
echo "Backup restaurado com sucesso no diretório $RESTORE_DIR."

# Remove o arquivo zip descriptografado
rm "$DECRYPTED_FILE"

# Autenticação - obtendo o JWT token
TOKEN=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"Username": "'"$USERNAME"'", "Password": "'"$PASSWORD"'"}' \
  "$PORTAINER_HOST/api/auth" | jq -r .jwt)

# Verifica se o token foi obtido
if [ -z "$TOKEN" ]; then
    echo "Falha ao obter o token de autenticação. Verifique as credenciais."
    exit 1
fi

# Restaura cada stack
echo "Iniciando a restauração das stacks..."

for STACK_DIR in "$RESTORE_DIR"/*/; do
    STACK_NAME=$(basename "$STACK_DIR")
    echo "Restaurando a stack $STACK_NAME..."

    # 1. Restaura a configuração JSON da stack
    CONFIG_FILE="${STACK_DIR}/${STACK_NAME}_config_*.json"
    if [ -f "$CONFIG_FILE" ]; then
        CONFIG=$(cat "$CONFIG_FILE")
        
        # Cria ou atualiza a stack no Portainer
        STACK_ID=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
            -d "{\"Name\":\"$STACK_NAME\", \"StackFileContent\":$CONFIG}" \
            "$PORTAINER_HOST/api/stacks?type=1&method=string&endpointId=1" | jq -r .Id)

        if [ -n "$STACK_ID" ]; then
            echo "Stack $STACK_NAME restaurada com ID $STACK_ID."
        else
            echo "Erro ao restaurar a configuração da stack $STACK_NAME."
            continue
        fi
    else
        echo "Configuração JSON para $STACK_NAME não encontrada."
        continue
    fi

    # 2. Restaura as variáveis de ambiente (arquivo .env)
    ENV_FILE="${STACK_DIR}/${STACK_NAME}_env_*.env"
    if [ -f "$ENV_FILE" ]; then
        while IFS= read -r line; do
            VAR_NAME=$(echo "$line" | cut -d '=' -f 1)
            VAR_VALUE=$(echo "$line" | cut -d '=' -f 2-)
            curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
                -d "{\"Name\":\"$VAR_NAME\", \"Value\":\"$VAR_VALUE\"}" \
                "$PORTAINER_HOST/api/stacks/$STACK_ID/env" > /dev/null
        done < "$ENV_FILE"
        echo "Variáveis de ambiente da stack $STACK_NAME restauradas."
    else
        echo "Arquivo .env para $STACK_NAME não encontrado."
    fi

    # 3. Restaura os volumes associados à stack
    for VOLUME_DIR in "$STACK_DIR/volumes/"*; do
        VOLUME_NAME=$(basename "$VOLUME_DIR")
        if [ -d "$VOLUME_DIR" ]; then
            # Cria o volume no Docker, caso não exista
            docker volume create "$VOLUME_NAME" > /dev/null

            # Restaura o conteúdo do volume
            docker run --rm -v "$VOLUME_NAME:/volume_data" -v "$VOLUME_DIR:/backup" alpine \
                sh -c "cd /volume_data && tar -xzf /backup/${VOLUME_NAME}_backup_*.tar.gz" || echo "Erro ao restaurar o volume $VOLUME_NAME."
            echo "Volume $VOLUME_NAME restaurado para a stack $STACK_NAME."
        else
            echo "Diretório do volume $VOLUME_NAME não encontrado para a stack $STACK_NAME."
        fi
    done

    echo -e "Restauração da stack $STACK_NAME completa.\n\n"
done

echo "Restauração completa de todas as stacks concluída."
