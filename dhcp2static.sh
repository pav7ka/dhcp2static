#!/bin/bash

##########
# скрипт , который считывает IP GW DNS полученный по dhcp и прописывает их статикой
# также выставляет hostnamе или как аргмент при запуске скрипта или запрашивает
# ver 0.3 | date 2023-12-25
# pav7ka (c)
# attention : используете скрипт на свой страх и риск "as is" | lic : public domain 
##########

#   объявляем глобальные переменные с пустыми значениями , чтобы не было мусора
# объявляем массивы
DEV_ARR=()
TYP_ARR=()
#CON_ARR=()
UUID_ARR=()
STAT_ARR=()

# объявляем переменные
TEMP_FILE=""
TEMP_DIR="/dev/shm"

# для отладки 
#TEMP_DIR="/root"

# аргументы для подстановки в nmcli
DOM="XX.XXX.ru"

HOSTNAME="$1"

# ограничение nmcli
#https://github.com/NetworkManager/NetworkManager/blob/main/NEWS
#Add "ipv6.method=disabled" to disable IPv6 on a device, like also possible for
#IPv4. Until now, the users could only set "ipv6.method=ignore" which means the
#users are free to set IPv6 related sysctl values themselves
NMCLI_VER="1.19.99"

echo -e "\n  СРИПТ НАЧАЛ РАБОТУ\n======================"
#   nmcli можно только или от root или sudo
# проверяет от кого запущен
# для отладки поставлен знак "!" , чтобы можно было запускать скрипт от пользователя
if [[ $EUID -ne 0 ]]
then
    echo -e "/!\ : я есть Groot\n"
    exit 1
else
    echo "|i| : я есть Root"
fi

# проверяем существование директории для временного файла и можно ли создать временный файл 
if [[ -d "$TEMP_DIR" ]]
then
    TEMP_FILE="$( mktemp -q -p $TEMP_DIR )" # -q тихий режим в случае ошибки
    if [[ -f "$TEMP_FILE" ]]
    then
        echo "|i| : файл $TEMP_FILE создался"
    else
        echo -e "/!\ : файл TEMP_FILE не создался по какой то причине\n"
        exit 1
    fi
else
    echo -e "/!\ : каталога $TEMP_DIR не существует\n"
    exit 1
fi

###  # работает только начиная с версии bash 4.3 ( local -n )
###  # функция заполнения массива
###  # ранее была реализация через вывод команды на прямую , но при этом отсекало послед строку если она пустая
###  # пришлось делать костыль через временный файл где есть маркер EOF , или я уже туплю
###  function fill_arr() {
###  nmcli -g $1 device status > $TEMP_FILE
###  #local TXT=$( nmcli -g $1 device status | tee txt )
###  local -n ARR=$2 # делаем локальную переменную как ссылку на массив "-n"
###  while read -r line
###  do
###      if [[ -n "$line" ]]
###      then
###  # если необходимо строку разбить на слова
###  #        words=( "$line" ) # получаем строку в виде массива слов
###  #        ARR+=( "${words[*]}" ) # пихаем все слова в ячейку массива , либо указать конкретное слово
###          ARR+=( "$line" ) # пихаем всю строку в массив
###      else
###          ARR+=( "NULL" ) # если строка пустая делаем спец маркер
###      fi
###  done < $TEMP_FILE #$TXT
###  }

function fill_arr() {
nmcli -g $1 device status > $TEMP_FILE
local ARR=() # создаем локальный массив
while read -r line
do
    if [[ -n "$line" ]]
    then
        ARR+=( "$line" ) # пихаем всю строку в массив
    else
        ARR+=( "NULL" ) # если строка пустая делаем спец маркер
    fi
done < $TEMP_FILE

# для отладки
#echo ${#ARR[*]} ${ARR[*]}

if [[ "$1" == "DEVICE" ]]
then
    DEV_ARR=("${ARR[@]}")
elif [[ "$1" == "TYPE" ]]
then
    TYP_ARR=("${ARR[@]}")
elif [[ "$1" == "CON-UUID" ]]
then
    UUID_ARR=("${ARR[@]}")
elif [[ "$1" == "STATE" ]]
then
    STAT_ARR=("${ARR[@]}")
else
    echo -e "/!\ : чтото пошло не так при присвоении массива\n"
    exit 1
fi
}

# получаем нужное нам значение по UUID
function get_val() {
    nmcli -g "$1" connection show "$2" | tr -d "|"
}

function set_val() {
    nmcli connection modify "$1" "$2" "$3"
}

function down_up() {
    nmcli con down "$1" && nmcli con up "$1"
}

function hostnm() {
    nmcli general hostname "$1"
}

#
# логика обработки выключенных сетевых устройств
# они не имеют UUID ( он пустой )  пока не включишь
#

# очищаем массивы
DEV_ARR=()
TYP_ARR=()
STAT_ARR=()
# заполняем массивы передавая аргументы
# заремлены для передачи в первой версии функции как второй аргумент
fill_arr "DEVICE" # DEV_ARR
fill_arr "TYPE" # TYP_ARR
fill_arr "STATE" # STAT_ARR

# начинаем пробегать по массиву с данными TYPE , нам нужен тип "disconnected" и "ethernet"
for idx in ${!TYP_ARR[*]}
do
    if [[ "${STAT_ARR[$idx]}" == "disconnected" && "${TYP_ARR[$idx]}" == "ethernet" ]]
    then
        echo -e "\n|i| : попытка активировать : ${DEV_ARR[$idx]}"
