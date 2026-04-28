#!/usr/bin/env bash
# =============================================================================
#  0a-CreaISO.sh
#  Genera una ISO de Ubuntu Desktop personalizada con instalación automática UEFI.
#
#  Uso:
#    ./0a-CreaISO.sh <iso_origen> <0b-Github.sh> [iso_salida]
#
#  ARQUITECTURA:
#    El autoinstall de Ubuntu solo actúa como disparador de arranque:
#    early-commands lanza 0b-Github.sh, que clona el repo y ejecuta
#    1-SetupLiveCD.sh (instalación completa manual desde el entorno live).
#    Subiquity nunca particiona ni instala nada por su cuenta.
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# PARÁMETROS Y VARIABLES
# ─────────────────────────────────────────────────────────────────────────────
SOURCE_ISO="${1:?ERROR: Debes indicar la ISO de origen.
  Uso: $0 <iso_origen> <0b-Github.sh> [iso_salida]}"
PERSO_SCRIPT="${2:?ERROR: Debes indicar el script de personalización (0b-Github.sh).}"
OUTPUT_ISO="${3:-ubuntu-custom-desktop-uefi.iso}"

WORK_DIR="$(mktemp -d /tmp/iso_build_XXXXXX)"
ISO_DIR="${WORK_DIR}/iso"
AUTOINSTALL_DIR="${ISO_DIR}/autoinstall"

