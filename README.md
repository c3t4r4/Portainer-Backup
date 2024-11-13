# Portainer-Backup (Usado no Ubuntu 24.04 - Docker Swarm - Portainer)

# AINDA EM TESTE

## Exportando Variaveis para usar o backup
### Edite o arquivo .bashrc
```sh
nano ~/.bashrc
```

### Adicione ao final do arquivo as senhas
```conf
export USERNAME="nick"
export PASSWORD="!\$boré"
export PASSWORDENC="calambinha"
```

### Salve o arquivo e recarrege os dados
```sh
source ~/.bashrc
```

## Clonando o Repositorio na pasta Root
```sh
cd /root && git clone https://github.com/c3t4r4/Portainer-Backup.git && cd Portainer-Backup && chmod +x backupPortainer.sh && chmod +x restorePortainer.sh
```

## Gerando Backup
```sh
./root/Portainer-Backup/backupPortainer.sh
```

-------------------------------------------------

## Restaurar Backup
```sh
./root/Portainer-Backup/restorePortainer.sh caminho_para_o_arquivo_criptografado.enc
```