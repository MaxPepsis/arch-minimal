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
lsblk -p -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT | grep part

desmontar_si_montado() {
    local PART=$1
    MNT=$(lsblk -pno MOUNTPOINT "$PART" | grep -v '^$' || true)
    if [[ -n "$MNT" ]]; then
        if mountpoint -q "$MNT"; then
            echo "Desmontando $PART de $MNT..."
            umount -R "$MNT"
        fi
    fi
}

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

while true; do
    read -p "Nombre del equipo (hostname): " HOSTNAME
    read -p "Confirma el nombre del equipo (hostname): " HOSTNAME_CONFIRM
    if [[ "$HOSTNAME" == "$HOSTNAME_CONFIRM" && -n "$HOSTNAME" ]]; then
        break
    else
        echo "Los nombres no coinciden o están vacíos. Intenta de nuevo."
    fi

done

while true; do
    read -p "Nombre del usuario: " USERNAME
    read -p "Confirma el nombre del usuario: " USERNAME_CONFIRM
    if [[ "$USERNAME" == "$USERNAME_CONFIRM" && -n "$USERNAME" ]]; then
        break
    else
        echo "Los nombres no coinciden o están vacíos. Intenta de nuevo."
    fi

done

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

# Montar sistema
mount "$ROOT_PART" /mnt

if [[ $IS_UEFI -eq 1 && -n "$EFI_PART" ]]; then
    mkdir -p /mnt/boot/efi
    mount "$EFI_PART" /mnt/boot/efi
fi

if [[ -n "$HOME_PART" ]]; then
    mkdir -p /mnt/home
    mount "$HOME_PART" /mnt/home
fi

# Bind /dev /proc /sys
for dir in dev proc sys; do
    mount --bind "/$dir" "/mnt/$dir"
done

echo "✅ Sistema montado en /mnt"

# Generar fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Configurar hostname
echo "$HOSTNAME" > /mnt/etc/hostname

# Configurar zona horaria automatica
if command -v curl &>/dev/null; then
    echo "Configurando zona horaria automáticamente..."
    ZONE=$(curl -s https://ipapi.co/timezone)
    if [[ -n "$ZONE" && -f "/usr/share/zoneinfo/$ZONE" ]]; then
        ln -sf "/usr/share/zoneinfo/$ZONE" /mnt/etc/localtime
        echo "✅ Zona horaria configurada en $ZONE"
    else
        echo "⚠️  No se pudo determinar o validar la zona horaria."
    fi
else
    echo "⚠️  curl no está disponible. Zona horaria no configurada."
fi

# Sincronizar reloj
arch-chroot /mnt hwclock -w

# Crear usuario y sudo
arch-chroot /mnt useradd -m -g users -G wheel -s /bin/bash "$USERNAME"
echo "Por favor, define la contraseña para el usuario $USERNAME:"
arch-chroot /mnt passwd "$USERNAME"

arch-chroot /mnt sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo "✅ Usuario creado y sudo configurado."

# EFISTUB
if [[ $IS_UEFI -eq 1 ]]; then
    echo "Configurando arranque con EFISTUB..."
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

    if [[ -z "$ROOT_UUID" ]]; then
        echo "❌ No se pudo obtener UUID de $ROOT_PART"
        exit 1
    fi

    KERNEL_PATH="\vmlinuz-linux"
    INITRD_PATH="\initramfs-linux.img"

    if [[ -f "/mnt/boot/vmlinuz-linux" && -f "/mnt/boot/initramfs-linux.img" ]]; then
        DISK=$(echo $EFI_PART | grep -o '^/dev/[a-z]*')
        PART_NUM=$(echo $EFI_PART | grep -o '[0-9]*$')

        arch-chroot /mnt efibootmgr --create \
            --disk "$DISK" \
            --part "$PART_NUM" \
            --label "Arch Linux (EFISTUB)" \
            --loader "$KERNEL_PATH" \
            --unicode "root=UUID=$ROOT_UUID rw initrd=$INITRD_PATH" \
            --verbose

        echo "✅ EFISTUB configurado correctamente."
    else
        echo "❌ No se encuentra el kernel/initramfs. Instala el sistema base antes."
    fi
fi

echo "🎉 Instalación inicial completada. Puedes continuar con la instalación del sistema."

# Desmontar bind mounts
for dir in dev proc sys; do
    umount -l "/mnt/$dir"
done
