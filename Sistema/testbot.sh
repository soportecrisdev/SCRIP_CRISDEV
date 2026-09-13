#!/bin/bash
[[ $(screen -list| grep -c 'bot_teste') == '0' ]] && {
    clear
    echo -e "\E[44;1;37m     ACTIVACIÓN BOT SSH PRUEBA     \E[0m"
    echo ""
    echo -ne "\n\033[1;32mINTRODUZCA EL TOKEN\033[1;37m: "
    read token
    clear
    echo ""
    echo -e "\033[1;32mINICIANDO BOT PRUEBA \033[0m\n"
    cd $HOME/BOT
    rm -rf $HOME/BOT/botssh
    wget -qO botssh "https://raw.githubusercontent.com/soportecrisdev/SCRIP_CRISDEV/main/Sistema/botssh" >/dev/null 2>&1
    chmod 777 botssh
    echo ""
    sleep 1
    screen -dmS bot_teste ./botssh $token > /dev/null 2>&1
    clear
    echo "BOT ACTIVADO"
    menu
} || {
    screen -r -S "bot_teste" -X quit
    clear
    echo "BOT DESACTIVADO"
    menu
}
