#!/bin/bash
set -e

clear
echo ">>> Instalador rápido e interactivo"
echo ">>> Este script solo formateará particiones existentes, no las creará."

read -p "¿Deseas continuar con el formateo? [s/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[sS]$ ]]; then
    echo "Cancelado por el usuario."
    exit 1
fi

# Detectar si es UEFI o BIOS
if [[ -d /sys/firmware/efi/efivars ]]; then
    IS_UEFI=1
    echo "Modo UEFI detectado."
else
    IS_UEFI=0
    echo "Modo BIOS detectado."
fi

# Listar particiones disponibles
echo "Particiones detectadas:"
lsblk -p -o NAME,SIZE,TYPE,MOUNTPOINT | grep part

# Función para desmontar si está montado
desmontar_si_montado() {
    local PART=$1
    MNT=$(lsblk -pno MOUNTPOINT "$PART" | grep -v '^$' || true)
    if [[ -n "$MNT" ]]; then
        echo "Desmontando $PART de $MNT..."
        umount -R "$PART"
    fi
}

# Pedir particiones
EFI_PART=""
if [[ $IS_UEFI -eq 1 ]]; then
    while true; do
        read -p "Partición EFI (ej: /dev/sda1): " EFI_PART
        [[ -b "$EFI_PART" ]] && break
        echo "Ruta no válida. Intenta de nuevo."
    done
    desmontar_si_montado "$EFI_PART"
fi

while true; do
    read -p "Partición raíz como btrfs (ej: /dev/sda2): " ROOT_PART
    [[ -b "$ROOT_PART" ]] && break
    echo "Ruta no válida. Intenta de nuevo."
done
desmontar_si_montado "$ROOT_PART"

read -p "¿Deseas formatear /home como xfs separado? [s/N]: " SEPARATE_HOME
HOME_PART=""
if [[ "$SEPARATE_HOME" =~ ^[sS]$ ]]; then
    while true; do
        read -p "Partición /home (ej: /dev/sda3): " HOME_PART
        [[ -b "$HOME_PART" ]] && break
        echo "Ruta no válida. Intenta de nuevo."
    done
    desmontar_si_montado "$HOME_PART"
fi

read -p "¿Deseas usar SWAP? [s/N]: " USE_SWAP
SWAP_PART=""
if [[ "$USE_SWAP" =~ ^[sS]$ ]]; then
    while true; do
        read -p "Partición SWAP (ej: /dev/sda4): " SWAP_PART
        [[ -b "$SWAP_PART" ]] && break
        echo "Ruta no válida. Intenta de nuevo."
    done
    desmontar_si_montado "$SWAP_PART"
fi

# Pedir hostname con confirmación doble
while true; do
    read -p "Nombre del equipo (hostname): " HOSTNAME
    read -p "Confirma el nombre del equipo (hostname): " HOSTNAME_CONFIRM
    if [[ "$HOSTNAME" == "$HOSTNAME_CONFIRM" && -n "$HOSTNAME" ]]; then
        break
    else
        echo "Los nombres no coinciden o están vacíos. Intenta de nuevo."
    fi
done

# Pedir usuario con confirmación doble
while true; do
    read -p "Nombre del usuario: " USERNAME
    read -p "Confirma el nombre del usuario: " USERNAME_CONFIRM
    if [[ "$USERNAME" == "$USERNAME_CONFIRM" && -n "$USERNAME" ]]; then
        break
    else
        echo "Los nombres no coinciden o están vacíos. Intenta de nuevo."
    fi
done

# Función para mostrar resumen
mostrar_resumen() {
    echo
    echo "=========================================="
    echo "Resumen de particiones y configuración:"
    echo "=========================================="
    if [[ $IS_UEFI -eq 1 ]]; then
        echo "EFI:       $EFI_PART"
    else
        echo "EFI:       No aplica (Modo BIOS)"
    fi
    echo "Root (btrfs): $ROOT_PART"
    if [[ -n "$HOME_PART" ]]; then
        echo "Home (xfs):   $HOME_PART"
    else
        echo "Home:         No separado"
    fi
    if [[ "$USE_SWAP" =~ ^[sS]$ ]]; then
        echo "SWAP:         $SWAP_PART"
    else
        echo "SWAP:         No"
    fi
    echo "Hostname:     $HOSTNAME"
    echo "Usuario:      $USERNAME"
    echo "=========================================="
    echo
}

