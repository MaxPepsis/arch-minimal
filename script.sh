#!/bin/bash
set -e

# ==========================================================
# FUNCIONES AUXILIARES
# ==========================================================
# Convierte tamaños con sufijo (M, G) a GiB enteros
convert_to_gib() {
    local size_input="$1"
    local num unit
    num=$(echo "$size_input" | grep -oP '^[0-9]+(\.[0-9]+)?')
    unit=$(echo "$size_input" | grep -oP '[MG]$' | tr '[:upper:]' '[:lower:]')
    [[ -z "$unit" ]] && unit="g"
    case "$unit" in
        m) # MiB a GiB (truncar)
            printf "%d" "$(echo "$num/1024" | bc)" ;;
        g)
            # redondear hacia arriba si decimal
            if [[ "$num" =~ \.[0-9]+ ]]; then
                printf "%d" "$(echo "$num+0.999" | bc)"
            else
                printf "%d" "$num"
            fi;;
        *)  echo "0" ;;
    esac
}

# ==========================================================
# CONFIGURACIÓN INICIAL
# ==========================================================
echo ">>> Instalador de particiones interactivo"
read -p "¿Deseas configurar dual boot? [s/N]: " DUAL
DUAL=${DUAL:-N}

read -p "Introduce la ruta de tu disco (ej: /dev/sda): " DISK
if [[ ! -b "$DISK" ]]; then
    echo "❌ Disco inválido."; exit 1
fi

# Limpiar disco si NO es dual boot
if [[ ! "$DUAL" =~ ^[sS]$ ]]; then
    echo "🔴 Instalación limpia: borrando tabla de particiones existente"
    sgdisk --zap-all "$DISK"
else
    echo "🟢 Dual boot: se conservarán particiones existentes"
fi

# Obtiene memoria y disco
MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
MEM_GIB=$((MEM_KB/1024/1024))
DISK_SIZE=$(lsblk -b -n -d -o SIZE "$DISK")
DISK_GIB=$((DISK_SIZE/1024/1024/1024))

echo "Disco: $DISK (${DISK_GIB}G) | RAM total: ${MEM_GIB}G"

# ==========================================================
# CALCULAR SWAP SEGÚN RAM E HIBERNACIÓN
# ==========================================================
read -p "¿Vas a usar hibernación? [s/N]: " HIB
HIB=${HIB:-N}
if (( MEM_GIB < 2 )); then
    SWAP_MIN=$((MEM_GIB*2))
    ((HIB =~ ^[sS]$)) && SWAP_MIN=$((MEM_GIB*3))
elif (( MEM_GIB < 8 )); then
    SWAP_MIN=${MEM_GIB}
    ((HIB =~ ^[sS]$)) && SWAP_MIN=$((MEM_GIB*2))
elif (( MEM_GIB < 64 )); then
    SWAP_MIN=4
    ((HIB =~ ^[sS]$)) && SWAP_MIN=$(printf "%d" "$(echo "${MEM_GIB}*1.5" | bc)")
else
    SWAP_MIN=4
    if ((HIB =~ ^[sS]$)); then
        echo "⚠️ Hibernación no recomendada con RAM >64G, se mantiene SWAP mínimo"
    fi
fi

echo "Tamaño de SWAP recomendado: ${SWAP_MIN}G"

# ==========================================================
# ORDEN DE CREACIÓN: EFI -> SWAP -> ROOT -> HOME
# ==========================================================
# EFI
IS_UEFI=false
if [ -d /sys/firmware/efi ]; then
    IS_UEFI=true
fi
if $IS_UEFI; then
    read -p "¿Crear partición EFI de 300M? [S/n]: " EFI_ASK
    EFI_ASK=${EFI_ASK:-S}
    if [[ "$EFI_ASK" =~ ^[sS]$ ]]; then
        EFI_SIZE_RAW="300M"
        EFI_SIZE=0.3
        echo "✅ EFI: 300M"
    else
        EFI_SIZE=0
    fi
