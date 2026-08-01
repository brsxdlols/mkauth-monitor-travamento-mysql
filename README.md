# Monitor de estabilidade MK-AUTH

Monitor de recuperação automática da integração FreeRADIUS + MySQL/MariaDB, compatível com Debian 9, 10, 11 e 12. Não depende obrigatoriamente de `systemctl`: também funciona com `service` e `/etc/init.d`.

## Instalação

```bash
chmod +x install.sh uninstall.sh monitor/check_backup_freeradius.sh
sudo ./install.sh
```

O instalador exige `root`, solicita o nome da VM e pergunta se o Telegram será usado. Se habilitado, solicita o token de forma visível e o Chat ID. Credenciais reais não fazem parte do repositório; ficam em `/etc/default/check_backup_freeradius`, modo `600`. O Telegram só é testado quando habilitado.

## Arquivos criados

- `/var/check_backup_freeradius.sh`: monitor instalado.
- `/etc/default/check_backup_freeradius`: configuração protegida.
- `/etc/cron.d/check_backup_freeradius`: execuções separadas por 30 segundos.
- `/etc/logrotate.d/check_backup_freeradius`: rotação dos logs.
- `/var/lib/check_backup_freeradius`: inode, offset, cooldown e incidente.
- `/var/log/check_backup_freeradius.log`: eventos e recuperações.
- `/var/log/check_backup_freeradius_cron.log`: saída do cron.

Arquivos anteriores recebem `.bak-AAAAMMDD-HHMMSS`. Entradas cron antigas ativas que chamam o monitor são comentadas e preservadas em backup.

## Teste controlado

Em uma janela:

```bash
tail -F /var/log/check_backup_freeradius.log
```

Em outra, durante uma janela de manutenção:

```bash
service mysql stop
```

Em até 30 segundos o monitor deve detectar a falha do `SELECT 1`, parar o FreeRADIUS, reiniciar o banco, aguardar sua resposta, iniciar o FreeRADIUS e confirmar processo e UDP 1812.

Para acompanhar o cron:

```bash
tail -F /var/log/check_backup_freeradius_cron.log
```

## Desinstalação

```bash
sudo ./uninstall.sh
```

O desinstalador pergunta se logs e backups devem ser preservados. Ele não remove arquivos do MK-AUTH.