# Mostrar resumen y pedir confirmación
mostrar_resumen

while true; do
    read -p "¿Confirmas que esta configuración es correcta para proceder con el formateo? [s/N]: " CONF
    if [[ "$CONF" =~ ^[sS]$ ]]; then
        break
    elif [[ "$CONF" =~ ^[nN]$ || -z "$CONF" ]]; then
        echo "Cancelado por el usuario."
        exit 1
    else
        echo "Por favor responde s (sí) o n (no)."
    fi
done

# Formateo de particiones
echo "Formateando particiones..."

if [[ $IS_UEFI -eq 1 && -n "$EFI_PART" ]]; then
    mkfs.fat -F32 "$EFI_PART"
fi

mkfs.btrfs "$ROOT_PART"

if [[ -n "$HOME_PART" ]]; then
    mkfs.xfs "$HOME_PART"
fi

if [[ "$USE_SWAP" =~ ^[sS]$ && -n "$SWAP_PART" ]]; then
    mkswap "$SWAP_PART"
    swapon "$SWAP_PART"
fi

echo "✅ Particiones formateadas."

# Montar sistema y crear puntos de montaje
echo "Montando sistema..."

mount "$ROOT_PART" /mnt

if [[ $IS_UEFI -eq 1 && -n "$EFI_PART" ]]; then
    mkdir -p /mnt/boot/efi
    mount "$EFI_PART" /mnt/boot/efi
fi

if [[ -n "$HOME_PART" ]]; then
    mkdir -p /mnt/home
    mount "$HOME_PART" /mnt/home
fi

echo "✅ Sistema montado en /mnt"

# Configurar hostname
echo "$HOSTNAME" > /etc/hostname

# Configuración de zona horaria automática
echo "Configurando zona horaria automáticamente..."
ZONE=$(curl -s https://ipapi.co/timezone)
if [[ -n "$ZONE" && -f "/usr/share/zoneinfo/$ZONE" ]]; then
    mkdir -p /mnt/etc
    ln -sf "/usr/share/zoneinfo/$ZONE" /mnt/etc/localtime
    echo "✅ Zona horaria configurada en $ZONE (enlazada en /mnt/etc/localtime)"
else
    echo "⚠️  No se pudo determinar o validar la zona horaria automáticamente."
fi

# Sincronizar reloj hardware
echo "Sincronizando reloj del sistema con hwclock..."
arch-chroot /mnt hwclock -w

# Crear usuario y dar permisos sudo
echo "Creando usuario '$USERNAME'..."
arch-chroot /mnt useradd -m -g users -G wheel -s /bin/bash "$USERNAME"
echo "Por favor, define la contraseña para el usuario $USERNAME:"
arch-chroot /mnt passwd "$USERNAME"

# Permitir sudo al grupo wheel
echo "Configurando permisos sudo para el grupo wheel..."
arch-chroot /mnt sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo "¡Configuración completada! Puedes continuar con la instalación."

# Configuración del arranque usando EFISTUB (solo UEFI)
if [[ $IS_UEFI -eq 1 ]]; then
    echo "Configurando arranque con EFISTUB..."

    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
    KERNEL_PATH="/boot/vmlinuz-linux"
    INITRD_PATH="/boot/initramfs-linux.img"

    if [[ -z "$ROOT_UUID" ]]; then
        echo "❌ No se pudo obtener UUID de $ROOT_PART"
        exit 1
    fi

    if [[ ! -f "/mnt/$KERNEL_PATH" || ! -f "/mnt/$INITRD_PATH" ]]; then
        echo "❌ No se encuentra el kernel o initramfs en /boot. Asegúrate de instalar el kernel antes de configurar EFISTUB."
    else
        arch-chroot /mnt efibootmgr --create \
            --disk "$(echo $EFI_PART | grep -o '^/dev/[a-z]*')" \
            --part "$(echo $EFI_PART | grep -o '[0-9]*$')" \
            --label "Arch Linux (EFISTUB)" \
            --loader "$KERNEL_PATH" \
            --unicode "root=UUID=$ROOT_UUID rw initrd=$INITRD_PATH" \
            --verbose

        echo "✅ EFISTUB configurado correctamente."
    fi
fi
