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
    mkfs.fat -F32 -n EFI "$EFI_PART"
fi

mkfs.btrfs -f "$ROOT_PART"

if [[ -n "$HOME_PART" ]]; then
    mkfs.xfs -f "$HOME_PART"
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

# ------------------ Seleccionar kernel ------------------
echo
echo "¿Qué kernel deseas instalar? Elige una opción:"
echo "1) linux         → Kernel estándar, estable y actualizado regularmente (uso general)"
echo "2) linux-lts     → Kernel con soporte a largo plazo (estabilidad prolongada)"
echo "3) linux-hardened→ Kernel reforzado en seguridad (entornos críticos)"
echo "4) linux-zen     → Kernel optimizado para rendimiento (ideal para gaming)"
echo "5) linux-rt      → Kernel en tiempo real (audio/video, robótica, ciencia)"
echo

while true; do
    read -p "Introduce el número de tu elección [1-5]: " KERNEL_CHOICE
    case $KERNEL_CHOICE in
        1) KERNEL_PKG="linux linux-headers"; break ;;
        2) KERNEL_PKG="linux-lts linux-lts-headers"; break ;;
        3) KERNEL_PKG="linux-hardened linux-hardened-headers"; break ;;
        4) KERNEL_PKG="linux-zen linux-zen-headers"; break ;;
        5) KERNEL_PKG="linux-rt linux-rt-headers"; break ;;
        *) echo "Opción inválida. Por favor elige un número del 1 al 5." ;;
    esac
done

echo "✅ Kernel seleccionado: $KERNEL_PKG"

# Instalar sistema base con kernel seleccionado
pacstrap /mnt base base-devel nano $KERNEL_PKG mkinitcpio linux-firmware btrfs-progs

# Crear puntos de montaje necesarios
mkdir -p /mnt/dev /mnt/proc /mnt/sys

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

# Crear usuario sin usar wheel
echo "Por favor, define la contraseña para el usuario $USERNAME:"
arch-chroot /mnt useradd -m -g users -s /bin/bash "$USERNAME"
arch-chroot /mnt passwd "$USERNAME"

# Configurar sudoers y pwfeedback
arch-chroot /mnt bash -c "
  if grep -q '^Defaults[[:space:]]*mail_badpass' /etc/sudoers; then
    sed -i '/^Defaults[[:space:]]*mail_badpass/s/\$/,\pwfeedback/' /etc/sudoers
    echo 'Se agregó ,pwfeedback a mail_badpass.'
  else
    echo 'No se encontró mail_badpass en /etc/sudoers.'
  fi

  if ! grep -q '^$USERNAME[[:space:]]*ALL=(ALL:ALL) ALL' /etc/sudoers; then
    sed -i "/^root[[:space:]]*ALL=(ALL:ALL) ALL/a $USERNAME       ALL=(ALL:ALL) ALL" /etc/sudoers
    echo 'Usuario $USERNAME añadido con permisos sudo.'
  else
    echo 'El usuario $USERNAME ya tiene permisos sudo.'
  fi
"

echo "✅ Usuario creado con sudo (sin usar grupo wheel)"

# Configurar arranque
if [[ $IS_UEFI -eq 1 ]]; then
    echo "Configurando arranque con EFISTUB..."
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

    if [[ -z "$ROOT_UUID" ]]; then
        echo "❌ No se pudo obtener UUID de $ROOT_PART"
        exit 1
    fi

    KERNEL_PATH="\\vmlinuz-linux"
    INITRD_PATH="\\initramfs-linux.img"

    if [[ -f "/mnt/boot/vmlinuz-linux" && -f "/mnt/boot/initramfs-linux.img" ]]; then
        DISK=$(echo $EFI_PART | grep -o '^/dev/[a-z]*')
        PART_NUM=$(echo $EFI_PART | grep -o '[0-9]*$')

        arch-chroot /mnt efibootmgr --create \
            --disk "$DISK" \
            --part "$PART_NUM" \
            --label "Arch Linux" \
            --loader "$KERNEL_PATH" \
            --unicode "root=UUID=$ROOT_UUID rw initrd=$INITRD_PATH" \
            --verbose

        echo "✅ EFISTUB configurado correctamente."
    else
        echo "❌ No se encuentra el kernel/initramfs. Instala el sistema base antes."
    fi

else
    echo "Configurando GRUB para BIOS..."
    arch-chroot /mnt pacman -Sy --noconfirm grub
    arch-chroot /mnt grub-install --target=i386-pc --recheck $(echo "$ROOT_PART" | grep -o '^/dev/[a-z]*')
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
    echo "✅ GRUB instalado en modo BIOS."
fi

# Desmontar bind mounts
for dir in dev proc sys; do
    umount -l "/mnt/$dir"
don