# ─────────────────────────────────────────────────────────────────────────────
# COLORES Y LIMPIEZA
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()   { echo -e "${GREEN}[+]${NC} $*"; }
info()  { echo -e "${CYAN}[i]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
step()  { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

cleanup() {
    log "Limpiando directorio temporal: ${WORK_DIR}"
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# 0. VERIFICACIONES
# ─────────────────────────────────────────────────────────────────────────────
check_deps() {
    step "Verificando dependencias"
    local missing=()
    for dep in xorriso mtools file openssl sfdisk; do
        if command -v "$dep" &>/dev/null; then
            log "  $dep → OK"
        else
            missing+=("$dep")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Faltan dependencias: ${missing[*]}\n  Instálalas con: sudo apt install util-linux ${missing[*]}"
    fi
}

check_inputs() {
    step "Verificando ficheros de entrada"
    [[ -f "$SOURCE_ISO" ]]    || err "No se encuentra la ISO: ${SOURCE_ISO}"
    [[ -f "$PERSO_SCRIPT" ]]  || err "No se encuentra el script: ${PERSO_SCRIPT}"
    if [[ "$(realpath "$SOURCE_ISO")" == "$(realpath "$OUTPUT_ISO")" ]]; then
        err "La ISO de origen y la de salida son el mismo fichero."
    fi
    log "ISO origen   : ${SOURCE_ISO}"
    log "0b-Github.sh     : ${PERSO_SCRIPT}"
    log "ISO salida   : ${OUTPUT_ISO}"
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. EXTRAER ISO
# ─────────────────────────────────────────────────────────────────────────────
extract_iso() {
    step "Extrayendo ISO → ${ISO_DIR}"
    mkdir -p "${ISO_DIR}"
    xorriso -osirrox on -indev "$SOURCE_ISO" -extract / "${ISO_DIR}" 2>/dev/null || err "xorriso falló al extraer."
    chmod -R u+w "${ISO_DIR}"
    log "Extracción completada"
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. AÑADIR 0b-Github.sh A LA ISO
# ─────────────────────────────────────────────────────────────────────────────
copy_perso_script() {
    step "Añadiendo 0b-Github.sh a /autoinstall/ en la ISO"
    mkdir -p "${AUTOINSTALL_DIR}"
    cp "$PERSO_SCRIPT" "${AUTOINSTALL_DIR}/0b-Github.sh"
    chmod +x "${AUTOINSTALL_DIR}/0b-Github.sh"
    log "0b-Github.sh copiado en ${AUTOINSTALL_DIR}/0b-Github.sh"
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. GENERAR user-data Y meta-data
#
#    CAMBIO respecto a la versión anterior:
#    ► Se elimina la sección "storage" (lvm): la partición la realiza
#      1-SetupLiveCD.sh, que es lanzado por 0b-Github.sh.
#    ► Se elimina la sección "identity": la crea 2-SetupSOdesdeLiveCD.sh
#      en el chroot.
#    ► Se sustituye "late-commands" por "early-commands": el autoinstall
#      de Ubuntu solo sirve para arrancar el entorno live y lanzar 0b-Github.sh.
#      Subiquity nunca llega a particionar ni a instalar el sistema base.
# ─────────────────────────────────────────────────────────────────────────────
generate_user_data() {
    step "Generando user-data — early-command → 0b-Github.sh"

    cat > "${AUTOINSTALL_DIR}/user-data" << 'EOF'
#cloud-config
autoinstall:
  version: 1
  locale: es_ES.UTF-8
  keyboard:
    layout: es
    variant: ""
  # early-commands se ejecutan en el entorno live ANTES de que Subiquity
  # toque los discos. 0b-Github.sh clona el repo y lanza 1-SetupLiveCD.sh,
  # que realiza la instalación completa y reinicia. Subiquity no continúa.
  early-commands:
    - bash /cdrom/autoinstall/0b-Github.sh
EOF
    touch "${AUTOINSTALL_DIR}/meta-data"
    log "user-data (early-command) y meta-data generados"
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. CONFIGURAR GRUB PARA ARRANQUE AUTOMÁTICO
# ─────────────────────────────────────────────────────────────────────────────
configure_grub() {
    step "Configurando GRUB para arranque automático (Desktop)"
    local grub_cfg="${ISO_DIR}/boot/grub/grub.cfg"

    if [[ ! -f "$grub_cfg" ]]; then
        grub_cfg=$(find "${ISO_DIR}" -name "grub.cfg" | head -1)
        [[ -z "$grub_cfg" ]] && err "No se encontró grub.cfg en la ISO."
    fi

    cp "$grub_cfg" "${grub_cfg}.orig"
    cat > "$grub_cfg" << 'GRUBEOF'
set default=0
set timeout=5
set timeout_style=countdown
set gfxpayload=text

menuentry "Ubuntu Desktop — Instalación automatizada (IAC-IESMHP)" --id=autoinstall {
    linux   /casper/vmlinuz \
                autoinstall \
                "ds=nocloud;s=/cdrom/autoinstall/" \
                quiet splash \
                ---
    initrd  /casper/initrd
}
menuentry "Ubuntu Desktop — Live / Interactivo (Debug)" --id=interactive {
    linux   /casper/vmlinuz \
                quiet splash \
                ---
    initrd  /casper/initrd
}
GRUBEOF
    log "GRUB configurado."
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. ELIMINAR BIOS/LEGACY BOOT
# ─────────────────────────────────────────────────────────────────────────────
remove_bios_boot() {
    step "Eliminando componentes BIOS/Legacy"
    
    if [[ -d "${ISO_DIR}/isolinux" ]]; then
        rm -rf "${ISO_DIR}/isolinux"
        log "  isolinux/ eliminado"
    fi
    
    if [[ -d "${ISO_DIR}/boot/grub/i386-pc" ]]; then
        rm -rf "${ISO_DIR}/boot/grub/i386-pc"
        log "  boot/grub/i386-pc/ eliminado"
    fi
    
    if [[ -f "${ISO_DIR}/boot/grub/boot_hybrid.img" ]]; then
        rm -f "${ISO_DIR}/boot/grub/boot_hybrid.img"
        log "  boot_hybrid.img eliminado"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. OBTENER PARÁMETROS EFI (VERSIÓN ROBUSTA sfdisk)
# ─────────────────────────────────────────────────────────────────────────────
get_efi_boot_params() {
    step "Leyendo parámetros EFI de la ISO original"
    EFI_PARAMS=$(xorriso -indev "$SOURCE_ISO" -report_el_torito as_mkisofs 2>/dev/null || true)
    EFI_IMG_PATH=$(echo "$EFI_PARAMS" | grep -oP '(?<=-e\s|--efi-boot\s|--interval:appended_partition)\S+' | head -1 || true)

    USE_APPENDED_PARTITION=false
    if echo "$EFI_PARAMS" | grep -q "appended_partition"; then
        USE_APPENDED_PARTITION=true
    fi

    if xorriso -osirrox on -indev "$SOURCE_ISO" -extract /boot/grub/efi.img "${WORK_DIR}/efi.img" 2>/dev/null; then
        EFI_IMG_FILE="${WORK_DIR}/efi.img"
        log "efi.img extraído exitosamente desde la ruta interna."
    else
        local appended_file
        appended_file=$(echo "$EFI_PARAMS" | grep -oP '(?<=-append_partition 2 [a-f0-9-]+ )\S+' | head -1 || true)
        
        if [[ -n "$appended_file" ]] && xorriso -osirrox on -indev "$SOURCE_ISO" -extract "$appended_file" "${WORK_DIR}/efi.img" 2>/dev/null; then
            EFI_IMG_FILE="${WORK_DIR}/efi.img"
            log "Partición adjunta EFI extraída exitosamente con xorriso."
        else
            warn "xorriso falló. Extrayendo sectores a bajo nivel con sfdisk+dd..."
            local part_info
            part_info=$(sfdisk -d "$SOURCE_ISO" 2>/dev/null | grep -i -E 'type=ef|type=C12A7328' | head -1)
            
            if [[ -n "$part_info" ]]; then
                local efi_start efi_size
                efi_start=$(echo "$part_info" | grep -oP 'start=\s*\K[0-9]+')
                efi_size=$(echo "$part_info" | grep -oP 'size=\s*\K[0-9]+')
                
                if [[ -n "$efi_start" ]] && [[ -n "$efi_size" ]]; then
                    dd if="$SOURCE_ISO" of="${WORK_DIR}/efi.img" bs=512 skip="$efi_start" count="$efi_size" 2>/dev/null
                    EFI_IMG_FILE="${WORK_DIR}/efi.img"
                    log "EFI extraído vía sfdisk+dd (Inicio: ${efi_start}, Sectores: ${efi_size})."
                else
                    err "sfdisk localizó la partición pero no se pudieron calcular los sectores."
                fi
            else
                err "sfdisk no pudo encontrar ninguna partición EFI en la ISO de origen."
            fi
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. REEMPAQUETAR ISO UEFI
# ─────────────────────────────────────────────────────────────────────────────
repack_iso() {
    step "Reempaquetando ISO UEFI → ${OUTPUT_ISO}"
    [[ -f "$OUTPUT_ISO" ]] && rm -f "$OUTPUT_ISO"

    if [[ "$USE_APPENDED_PARTITION" == "true" ]]; then
        local EFI_PART_TYPE="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
        xorriso -as mkisofs -r -V "UBUNTU_CUSTOM_DESKTOP" -o "${OUTPUT_ISO}" \
            --no-pad -J --joliet-long -rational-rock -partition_offset 16 \
            -appended_part_as_gpt -append_partition 2 "${EFI_PART_TYPE}" "${EFI_IMG_FILE}" \
            -e "--interval:appended_partition_2:::" -no-emul-boot "${ISO_DIR}" \
        || err "Fallo en xorriso (modo GPT)."
    else
        local efi_rel
        efi_rel=$(realpath --relative-to="${ISO_DIR}" "${ISO_DIR}/boot/grub/efi.img" 2>/dev/null || echo "boot/grub/efi.img")
        xorriso -as mkisofs -r -V "UBUNTU_CUSTOM_DESKTOP" -o "${OUTPUT_ISO}" \
            --no-pad -J --joliet-long -rational-rock -e "${efi_rel}" -no-emul-boot \
            -boot-load-size 4 -boot-info-table --efi-boot "${efi_rel}" \
            -efi-boot-part --efi-boot-image "${ISO_DIR}" \
        || err "Fallo en xorriso (modo El Torito)."
    fi

    log "ISO completada: ${OUTPUT_ISO} ($(du -sh "${OUTPUT_ISO}" | cut -f1))"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    check_deps
    check_inputs
    extract_iso
    copy_perso_script
    generate_user_data
    configure_grub
    remove_bios_boot
    get_efi_boot_params
    repack_iso

    echo -e "${GREEN}✓ ISO Desktop lista: ${OUTPUT_ISO}${NC}"
}

main "$@"