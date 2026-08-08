# Changelog

## 1.5.0 - 2026-08-08

- Consolida todos os patches em um único `install.sh` autossuficiente.
- Corrige execução interativa por `curl | bash` usando `/dev/tty`.
- Corrige codificação UTF-8 e finais de linha Linux.
- Remove Chat ID padrão e qualquer credencial fixa.
- Sincroniza literalmente o monitor embutido com o arquivo separado.
- Corrige validação UDP 1812 sem depender de uma coluna fixa do `ss`.
- Detecta clientes `mysql` e `mariadb` e serviços alternativos.
- Desativa crons antigos para impedir alertas com nomes/configurações anteriores.
- Preserva leitura incremental, `flock`, `SELECT 1`, cooldown e Telegram editável.
- Incorpora o Guardian v1.4 ao monitor principal sem criar cron concorrente.
- Aguarda 90 segundos por recuperação automática antes da intervenção.
- Adiciona encerramento TERM/KILL controlado e limpeza segura de socket/PID.
- Aguarda até 150 segundos pelo retorno do banco e reinicia o pool SQL do FreeRADIUS.

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