fi

# SWAP
while true; do
    read -p "Tamaño de SWAP (ej: ${SWAP_MIN}G, puedes ajustar): " SWAP_RAW
    SWAP_RAW=${SWAP_RAW:-${SWAP_MIN}G}
    SWAP_GIB=$(convert_to_gib "$SWAP_RAW")
    if (( SWAP_GIB < SWAP_MIN )); then
        echo "❌ Debe ser al menos ${SWAP_MIN}G para tu configuración de RAM/hibernación"
    else
        echo "✅ SWAP: ${SWAP_GIB}G"; break
    fi
done

# ROOT
total_used=$(( EFI_SIZE + SWAP_GIB ))
AVAILABLE_GIB=$(( DISK_GIB - total_used ))
while true; do
    read -p "Tamaño de ROOT (disp: ${AVAILABLE_GIB}G) (ej: 20G): " ROOT_RAW
    ROOT_GIB=$(convert_to_gib "$ROOT_RAW")
    if (( ROOT_GIB <= 0 || ROOT_GIB > AVAILABLE_GIB )); then
        echo "❌ Invalido. Usa 1-${AVAILABLE_GIB}G"
    else
        echo "✅ ROOT: ${ROOT_GIB}G"; break
    fi
done

# HOME opcional
total_used=$(( total_used + ROOT_GIB ))
AVAILABLE_GIB=$(( DISK_GIB - total_used ))
read -p "Crear /home? Espacio dispo: ${AVAILABLE_GIB}G [s/N]: " HOME_ASK
HOME_SIZE=0
if [[ "$HOME_ASK" =~ ^[sS]$ ]] && (( AVAILABLE_GIB > 0 )); then
    while true; do
        read -p "Tamaño de /home (1-${AVAILABLE_GIB}G): " HOME_RAW
        HOME_GIB=$(convert_to_gib "$HOME_RAW")
        if (( HOME_GIB <= 0 || HOME_GIB > AVAILABLE_GIB )); then
            echo "❌ Invalido"
        else
            HOME_SIZE=$HOME_GIB; echo "✅ /home: ${HOME_SIZE}G"; break
        fi
    done
else
    echo "ℹ️ /home incluido en ROOT"
fi

# ==========================================================
# RESUMEN FINAL
# ==========================================================
echo -e "\n== Resumen de particiones en $DISK =="
[[ $EFI_SIZE > 0 ]] && echo "EFI: 300M"
echo "SWAP: ${SWAP_GIB}G"
echo "ROOT: ${ROOT_GIB}G"
[[ $HOME_SIZE > 0 ]] && echo "/home: ${HOME_SIZE}G"
echo "Espacio libre: $(( DISK_GIB - EFI_SIZE - SWAP_GIB - ROOT_GIB - HOME_SIZE ))G"

read -p "Proceder con fdisk? [s/N]: " GO
if [[ ! "$GO" =~ ^[sS]$ ]]; then echo "Cancelado"; exit 1; fi

# ==========================================================
# CREAR PARTICIONES con fdisk
# ==========================================================
{
    # EFI
    if $IS_UEFI && (( EFI_SIZE > 0 )); then
        echo "g"      # GPT
        echo "n"; echo; echo; echo "+300M"  # EFI
        echo "t"; echo "1"
    else
        echo $([[ ! $IS_UEFI ]] && echo "o")
    fi
    # SWAP
    echo "n"; echo; echo; echo "+${SWAP_GIB}G"
    echo "t"; echo; echo "82"
    # ROOT
    echo "n"; echo; echo; echo "+${ROOT_GIB}G"
    # HOME
    if (( HOME_SIZE > 0 )); then
        echo "n"; echo; echo; echo "+${HOME_SIZE}G"
    fi
    echo "w"
} | fdisk "$DISK"

echo "✅ Particiones creadas con éxito."
