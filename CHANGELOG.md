# Changelog

## 1.0.0 - 2026-08-01

- Leitura incremental de `radius.log` por inode e offset.
- Exclusão mútua com `flock` e execução a cada 30 segundos.
- Diagnóstico MySQL por `SELECT 1` com timeout.
- Detecção de MySQL/MariaDB e FreeRADIUS/radiusd.
- Recuperação ordenada e validação do processo e UDP 1812.
- Cooldown de 180 segundos, ignorado em falha real do `SELECT 1`.
- Telegram opcional com edição da mensagem original e fallback.
- Instalador com backups, crons antigos, configuração `600` e logrotate.
- Desinstalador com opção de preservar logs e backups.
- Compatibilidade com Debian 9, 10, 11 e 12 e múltiplos gerenciadores de serviço.
