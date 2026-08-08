# Monitor de estabilidade MK-AUTH

Monitor de recuperação automática da integração FreeRADIUS + MySQL/MariaDB para Debian 9, 10, 11 e 12. Compatível com `systemctl`, `service` e `/etc/init.d`.

## Instalação automatizada

Execute como `root` em um terminal interativo:

```bash
curl -fsSL https://raw.githubusercontent.com/brsxdlols/mkauth-monitor-travamento-mysql/v1.1.0/install.sh | bash
```

O instalador lê as respostas diretamente de `/dev/tty`, portanto funciona com `curl | bash` sem consumir o restante do script. Também pode ser baixado e executado como arquivo.

Ele solicita:

- nome do MK-AUTH/VM;
- ativação opcional do Telegram;
- token visível e Chat ID somente quando o Telegram é habilitado.

Não existe token ou Chat ID fixo no repositório. As credenciais ficam em `/etc/default/check_backup_freeradius`, com permissão `600`.

## Funcionamento

- lê somente novas linhas de `/var/log/freeradius/radius.log`, controladas por inode e offset;
- usa `flock` contra execuções simultâneas;
- testa MySQL/MariaDB com `SELECT 1` e timeout;
- detecta automaticamente serviços `mysql`, `mariadb`, `mysqld`, `freeradius` ou `radiusd`;
- para o FreeRADIUS, reinicia o banco, aguarda `SELECT 1`, inicia o FreeRADIUS e confirma processo e UDP 1812;
- aplica cooldown de 180 segundos, exceto quando o `SELECT 1` falha de verdade;
- envia alerta do Telegram e edita a mesma mensagem na recuperação, com fallback para nova mensagem.

## Arquivos criados

- `/var/check_backup_freeradius.sh`
- `/etc/default/check_backup_freeradius`
- `/etc/cron.d/check_backup_freeradius`
- `/etc/logrotate.d/check_backup_freeradius`
- `/var/lib/check_backup_freeradius`
- `/var/log/check_backup_freeradius.log`
- `/var/log/check_backup_freeradius_cron.log`

Arquivos anteriores recebem `.bak-AAAAMMDD-HHMMSS`. Todas as entradas cron antigas ativas que chamem `check_backup_freeradius.sh` são comentadas com backup, evitando que configurações antigas enviem alertas com outro nome de MK-AUTH.

## Teste controlado

Em uma janela:

```bash
tail -F /var/log/check_backup_freeradius.log
```

Em outra, durante manutenção:

```bash
service mysql stop
```

O monitor deve recuperar o banco e o FreeRADIUS em até um ciclo de 30 segundos.

## Desinstalação

```bash
chmod +x uninstall.sh
./uninstall.sh
```

O desinstalador pergunta se logs e backups devem ser preservados e não remove arquivos do MK-AUTH.
