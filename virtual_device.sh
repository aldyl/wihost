
 [[ ! -e "/tmp/i.next" ]] && echo "virtual units" > "/tmp/i.next"

get_var_virt(){
confdir="/tmp/wihost"
INTERFACE_WLAN=$(cat "/tmp/wihost/confnameinterface.conf")
USE_IWCONFIG=0


if ! init_lock; then
    echo "ERROR: Inicializacion del bloqueo fallida" >&2
    exit 1
fi


}

# all new files and directories must be readable only by root.
# in special cases we must use chmod to give any other permissions.
SCRIPT_UMASK=0077
umask $SCRIPT_UMASK

#############################
###########Semaforo##########
#############################

# on success it echos a non-zero unused FD
# on error it echos 0
get_avail_fd() {
    local x
    for x in $(seq 1 $(ulimit -n)); do
        if [[ ! -a "/proc/$BASHPID/fd/$x" ]]; then
            echo $x
            return
        fi
    done
    echo 0
}

# lock file for the mutex counter
COUNTER_LOCK_FILE=/tmp/wihost/$$.lock

cleanup_lock() {
    rm -f $COUNTER_LOCK_FILE
}

init_lock() {
    local LOCK_FILE=/tmp/wihost/wi.all.lock

    # we initialize only once
    [[ $LOCK_FD -ne 0 ]] && return 0

    LOCK_FD=$(get_avail_fd)
    [[ $LOCK_FD -eq 0 ]] && return 1

    # open/create lock file with write access for all users
    # otherwise normal users will not be able to use it.
    # to avoid race conditions on creation, we need to
    # use umask to set the permissions.
    umask 0555
    eval "exec $LOCK_FD>$LOCK_FILE" > /dev/null 2>&1 || return 1
    umask $SCRIPT_UMASK

    # there is a case where lock file was created from a normal
    # user. change the owner to root as soon as we can.
    [[ $(id -u) -eq 0 ]] && chown 0:0 $LOCK_FILE

    # create mutex counter lock file
    echo 0 > $COUNTER_LOCK_FILE

    return $?
}

# recursive mutex lock for all create_ap processes
mutex_lock() {
    local counter_mutex_fd
    local counter

    # lock local mutex and read counter
    counter_mutex_fd=$(get_avail_fd)
    if [[ $counter_mutex_fd -ne 0 ]]; then
        eval "exec $counter_mutex_fd<>$COUNTER_LOCK_FILE"
        flock $counter_mutex_fd
        read -u $counter_mutex_fd counter
    else
        echo "Failed to lock mutex counter" >&2
        return 1
    fi

    # lock global mutex and increase counter
    [[ $counter -eq 0 ]] && flock $LOCK_FD
    counter=$(( $counter + 1 ))

    # write counter and unlock local mutex
    echo $counter > /proc/$BASHPID/fd/$counter_mutex_fd
    eval "exec ${counter_mutex_fd}<&-"
    return 0
}

# recursive mutex unlock for all create_ap processes
mutex_unlock() {
    local counter_mutex_fd
    local counter

    # lock local mutex and read counter
    counter_mutex_fd=$(get_avail_fd)
    if [[ $counter_mutex_fd -ne 0 ]]; then
        eval "exec $counter_mutex_fd<>$COUNTER_LOCK_FILE"
        flock $counter_mutex_fd
        read -u $counter_mutex_fd counter
    else
        echo "Failed to lock mutex counter" >&2
        return 1
    fi

    # decrease counter and unlock global mutex
    if [[ $counter -gt 0 ]]; then
        counter=$(( $counter - 1 ))
        [[ $counter -eq 0 ]] && flock -u $LOCK_FD
    fi

    # write counter and unlock local mutex
    echo $counter > /proc/$BASHPID/fd/$counter_mutex_fd
    eval "exec ${counter_mutex_fd}<&-"
    return 0
}


