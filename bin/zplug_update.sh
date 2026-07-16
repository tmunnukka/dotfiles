#!/bin/zsh

EMAIL="munnu@kolumbus.fi"
SENDER="timo@bogey.munnukka.fi"

export ZPLUG_HOME=$HOME/.zplug
# Parameters
#   local recipient="$1:-munnu@kolumbus.fi"
#   local subject="$2"
#   local log_file="$3"      # Path to log file in /tmp
#   local sender="${4:-noreply@norttilaakso.fi}"  # Default sender if not provided


source /home/timo/bin/send_notification_email.sh

source /usr/share/zplug/init.zsh

zplug clear
zplug "plugins/git", from:oh-my-zsh
zplug "plugins/sudo", from:oh-my-zsh
zplug "plugins/command-not-found", from:oh-my-zsh
zplug "zsh-users/zsh-syntax-highlighting"
zplug "zsh-users/zsh-autosuggestions"
zplug "zsh-users/zsh-history-substring-search"
zplug "zsh-users/zsh-completions"
zplug "junegunn/fzf"
zplug "themes/fino", from:oh-my-zsh, as:theme   # Theme

zplug list

zplug check || zplug install

zplug update

zplug load --verbose



if (( $+functions[test_func] )); then
    send_notification_email "$EMAIL" "Bogeyn ZPlug päivitetty" "$ZPLUG_HOME/log/update.log" "$SENDER"
else
    send_notification_email "$EMAIL" "Bogeyn ZPlug:iin ei oo päivityksiä." "$ZPLUG_HOME/log/update.log" "$SENDER"
fi