# активируем
        nmcli device connect ${DEV_ARR[$idx]}
# перезапускаем а надо ?
        down_up "${DEV_ARR[$idx]}"
    else
        echo -e "\n|i| : не активируем : ${DEV_ARR[$idx]} >>> не 'disconnected' или не 'ethernet'"
    fi
done

#
# логика обработки dhcp > static
#

# очищаем массивы
DEV_ARR=()
TYP_ARR=()
UUID_ARR=()
STAT_ARR=()
# заполняем массивы передавая аргументы
# заремлены для передачи в первой версии функции как второй аргумент
fill_arr "DEVICE" # DEV_ARR
fill_arr "TYPE" # TYP_ARR
fill_arr "CON-UUID" # UUID_ARR
fill_arr "STATE" # STAT_ARR

# после заполнения массивов файл нам больше не нужен
echo -e "\n|i| : файл $TEMP_FILE больше ну нужен массивы заполнены , удаляем"
rm $TEMP_FILE

#   для отладки
# выводим длину массива и данные массива
#echo ${#DEV_ARR[*]} ${DEV_ARR[*]} 
#echo ${#TYP_ARR[*]} ${TYP_ARR[*]}
###echo ${#CON_ARR[*]} ${CON_ARR[*]}
#echo ${#UUID_ARR[*]} ${UUID_ARR[*]}
#echo ${#STAT_ARR[*]} ${STAT_ARR[*]}


# начинаем пробегать по массиву с данными TYPE , нам нужен тип "auto" и "ethernet" и "connected"
for idx in ${!TYP_ARR[*]}
do
# отбрасываем индексы если в них есть маркер пустой строки NULL
    if [[ "${DEV_ARR[$idx]}" != "NULL" && "${TYP_ARR[$idx]}" != "NULL" && "${UUID_ARR[$idx]}" != "NULL" ]]
    then
        MET=$( get_val "ipv4.method" "${UUID_ARR[$idx]}" )
#        echo $MET
        if [[ "$MET" == "auto" && "${TYP_ARR[$idx]}" == "ethernet" && "${STAT_ARR[$idx]}" == "connected" ]]
        then
            echo -e "\n|i| : выставляем : для ${DEV_ARR[$idx]} следующие значения :"
# получаем значения 
            IP=$( get_val "IP4.ADDRESS" "${UUID_ARR[$idx]}" )
            GW=$( get_val "IP4.GATEWAY" "${UUID_ARR[$idx]}" )
            DNS=$( get_val "IP4.DNS" "${UUID_ARR[$idx]}" )
            echo -e "IP -- $IP\nGW -- $GW\nDNS -- $DNS\nMETHOD -- $MET на manual\nDOMAIN -- $DOM\n"
# прописываем значения , которые получили , можно было одной строкой , но так понятнее что делаем
            set_val "${DEV_ARR[$idx]}" "ipv4.addresses" "$IP"
            set_val "${DEV_ARR[$idx]}" "ipv4.gateway" "$GW"
            set_val "${DEV_ARR[$idx]}" "ipv4.dns" "$DNS"
            set_val "${DEV_ARR[$idx]}" "ipv4.method" "manual"
            set_val "${DEV_ARR[$idx]}" "ipv4.dns-search" "$DOM"
# отключаем IPv6
# см. выше , disabled появился только в версии 1.20
            VER="$( nmcli -v | awk '{ print $4 }' )"
            CHECK="$( echo -e "$NMCLI_VER\n$VER" | sort | tail -n 1 )"
            if [[ "$VER" == "$CHECK" ]]
            then
#                echo "$VER версия выше $NMCLI_VER"
                set_val "${DEV_ARR[$idx]}" "ipv6.method" "disabled"
            else
#                echo "$VER версия ниже $NMCLI_VER"
                set_val "${DEV_ARR[$idx]}" "ipv6.method" "ignore"
            fi
# перезапускаем
            down_up "${DEV_ARR[$idx]}"
        else
            echo -e "\n|i| : не правим : ${DEV_ARR[$idx]} >>> не 'auto' или не 'ethernet'"
        fi
    else
        echo -e "\n|i| : не обрабатываем : ${DEV_ARR[$idx]} >>> имеет NULL в одном из массивов"
    fi
done

if [[ "$HOSTNAME" != "" ]]
then
    hostnm "$HOSTNAME.$DOM"
    echo -e "\n|i| имя хоста выставлено $( nmcli general hostname )"
else
    echo -e "\n    >>> при запуске скрипта не был введен ни один аргумент для внесения hostname"
    echo -e "    >>> введите имя сервера [без домена] или нажмите ВВОД , чтобы пропустить :"
    read HOSTNAME
    if [[ "$HOSTNAME" != "" ]]
    then
        hostnm "$HOSTNAME.$DOM"
        echo -e "\n|i| имя хоста выставлено $( nmcli general hostname )"
    else
        hostnm "localhost.$DOM"
        echo -e "\n|i| имя хоста выставлено по умолчанию $( nmcli general hostname )"
    fi
fi

echo -e "======================\n  СКРИПТ ОТРАБОТАЛ\n"
exit 0
