#!/usr/bin/env bash
#
# construir-iso-win11.sh
# Inserta un autounattend.xml en una ISO de Windows 11 desde Linux (Ubuntu)
# usando xorriso, conservando el arranque BIOS + UEFI intacto.
#
# Dependencias:  sudo apt install xorriso wimtools
#
# Uso:
#   ./construir-iso-win11.sh -i ORIGINAL.iso -a autounattend.xml -o SALIDA.iso [--split]
#
#   --split   Si install.wim supera 4 GB, lo trocea en .swm (<4 GB) y lo
#             sustituye en la ISO. Solo necesario para imagenes grandes.
#
# NOTA: prueba SIEMPRE la ISO resultante en una maquina virtual antes de
#       usarla en hardware real.
#
set -euo pipefail

ORIG=""; AUTO=""; OUT=""; SPLIT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i) ORIG="$2"; shift 2 ;;
    -a) AUTO="$2"; shift 2 ;;
    -o) OUT="$2";  shift 2 ;;
    --split) SPLIT=1; shift ;;
    *) echo "Argumento no reconocido: $1" >&2; exit 1 ;;
  esac
done

[[ -f "$ORIG" ]] || { echo "ERROR: no encuentro la ISO de origen: $ORIG" >&2; exit 1; }
[[ -f "$AUTO" ]] || { echo "ERROR: no encuentro el autounattend.xml: $AUTO" >&2; exit 1; }
[[ -n "$OUT"  ]] || { echo "ERROR: falta -o SALIDA.iso" >&2; exit 1; }
command -v xorriso >/dev/null || { echo "ERROR: instala xorriso (sudo apt install xorriso)" >&2; exit 1; }

echo ">> ISO origen : $ORIG"
echo ">> Answer file: $AUTO"
echo ">> ISO salida : $OUT"

# --- Comprobar tamano de install.wim dentro de la ISO -----------------------
WIM_PATH=""
for p in /sources/install.wim /sources/install.esd; do
  if xorriso -indev "$ORIG" -find "$p" >/dev/null 2>&1 \
     && xorriso -indev "$ORIG" -find "$p" 2>/dev/null | grep -q .; then
    WIM_PATH="$p"; break
  fi
done

WIM_MB=0
if [[ -n "$WIM_PATH" ]]; then
  WIM_BYTES=$(xorriso -indev "$ORIG" -lsl "$WIM_PATH" 2>/dev/null \
              | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){print $i; exit}}')
  WIM_MB=$(( ${WIM_BYTES:-0} / 1024 / 1024 ))
  echo ">> Imagen     : $WIM_PATH  (~${WIM_MB} MB)"
fi

# --- Caso simple: imagen <= ~4 GB o install.esd ----------------------------
if [[ "$SPLIT" -eq 0 || "$WIM_PATH" != "/sources/install.wim" || "$WIM_MB" -le 4000 ]]; then
  if [[ "$WIM_MB" -gt 4000 && "$WIM_PATH" == "/sources/install.wim" ]]; then
    echo "!! AVISO: install.wim supera 4 GB. Si la ISO resultante no arranca o"
    echo "          Setup no encuentra la imagen, relanza con --split." >&2
  fi
  echo ">> Construyendo (metodo replay, sin extraer)..."
  xorriso -indev "$ORIG" \
          -outdev "$OUT" \
          -boot_image any replay \
          -map "$AUTO" /autounattend.xml \
          -commit

else
  # --- Caso install.wim > 4 GB: trocear en .swm y sustituir ----------------
  command -v wimlib-imagex >/dev/null || { echo "ERROR: instala wimtools (sudo apt install wimtools)" >&2; exit 1; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  echo ">> Extrayendo install.wim..."
  xorriso -osirrox on -indev "$ORIG" -extract /sources/install.wim "$TMP/install.wim"
  echo ">> Troceando en .swm (<3800 MB por parte)..."
  wimlib-imagex split "$TMP/install.wim" "$TMP/install.swm" 3800

  MAPARGS=(-map "$AUTO" /autounattend.xml)
  for f in "$TMP"/install*.swm; do
    MAPARGS+=(-map "$f" "/sources/$(basename "$f")")
  done

  echo ">> Construyendo (replay + sustituyendo install.wim por .swm)..."
  xorriso -indev "$ORIG" \
          -outdev "$OUT" \
          -boot_image any replay \
          -rm /sources/install.wim -- \
          "${MAPARGS[@]}" \
          -commit
fi

# --- Verificacion -----------------------------------------------------------
echo
echo "=== Verificacion ==="
echo "- Arranque El Torito conservado:"
xorriso -indev "$OUT" -report_el_torito plain 2>/dev/null | grep -E "boot img|img path" || true
echo "- autounattend.xml en la raiz:"
xorriso -indev "$OUT" -find /autounattend.xml 2>/dev/null || echo "  (NO encontrado!)"
echo
echo ">> Listo: $OUT"
echo ">> Pruebalo en una VM (UEFI + TPM) antes de usarlo en hardware real."
