#Ver en claude el proceso  (Solo vmuela)
#https://claude.ai/share/ef728452-b05c-4f13-85db-1e9cbaa5e5a8


#Para generar una iso autorrancable (que permite hacer instalaciones desde red)

#1-Preparar la carpeta en Ubuntu
cd ~/Descargas
mkdir -p ~/usb-nfs/{EFI,.disk,boot/grub,live/img1}

# Cargador UEFI firmado (usa la ISO de Ubuntu más reciente)
sudo mkdir -p /mnt/iso
sudo mount -o loop,ro ubuntu-26.04-desktop-amd64.iso /mnt/iso
cp -r /mnt/iso/EFI/. ~/usb-nfs/EFI/
cp /mnt/iso/.disk/info ~/usb-nfs/.disk/
sudo umount /mnt/iso
chmod -R u+w ~/usb-nfs
ls ~/usb-nfs/EFI/boot    # deben aparecer bootx64.efi, grubx64.efi y mmx64.efi



#Kernel e init de cada recurso (es el mismo para todos)
sudo mkdir -p /mnt/nfs
sudo mount -t nfs -o ro,vers=3 10.0.72.253:/mnt/DiscosRapidos/LiveCDs/Ubuntu26.04-IESMHP /mnt/nfs
cp /mnt/nfs/casper/vmlinuz /mnt/nfs/casper/initrd ~/usb-nfs/live/img1/
sudo umount /mnt/nfs
sudo rm -rf /mnt/nfs


#Creamos ~/usb-nfs/boot/grub/grub.cfg
if [ "$grub_platform" != "efi" ]; then
  echo "ERROR: este USB solo funciona en modo UEFI."
  echo "Desactive el modo Legacy/CSM en la configuración del equipo."
  echo "El equipo se apagará en 30 segundos."
  sleep 30
  halt
fi

set timeout=10
set default=0

menuentry "Desde IABD-20 (10.0.72.140:/srv/ubuntu-live)" {
  linux /live/img1/vmlinuz boot=casper netboot=nfs nfsroot=10.0.72.140:/srv/ubuntu-live ip=dhcp quiet splash
  initrd /live/img1/initrd
}
menuentry "Desde NAS IABD(10.0.72.253:/srv/ubuntu-live)" {
  linux /live/img1/vmlinuz boot=casper netboot=nfs nfsroot=10.0.72.253:/mnt/DiscosRapidos/LiveCDs/Ubuntu26.04-IESMHP ip=dhcp quiet splash
  initrd /live/img1/initrd
}

menuentry "Desde NAS SMRV(10.0.32.253:/srv/ubuntu-live)" {
  linux /live/img1/vmlinuz boot=casper netboot=nfs nfsroot=10.0.32.253:/mnt/DiscosRapidos/LiveCDs/Ubuntu26.04-IESMHP ip=dhcp quiet splash
  initrd /live/img1/initrd
}

menuentry "Desde NAS Centro(10.0.1.253:/srv/ubuntu-live)" {
  linux /live/img1/vmlinuz boot=casper netboot=nfs nfsroot=10.0.1.253:/mnt/DiscosRapidos/LiveCDs/Ubuntu26.04-IESMHP ip=dhcp quiet splash
  initrd /live/img1/initrd
}


#Creamos la ISO para probar desde maquina virtual 
./crea-iso-arranque-nfs.sh ~/usb-nfs InstalaciónDesdeRed.iso

