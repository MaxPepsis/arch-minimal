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
        m) printf "%d" "$(echo "$num/1024" | bc)" ;; # MiB a GiB truncado
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
    echo "Cancelado por el usuario."
    exit 1
fi

# Mostrar lista de discos disponibles
echo "Discos disponibles:";
lsblk -d -p -o NAME,SIZE,MODEL,TYPE | grep disk

# Limpia completamente el disco al inicio
read -p "Introduce la ruta de tu disco (ej: /dev/sda): " DISK
if [[ ! -b "$DISK" ]]; then
    echo "❌ Disco inválido."; exit 1
fi

echo "🔴 Instalación limpia: borrando tabla de particiones existente"
sgdisk --zap-all "$DISK"

# Detectar UEFI y configurar EFISTUB automáticamente
IS_UEFI=false
EFI_SIZE=0
if [ -d /sys/firmware/efi ]; then
    IS_UEFI=true
    EFI_SIZE=1  # para cálculos
    echo "✅ Detectado UEFI: se creará partición EFI de 300MiB para EFISTUB"
else
    echo "ℹ️ Modo BIOS detectado: no se creará partición EFI"
fi

# Obtiene memoria y disco
MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo || echo 0)
MEM_GIB=$((MEM_KB/1024/1024))
DISK_GIB=$(( $(lsblk -b -n -d -o SIZE "$DISK") /1024/1024/1024 ))

echo "Disco: $DISK (${DISK_GIB}G) | RAM total: ${MEM_GIB}G"

# ==========================================================
# CALCULAR SWAP SEGÚN RAM E HIBERNACIÓN (OPCIONAL)
# ==========================================================
read -p "¿Deseas usar SWAP? [s/N]: " USE_SWAP
USE_SWAP=${USE_SWAP:-N}
SWAP_GIB=0
if [[ "$USE_SWAP" =~ ^[sS]$ ]]; then
    read -p "¿Vas a usar hibernación? [s/N]: " HIB
    HIB=${HIB:-N}
    if (( MEM_GIB < 2 )); then
        SWAP_MIN=$((MEM_GIB * 2))
        if [[ "$HIB" =~ ^[sS]$ ]]; then
            SWAP_MIN=$((MEM_GIB * 3))
        fi
    elif (( MEM_GIB < 8 )); then
        SWAP_MIN=$MEM_GIB
        if [[ "$HIB" =~ ^[sS]$ ]]; then
            SWAP_MIN=$((MEM_GIB * 2))
        fi
    elif (( MEM_GIB < 64 )); then
        SWAP_MIN=4
        if [[ "$HIB" =~ ^[sS]$ ]]; then
            SWAP_MIN=$(printf "%d" "$(echo "${MEM_GIB} * 1.5" | bc)")
        fi
    else
        SWAP_MIN=4
        if [[ "$HIB" =~ ^[sS]$ ]]; then
            echo "⚠️ Hibernación no recomendada con RAM >64G, se mantiene SWAP mínimo"
        fi
    fi
    # Asegurar mínimo de 2GiB si el cálculo resultara en <=2GiB
    if (( SWAP_MIN <= 2 )); then
        SWAP_MIN=$((MEM_GIB * 2))
        if (( SWAP_MIN <= 2 )); then
            SWAP_MIN=2
        fi
    fi
    echo "Tamaño de SWAP recomendado: ${SWAP_MIN}G"
    while true; do
        read -p "Tamaño de SWAP (ej: ${SWAP_MIN}G, puedes ajustar): " SWAP_RAW
        SWAP_RAW=${SWAP_RAW:-${SWAP_MIN}G}
        SWAP_GIB=$(convert_to_gib "$SWAP_RAW")
        if (( SWAP_GIB < SWAP_MIN )); then
            echo "❌ Debe ser al menos ${SWAP_MIN}G para tu configuración de RAM/hibernación"
        else
            echo "✅ SWAP: ${SWAP_GIB}G"
            break
        fi
    done
else
    echo "ℹ️ Omitiendo partición SWAP"
