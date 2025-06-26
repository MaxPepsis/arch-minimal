#!/bin/bash
set -e

# ==========================================================
# FUNCIONES AUXILIARES
# ==========================================================
convert_to_gib() {
    local size_input="$1"
    local num unit
    num=$(echo "$size_input" | grep -oP '^[0-9]+(\.[0-9]+)?')
    unit=$(echo "$size_input" | grep -oP '[MG]$' | tr '[:upper:]' '[:lower:]')
    [[ -z "$unit" ]] && unit="g"
    case "$unit" in
        m) printf "%d" "$(echo "$num/1024" | bc)" ;; # MiB -> GiB
        g)
            if [[ "$num" =~ \.[0-9]+ ]]; then
                printf "%d" "$(echo "$num+0.999" | bc)"
            else
                printf "%d" "$num"
            fi
            ;;
        *) echo "0" ;;
    esac
}

# ==========================================================
# CONFIGURACIÓN INICIAL
# ==========================================================
echo ">>> Instalador de particiones interactivo"
echo ">>> Al usar esta herramienta, confirma que entiendes que borrará todos los datos."
read -p "¿Deseas continuar con la instalación? [s/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[sS]$ ]]; then
    echo "Cancelado por el usuario."; exit 1
fi

# Listar discos disponibles
echo "Discos disponibles:"
lsblk -d -p -o NAME,SIZE,MODEL,TYPE | grep disk

# Seleccionar disco
echo
read -p "Introduce la ruta de tu disco (ej: /dev/sda): " DISK
if [[ ! -b "$DISK" ]]; then
    echo "❌ Disco inválido."; exit 1
fi

echo "🔴 Instalación limpia: borrando tabla de particiones"
sgdisk --zap-all "$DISK"

# Detectar modo de arranque
echo
IS_UEFI=false; EFI_SIZE=0
if [ -d /sys/firmware/efi ]; then
    IS_UEFI=true; EFI_SIZE=1
    echo "✅ UEFI detectado: se creará partición EFI 300MiB"
else
    echo "ℹ️ Modo BIOS detectado: sin EFI"
fi

# Obtener RAM y disco
MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
if [[ -z "$MEM_KB" ]]; then
    MEM_KB=0
fi
MEM_GIB=$((MEM_KB/1024/1024))
DISK_SIZE_BYTES=$(lsblk -b -n -d -o SIZE "$DISK")
DISK_GIB=$((DISK_SIZE_BYTES/1024/1024/1024))
echo "Disco: $DISK (${DISK_GIB}G) | RAM: ${MEM_GIB}G"

# ==========================================================
# SWAP (OPCIONAL)
# ==========================================================
read -p "¿Deseas usar SWAP? [s/N]: " USE_SWAP; USE_SWAP=${USE_SWAP:-N}
SWAP_GIB=0
if [[ "$USE_SWAP" =~ ^[sS]$ ]]; then
    read -p "¿Vas a usar hibernación? [s/N]: " HIB; HIB=${HIB:-N}
    # Calcular mínimo
    if (( MEM_GIB < 2 )); then
        SWAP_MIN=$((MEM_GIB*2))
        [[ "$HIB" =~ ^[sS]$ ]] && SWAP_MIN=$((MEM_GIB*3))
    elif (( MEM_GIB < 8 )); then
        SWAP_MIN=$MEM_GIB
        [[ "$HIB" =~ ^[sS]$ ]] && SWAP_MIN=$((MEM_GIB*2))
    elif (( MEM_GIB < 64 )); then
        SWAP_MIN=4
        [[ "$HIB" =~ ^[sS]$ ]] && SWAP_MIN=$(printf "%d" "$(echo "${MEM_GIB}*1.5"|bc)")
    else
        SWAP_MIN=4
        [[ "$HIB" =~ ^[sS]$ ]] && echo "⚠️ Hibernación no recomendada con RAM>64G"
    fi
    # Forzar al menos 2 GiB
    (( SWAP_MIN<2 )) && SWAP_MIN=2
    echo "Tamaño SWAP recomendado: ${SWAP_MIN}G"
    while true; do
        read -p "Tamaño SWAP [${SWAP_MIN}G]: " SWAP_RAW
        SWAP_RAW=${SWAP_RAW:-${SWAP_MIN}G}
        SWAP_GIB=$(convert_to_gib "$SWAP_RAW")
        (( SWAP_GIB<SWAP_MIN )) && echo "❌ Mínimo ${SWAP_MIN}G" || { echo "✅ SWAP: ${SWAP_GIB}G"; break; }
    done
else
    echo "ℹ️ Omitiendo SWAP"
fi

# ==========================================================
# ROOT y HOME
# ==========================================================
USED=$((EFI_SIZE+SWAP_GIB))
AVAIL=$((DISK_GIB-USED))
while true; do
    read -p "Tamaño ROOT (disp ${AVAIL}G): " RRAW
    ROOT_GIB=$(convert_to_gib "$RRAW")
    (( ROOT_GIB>0 && ROOT_GIB<=AVAIL )) && { echo "✅ ROOT: ${ROOT_GIB}G"; break; } || echo "❌ Usa 1-${AVAIL}G"
done

USED=$((USED+ROOT_GIB)); AVAIL=$((DISK_GIB-USED))
read -p "Crear /home? Esp ${AVAIL}G [s/N]: " HASK; HASK=${HASK:-N}
HOME_GIB=0
if [[ "$HASK" =~ ^[sS]$ && $AVAIL -gt 0 ]]; then
    while true; do
        read -p "Tamaño /home (1-${AVAIL}G): " HRAW
        HOME_GIB=$(convert_to_gib "$HRAW")
        (( HOME_GIB>0 && HOME_GIB<=AVAIL )) && { echo "✅ /home: ${HOME_GIB}G"; break; } || echo "❌ Usa 1-${AVAIL}G"
    done
else
    echo "ℹ️ /home incluido en ROOT"
fi

# ==========================================================
# RESUMEN
# ==========================================================
echo -e "\n== Resumen en $DISK =="
((EFI_SIZE)) && echo "EFI:300M"
[[ "$USE_SWAP" =~ ^[sS]$ ]] && echo "SWAP:${SWAP_GIB}G"
echo "ROOT:${ROOT_GIB}G"
((HOME_GIB)) && echo "/home:${HOME_GIB}G"
echo "Libre:$((DISK_GIB-EFI_SIZE-SWAP_GIB-ROOT_GIB-HOME_GIB))G"

read -p "Proceder con fdisk? [s/N]: " GO
[[ "$GO" =~ ^[sS]$ ]] || { echo "Cancelado"; exit 1; }

# ==========================================================
# CREACIÓN DE PARTICIONES con fdisk
# ==========================================================
{
    if $IS_UEFI; then
        # crear GPT
        echo g
        # EFI 300MiB
        echo n
        echo
        echo
        echo +300M
        echo t
        echo 1
    else
        # crear MBR
        echo o
    fi

    # SWAP si aplica
    if [[ "$USE_SWAP" =~ ^[sS]$ ]]; then
        echo n
        echo
        echo
        echo +${SWAP_GIB}G
        echo t
        # para GPT cambiar tipo '19' (Linux swap); MBR usa código 82
        if $IS_UEFI; then echo 19; else echo 82; fi
    fi

    # ROOT siempre
    echo n
    echo
    echo
    echo +${ROOT_GIB}G

    # HOME si aplica
    if (( HOME_GIB > 0 )); then
        echo n
        echo
        echo
        echo +${HOME_GIB}G
    fi

    # escribir cambios
    echo w
} | fdisk "$DISK"

echo "✅ Particiones creadas exitosamente."