#####################################
#####Comparador de versiones#########
#####################################
# it takes 2 arguments
# returns:
#  0 if v1 (1st argument) and v2 (2nd argument) are the same
#  1 if v1 is less than v2
#  2 if v1 is greater than v2
version_cmp() {
    local V1 V2 VN x
    [[ ! $1 =~ ^[0-9]+(\.[0-9]+)*$ ]] && die "Wrong version format!"
    [[ ! $2 =~ ^[0-9]+(\.[0-9]+)*$ ]] && die "Wrong version format!"

    V1=( $(echo $1 | tr '.' ' ') )
    V2=( $(echo $2 | tr '.' ' ') )
    VN=${#V1[@]}
    [[ $VN -lt ${#V2[@]} ]] && VN=${#V2[@]}

    for ((x = 0; x < $VN; x++)); do
        [[ ${V1[x]} -lt ${V2[x]} ]] && return 1
        [[ ${V1[x]} -gt ${V2[x]} ]] && return 2
    done

    return 0
}




###########################
#Crear una interface virtual
###########################

alloc_new_iface() {
    local prefix=$1
    local i
   
    i=$(grep -c "ap" "/tmp/i.next")
  
    mutex_lock
    while :; do
        if ! is_interface $prefix$i && [[ ! -f $confdir/ifaces/$prefix$i ]]; then
            mkdir -p $confdir/ifaces
            touch $confdir/ifaces/$prefix$i
            echo $prefix$i
            mutex_unlock
            return
        fi
        i=$((i + 1))
    done
    mutex_unlock
}

dealloc_iface() {
	
	    echo "$1" >> "/tmp/i.next"
	    rm -f $confdir/ifaces/$1
	    
}
################
#Interface Wify#
################



is_interface() {
    [[ -z "$1" ]] && return 1
    [[ -d "/sys/class/net/${1}" ]]
}



is_wifi_connected() {
	USE_IWCONFIG=1
    if [[ $USE_IWCONFIG -eq 0 ]]; then
        iw dev "$1" link 2>&1 | grep -E '^Connected to' > /dev/null 2>&1 && return 0
     else
        iwconfig "$1" 2>&1 | grep -E 'Access Point: [0-9a-fA-F]{2}:' > /dev/null 2>&1 && return 0
      echo "No conectado"

    fi
    return 1
}
##############################
#Referente a la Mac del dispositivo
#Virtual
##############################
get_macaddr() {
    is_interface "$1" || return
    cat "/sys/class/net/${1}/address"
}

get_all_macaddrs() {
    cat /sys/class/net/*/address
}
get_new_macaddr() {
    local OLDMAC NEWMAC LAST_BYTE i
    OLDMAC=$(get_macaddr "$1")
    LAST_BYTE=$(printf %d 0x${OLDMAC##*:})
    mutex_lock
    for i in {1..255}; do
        NEWMAC="${OLDMAC%:*}:$(printf %02x $(( ($LAST_BYTE + $i) % 256 )))"
        (get_all_macaddrs | grep "$NEWMAC" > /dev/null 2>&1) || break
    done
    mutex_unlock
    echo $NEWMAC
}
#########################################
# taken from iw/util.c###################
#IEEEE###################################
ieee80211_frequency_to_channel() {
    local FREQ=$1
    if [[ $FREQ -eq 2484 ]]; then
        echo 14
    elif [[ $FREQ -lt 2484 ]]; then
        echo $(( ($FREQ - 2407) / 5 ))
    elif [[ $FREQ -ge 4910 && $FREQ -le 4980 ]]; then
        echo $(( ($FREQ - 4000) / 5 ))
    elif [[ $FREQ -le 45000 ]]; then
        echo $(( ($FREQ - 5000) / 5 ))
    elif [[ $FREQ -ge 58320 && $FREQ -le 64800 ]]; then
        echo $(( ($FREQ - 56160) / 2160 ))
    else
        echo 0
    fi
}
#########################
#NETWORKMANAGER##########
#########################

NETWORKMANAGER_CONF=/etc/NetworkManager/NetworkManager.conf
NM_OLDER_VERSION=1

#Verificar activo NM
networkmanager_is_running() {
    local NMCLI_OUT
    networkmanager_exists || return 1
    if [[ $NM_OLDER_VERSION -eq 1 ]]; then
        NMCLI_OUT=$(nmcli -t -f RUNNING nm 2>&1 | grep -E '^running$')
    else
        NMCLI_OUT=$(nmcli -t -f RUNNING g 2>&1 | grep -E '^running$')
    fi
    [[ -n "$NMCLI_OUT" ]]
}
#Que version es disponible
networkmanager_exists() {
    local NM_VER
    which nmcli > /dev/null 2>&1 || return 1
    NM_VER=$(nmcli -v | grep -m1 -oE '[0-9]+(\.[0-9]+)*\.[0-9]+')
    version_cmp $NM_VER 0.9.9
    if [[ $? -eq 1 ]]; then
        NM_OLDER_VERSION=1
    else
        NM_OLDER_VERSION=0
    fi
    return 0
}
#Quitar maestro a la interface
ADDED_UNMANAGED=

networkmanager_add_unmanaged() {
    local MAC UNMANAGED WAS_EMPTY x
    networkmanager_exists || return 1

    [[ -d ${NETWORKMANAGER_CONF%/*} ]] || mkdir -p ${NETWORKMANAGER_CONF%/*}
    [[ -f ${NETWORKMANAGER_CONF} ]] || touch ${NETWORKMANAGER_CONF}

    if [[ $NM_OLDER_VERSION -eq 1 ]]; then
        if [[ -z "$2" ]]; then
            MAC=$(get_macaddr "$1")
        else
            MAC="$2"
        fi
        [[ -z "$MAC" ]] && return 1
    fi

    mutex_lock
    UNMANAGED=$(grep -m1 -Eo '^unmanaged-devices=[[:alnum:]:;,-]*' /etc/NetworkManager/NetworkManager.conf)

    WAS_EMPTY=0
    [[ -z "$UNMANAGED" ]] && WAS_EMPTY=1
    UNMANAGED=$(echo "$UNMANAGED" | sed 's/unmanaged-devices=//' | tr ';,' ' ')

    # if it exists, do nothing
    for x in $UNMANAGED; do
        if [[ $x == "mac:${MAC}" ]] ||
               [[ $NM_OLDER_VERSION -eq 0 && $x == "interface-name:${1}" ]]; then
            mutex_unlock
            return 2
        fi
    done

    if [[ $NM_OLDER_VERSION -eq 1 ]]; then
        UNMANAGED="${UNMANAGED} mac:${MAC}"
    else
        UNMANAGED="${UNMANAGED} interface-name:${1}"
    fi

    UNMANAGED=$(echo $UNMANAGED | sed -e 's/^ //')
    UNMANAGED="${UNMANAGED// /;}"
    UNMANAGED="unmanaged-devices=${UNMANAGED}"

    if ! grep -E '^\[keyfile\]' ${NETWORKMANAGER_CONF} > /dev/null 2>&1; then
        echo -e "\n\n[keyfile]\n${UNMANAGED}" >> ${NETWORKMANAGER_CONF}
    elif [[ $WAS_EMPTY -eq 1 ]]; then
        sed -e "s/^\(\[keyfile\].*\)$/\1\n${UNMANAGED}/" -i ${NETWORKMANAGER_CONF}
    else
        sed -e "s/^unmanaged-devices=.*/${UNMANAGED}/" -i ${NETWORKMANAGER_CONF}
    fi

    ADDED_UNMANAGED="${ADDED_UNMANAGED} ${1} "
    mutex_unlock

    local nm_pid=$(pidof NetworkManager)
    [[ -n "$nm_pid" ]] && kill -HUP $nm_pid

    return 0
}

networkmanager_wait_until_unmanaged() {
    local RES
    networkmanager_is_running || return 1
    while :; do
        networkmanager_iface_is_unmanaged "$1"
        RES=$?
        [[ $RES -eq 0 ]] && break
        [[ $RES -eq 2 ]] && die "Interface '${1}' does not exists.
       It's probably renamed by a udev rule."
        sleep 1
    done
    sleep 2
    return 0
}
networkmanager_iface_is_unmanaged() {
    is_interface "$1" || return 2
    (nmcli -t -f DEVICE,STATE d 2>&1 | grep -E "^$1:unmanaged$" > /dev/null 2>&1) || return 1
}

networkmanager_rm_unmanaged_if_needed() {
    [[ $ADDED_UNMANAGED =~ .*\ ${1}\ .* ]] && networkmanager_rm_unmanaged $1 $2
}

networkmanager_rm_unmanaged() {
    local MAC UNMANAGED
    networkmanager_exists || return 1
    [[ ! -f ${NETWORKMANAGER_CONF} ]] && return 1

    if [[ $NM_OLDER_VERSION -eq 1 ]]; then
        if [[ -z "$2" ]]; then
            MAC=$(get_macaddr "$1")
        else
            MAC="$2"
        fi
        [[ -z "$MAC" ]] && return 1
    fi

    mutex_lock
    UNMANAGED=$(grep -m1 -Eo '^unmanaged-devices=[[:alnum:]:;,-]*' /etc/NetworkManager/NetworkManager.conf | sed 's/unmanaged-devices=//' | tr ';,' ' ')

    if [[ -z "$UNMANAGED" ]]; then
        mutex_unlock
        return 1
    fi

    [[ -n "$MAC" ]] && UNMANAGED=$(echo $UNMANAGED | sed -e "s/mac:${MAC}\( \|$\)//g")
    UNMANAGED=$(echo $UNMANAGED | sed -e "s/interface-name:${1}\( \|$\)//g")
    UNMANAGED=$(echo $UNMANAGED | sed -e 's/ $//')

    if [[ -z "$UNMANAGED" ]]; then
        sed -e "/^unmanaged-devices=.*/d" -i ${NETWORKMANAGER_CONF}
    else
        UNMANAGED="${UNMANAGED// /;}"
        UNMANAGED="unmanaged-devices=${UNMANAGED}"
        sed -e "s/^unmanaged-devices=.*/${UNMANAGED}/" -i ${NETWORKMANAGER_CONF}
    fi

    ADDED_UNMANAGED="${ADDED_UNMANAGED/ ${1} /}"
    mutex_unlock

    local nm_pid=$(pidof NetworkManager)
    [[ -n "$nm_pid" ]] && kill -HUP $nm_pid

    return 0
}

die() {
    [[ -n "$1" ]] && echo -e "\nERROR: $1\n" >&2
    # send die signal to the main process
    [[ $BASHPID -ne $$ ]] && kill -USR2 $$
    # we don't need to call cleanup because it's traped on EXIT
    exit 1
}


#######################################################################
############            Logica de la aplicacion             ############
##########################################################################



crear_virtual_wify(){
	
NO_VIRT=$1

get_var_virt


if [[ $NO_VIRT -eq 0 ]]; then
    VWIFI_IFACE=$(alloc_new_iface ap)
    
       
    show_in_log  "Creando access point virtual  $VWIFI_IFACE"
   
    # in NetworkManager 0.9.9 and above we can set the interface as unmanaged without
    # the need of MAC address, so we set it before we create the virtual interface.
   
    if networkmanager_is_running && [[ $NM_OLDER_VERSION -eq 0 ]]; then
        echo -n "Network Manager found, set ${VWIFI_IFACE} as unmanaged device... "
       
        networkmanager_add_unmanaged ${VWIFI_IFACE}
        # do not call networkmanager_wait_until_unmanaged because interface does not
        # exist yet
        echo "DONE"
    fi
    
     
    
#Si ya estas conectado a una red wify
    if is_wifi_connected ${INTERFACE_WLAN}; then
        INTERFACE_WLAN_FREQ=$(iw dev ${INTERFACE_WLAN} link | grep -i freq | awk '{print $2}')
        INTERFACE_WLAN_CHANNEL=$(ieee80211_frequency_to_channel ${INTERFACE_WLAN_FREQ})
        echo -n "${INTERFACE_WLAN} is already associated with channel ${INTERFACE_WLAN_CHANNEL} (${INTERFACE_WLAN_FREQ} MHz)"
        if is_5ghz_frequency $INTERFACE_WLAN_FREQ; then
            FREQ_BAND=5
        else
            FREQ_BAND=2.4
        fi
        if [[ $INTERFACE_WLAN_CHANNEL -ne $CHANNEL ]]; then
            echo ", fallback to channel ${INTERFACE_WLAN_CHANNEL}"
            CHANNEL=$INTERFACE_WLAN_CHANNEL
        else
            echo
        fi
       
    fi
          
    VIRTDIEMSG="Maybe your WiFi adapter does not fully support virtual interfaces.
       Try again with --no-virt."
       
   
    show_in_log "Creating a virtual WiFi interface... "
###########################################################################################
#Anadir la interface virtual a networkmanager
########################################################################################

      show_err  "Creando access point on ${INTERFACE_WLAN} con $VWIFI_IFACE"
      
    if iw dev ${INTERFACE_WLAN} interface add ${VWIFI_IFACE} type __ap; then
        # now we can call networkmanager_wait_until_unmanaged
        networkmanager_is_running && [[ $NM_OLDER_VERSION -eq 0 ]] && networkmanager_wait_until_unmanaged ${VWIFI_IFACE}
        
        show_in_log "${VWIFI_IFACE} created."
    else
        VWIFI_IFACE=
        die "$VIRTDIEMSG"
    fi
    
##########################################################################################
#nueva mac para nueva virtual
    
    OLD_MACADDR=$(get_macaddr ${VWIFI_IFACE})
    echo "$OLD_MACADDR" > "$confdir/ioldmac.id"
    
    if [[ -z "$NEW_MACADDR" && $(get_all_macaddrs | grep -c ${OLD_MACADDR}) -ne 1 ]]; then
        NEW_MACADDR=$(get_new_macaddr ${VWIFI_IFACE})
    fi
    INTERFACE_WLAN=${VWIFI_IFACE}
else
    OLD_MACADDR=$(get_macaddr ${INTERFACE_WLAN})
fi
    echo "$NEW_MACADDR" > "$confdir/inewmac.id"
##########################################################################################    
# initialize WiFi interface


if [[ $NO_VIRT -eq 0 && -n "$NEW_MACADDR" ]]; then
    ip link set dev ${INTERFACE_WLAN} address ${NEW_MACADDR} || die "$VIRTDIEMSG"
fi

ip link set down dev ${INTERFACE_WLAN} || die "$VIRTDIEMSG"
ip addr flush ${INTERFACE_WLAN} || die "$VIRTDIEMSG"

if [[ $NO_VIRT -eq 1 && -n "$NEW_MACADDR" ]]; then
    ip link set dev ${INTERFACE_WLAN} address ${NEW_MACADDR} || die
fi


echo ${INTERFACE_WLAN} > "$confdir/interfacevirtual.id"

}


##########################################################################################
##########################   Eliminar wify virtual       #################################
##########################################################################################



eliminar_virtual_wify(){
	
	NO_VIRT=$1
	get_var_virt
	
VWIFI_IFACE=$(cat "$confdir/interfacevirtual.id")
OLD_MACADDR=$(cat "$confdir/ioldmac.id")
NEW_MACADDR=$(cat "$confdir/inewmac.id")


if [[ $NO_VIRT -eq 0 ]] ; then

        if [[ -n "$VWIFI_IFACE" ]]; then
            ip link set down dev ${VWIFI_IFACE}
            ip addr flush ${VWIFI_IFACE}
            networkmanager_rm_unmanaged_if_needed ${VWIFI_IFACE} ${OLD_MACADDR}
            iw dev ${VWIFI_IFACE} del
            dealloc_iface $VWIFI_IFACE
            show_err "Full delete of virtual wify interface  $VWIFI_IFACE"
        fi
    else
        ip link set down dev ${INTERFACE_WLAN}
        ip addr flush ${INTERFACE_WLAN}
        if [[ -n "$NEW_MACADDR" ]]; then
            ip link set dev ${INTERFACE_WLAN} address ${OLD_MACADDR}
        fi
         echo "Full reset of $INTERFACE_WLAN"
        networkmanager_rm_unmanaged_if_needed ${INTERFACE_WLAN} ${OLD_MACADDR}
    fi


}