fi========
read -p "¿Deseas usar SWAP? [s/N]: " USE_SWAP
USE_SWAP=${USE_SWAP:-N}
SWAP_GIB=0
if [[ "$USE_SWAP" =~ ^[sS]$ ]]; then
    read -p "¿Vas a usar hibernación? [s/N]: " HIB
    HIB=${HIB:-N}
    if (( MEM_GIB < 2 )); then
        SWAP_MIN=$((MEM_GIB*2))
        if [[ "$HIB" =~ ^[sS]$ ]]; then
            SWAP_MIN=$((MEM_GIB*3))
        fi
    elif (( MEM_GIB < 8 )); then
        SWAP_MIN=$MEM_GIB
        if [[ "$HIB" =~ ^[sS]$ ]]; then
            SWAP_MIN=$((MEM_GIB*2))
        fi
    elif (( MEM_GIB < 64 )); then
        SWAP_MIN=4
        if [[ "$HIB" =~ ^[sS]$ ]]; then
            SWAP_MIN=$(printf "%d" "$(echo "${MEM_GIB}*1.5" | bc)")
        fi
    else
        SWAP_MIN=4
        if [[ "$HIB" =~ ^[sS]$ ]]; then
            echo "⚠️ Hibernación no recomendada con RAM >64G, se mantiene SWAP mínimo"
        fi
    fi
    echo "Tamaño de SWAP recomendado: ${SWAP_MIN}G"
    while true; do
        read -p "Tamaño de SWAP (ej: ${SWAP_MIN}G, puedes ajustar): " SWAP_RAW
        SWAP_RAW=${SWAP_RAW:-${SWAP_MIN}G}
        SWAP_GIB=$(convert_to_gib "$SWAP_RAW")
        if (( SWAP_GIB < SWAP_MIN )); then
            echo "❌ Debe ser al menos ${SWAP_MIN}G para tu configuración de RAM/hibernación"
        else
            echo "✅ SWAP: ${SWAP_GIB}G"
            break
        fi
    done
else
    echo "ℹ️ Omitiendo partición SWAP"
fi

# ==========================================================
# ORDEN DE CREACIÓN: EFI -> SWAP -> ROOT -> HOME
# ==========================================================
# ROOT
USED=$(( EFI_SIZE + SWAP_GIB ))
AVAILABLE_GIB=$(( DISK_GIB - USED ))
while true; do
    read -p "Tamaño de ROOT (disp: ${AVAILABLE_GIB}G) (ej: 20G): " ROOT_RAW
    ROOT_GIB=$(convert_to_gib "$ROOT_RAW")
    if (( ROOT_GIB <= 0 || ROOT_GIB > AVAILABLE_GIB )); then
        echo "❌ Inválido. Usa 1-${AVAILABLE_GIB}G"
    else
        echo "✅ ROOT: ${ROOT_GIB}G"
        break
    fi
done

# HOME opcional
USED=$(( USED + ROOT_GIB ))
AVAILABLE_GIB=$(( DISK_GIB - USED ))
read -p "Crear /home? Espacio dispo: ${AVAILABLE_GIB}G [s/N]: " HOME_ASK
HOME_SIZE=0
if [[ "$HOME_ASK" =~ ^[sS]$ ]] && (( AVAILABLE_GIB > 0 )); then
    while true; do
        read -p "Tamaño de /home (1-${AVAILABLE_GIB}G): " HOME_RAW
        HOME_GIB=$(convert_to_gib "$HOME_RAW")
        if (( HOME_GIB <= 0 || HOME_GIB > AVAILABLE_GIB )); then
            echo "❌ Inválido"
        else
            HOME_SIZE=$HOME_GIB
            echo "✅ /home: ${HOME_SIZE}G"
            break
        fi
    done
else
    echo "ℹ️ /home incluido en ROOT"
fi

# ==========================================================
# RESUMEN FINAL
# ==========================================================
echo -e "\n== Resumen de particiones en $DISK =="
if (( EFI_SIZE > 0 )); then echo "EFI: 300M"; fi
if [[ "$USE_SWAP" =~ ^[sS]$ ]]; then echo "SWAP: ${SWAP_GIB}G"; fi
echo "ROOT: ${ROOT_GIB}G"
if (( HOME_SIZE > 0 )); then echo "/home: ${HOME_SIZE}G"; fi
echo "Espacio libre: $(( DISK_GIB - EFI_SIZE - SWAP_GIB - ROOT_GIB - HOME_SIZE ))G"

read -p "Proceder con fdisk? [s/N]: " GO
if [[ ! "$GO" =~ ^[sS]$ ]]; then
    echo "Cancelado"; exit 1
fi

# ==========================================================
# CREAR PARTICIONES con fdisk
# ==========================================================
{
    # EFI
    if (( EFI_SIZE > 0 )); then
        echo "g"
        echo "n"; echo; echo; echo "+300M"
        echo "t"; echo "1"
    else
        echo $([[ ! $IS_UEFI ]] && echo "o")
    fi
    # SWAP
    if [[ "$USE_SWAP" =~ ^[sS]$ ]]; then
        echo "n"; echo; echo; echo "+${SWAP_GIB}G"
        echo "t"; echo; echo "82"
    fi
    # ROOT
    echo "n"; echo; echo; echo "+${ROOT_GIB}G"
    # HOME
    if (( HOME_SIZE > 0 )); then
        echo "n"; echo; echo; echo "+${HOME_SIZE}G"
    fi
    echo "w"
} | fdisk "$DISK"

echo "✅ Particiones creadas con éxito."
