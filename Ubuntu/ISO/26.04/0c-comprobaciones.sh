echo "1. Ver qué procesos están corriendo en ese momento:"
ps axf | grep -E "(apt|dpkg|git|iac|bash)" --color=never
echo "2. Ver en qué función de kernel está bloqueado dpkg (el más útil):"
cat /proc/$(pgrep -f dpkg | head -1)/wchan 2>/dev/null

echo "3. Comprobar si hay locks de apt/dpkg activos:"
ls -la /var/lib/dpkg/lock* /var/lib/apt/lists/lock* 2>/dev/null
fuser /var/lib/dpkg/lock /var/lib/apt/lists/lock 2>/dev/null

echo "4. Ver si systemd está haciendo algo:"
systemctl status --no-pager | head -20
journalctl -n 30 --no-pager

echo "5. Ver los triggers dpkg pendientes:"
ls /var/lib/dpkg/triggers/