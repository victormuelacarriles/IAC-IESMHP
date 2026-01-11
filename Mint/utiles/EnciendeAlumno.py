import sys
import time
import socket
import struct
import subprocess
import platform
import getpass
from ldap3 import Server, Connection, ALL, NTLM

# --- CONFIGURACIÓN ---   (ver al final del fichero explicaciones)

# Matriz de datos: [Usuario, NombreEquipo, IP, MAC]
# Formato MAC: Acepta AA:BB:CC... o AA-BB-CC...
DATOS_USUARIOS = [
    ["SMRD01", "SMRD-00", "10.0.32.120", "bc:fc:e7:05:76:08", "Aaron"],
    ["SMRD05", "SMRD-04", "10.0.32.124", "bc:fc:e7:05:70:f8", "AlexandraPRUEBAS"],
    ["SMRV20", "SMRD-06", "10.0.32.126", "bc:fc:e7:04:bb:57", "Carlos"],
    ["SMRV02", "SMRD-07", "10.0.32.127", "bc:fc:e7:05:71:60", "Isabel"],
    ["SMRV05", "SMRD-10", "10.0.32.130", "bc:fc:e7:04:bc:ed", "Juan Manuel"],
    ["SMRV25", "SMRD-11", "10.0.32.131", "bc:fc:e7:05:73:47", "María Sandra"],
    ["SMRV07", "SMRD-12", "10.0.32.132", "bc:fc:e7:05:73:cc", "Jorge"],
    ["SMRV13", "SMRD-18", "10.0.32.138", "bc:fc:e7:05:73:d5", "Ignacio"],
    ["vmuela", "SMRD-18", "10.0.32.138", "74:56:3C:95:EA:81", "Victor"] # Ejemplo local
]

# Configuración del Dominio
DOMINIO = "iesmhp.local" # Cambiar por tu dominio
SERVIDOR_AD = "10.0.1.48" # IP del Controlador de Dominio

# --- FUNCIONES ---

def verificar_credenciales(usuario, password):
    """
    Verifica usuario y contraseña contra el Directorio Activo.
    """
    try:
        # Si no tienes un AD real para probar ahora, descomenta la siguiente línea:
        # return True 
        
        server = Server(SERVIDOR_AD, get_info=ALL)
        # Formato habitual: DOMINIO\usuario o usuario@dominio
        #user_dn = f"{DOMINIO}\\{usuario}" -----< Formato usado en NTLM, fallaba en SMRD
        user_dn = f"{usuario}@{DOMINIO}"
        
        conn = Connection(server, user=user_dn, password=password) #, authentication=NTLM)
        if conn.bind():
            conn.unbind()
            return True
        else:
            return False
    except Exception as e:
        print(f"[!] Error de conexión con el dominio: {e}")
        return False

def buscar_datos_usuario(usuario_input):
    """Busca el usuario en la matriz y devuelve sus datos."""
    for fila in DATOS_USUARIOS:
        if fila[0].lower() == usuario_input.lower():
            return fila # Retorna [User, Host, IP, MAC]
    return None

def hacer_ping(ip):
    """
    Realiza un ping al equipo.
    Detecta automáticamente si es Windows o Linux para usar el parámetro correcto.
    """
    param = '-n' if platform.system().lower() == 'windows' else '-c'
    # Timeout corto (1s) para que no bloquee mucho tiempo
    comando = ['ping', param, '1', ip]
    
    # stdout=subprocess.DEVNULL oculta la salida del ping en consola
    respuesta = subprocess.call(comando, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return respuesta == 0

def enviar_wol(mac_address):
    """
    Envía un paquete mágico (Wake-on-LAN) a la dirección MAC.
    Esto sustituye a la utilidad externa para mayor compatibilidad.
    """
    # Limpiar formato MAC
    mac_clean = mac_address.replace(":", "").replace("-", "")
    
    if len(mac_clean) != 12:
        raise ValueError("Dirección MAC incorrecta")

    data = bytes.fromhex('FF' * 6 + mac_clean * 16)
    
    # Enviar paquete broadcast
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.sendto(data, ("255.255.255.255", 9))

# --- FLUJO PRINCIPAL ---

def main():
    print("--- SISTEMA DE ARRANQUE REMOTO CORPORATIVO ---")
    
    # 1. Pedir usuario
    usuario_input = input("Introduzca su nombre de usuario de dominio: ").strip()
    
    # 2. Verificar si el usuario tiene equipo asignado antes de pedir pass (opcional, por seguridad)
    datos_equipo = buscar_datos_usuario(usuario_input)
    
    if not datos_equipo:
        print("[X] Error: El usuario no tiene un equipo asociado en la base de datos.")
        return

    nombre_equipo = datos_equipo[1]
    ip_equipo = datos_equipo[2]
    mac_equipo = datos_equipo[3]

    # 3. Pedir contraseña y verificar dominio
    password_input = getpass.getpass(f"Contraseña para {DOMINIO}\\{usuario_input}: ")
    
    print("\nVerificando credenciales...")
    if not verificar_credenciales(usuario_input, password_input):
        print("[X] Error: Contraseña incorrecta o error de dominio.")
        return

    print(f"[OK] Credenciales válidas. Equipo asociado: {nombre_equipo} ({ip_equipo})")

    # 4. Comprobar estado actual
    if hacer_ping(ip_equipo):
        print(f"[!] El equipo {nombre_equipo} ya está encendido y respondiendo.")
        return

    # 5. Encender equipo
    print(f"[...] El equipo está apagado. Enviando señal Wake-on-LAN a {mac_equipo}...")
    try:
        enviar_wol(mac_equipo)
        # Si prefieres usar la utilidad externa instalada, comenta la línea de arriba y usa:
        # subprocess.run(["wakeonlan", mac_equipo]) 
    except Exception as e:
        print(f"[X] Error enviando WoL: {e}")
        return

    # 6. Bucle de espera (Timeout 5 min = 300 seg)
    print("[...] Esperando arranque. Primera comprobación en 10 segundos.")
    time.sleep(10) # Espera inicial obligatoria
    
    tiempo_inicio = time.time()
    tiempo_maximo = 300 # 5 minutos
    
    while (time.time() - tiempo_inicio) < tiempo_maximo:
        print(f" -> Comprobando conectividad con {ip_equipo}...")
        
        if hacer_ping(ip_equipo):
            print("------------------------------------------------")
            print(f"[EXITO] El equipo {nombre_equipo} ya está disponible.")
            print("------------------------------------------------")
            return
        
        # Esperar 10 segundos para el siguiente intento
        time.sleep(10)

    # 7. Error por Timeout
    print("\n[X] Error: Tiempo de espera agotado (5 min).")
    print("    El equipo no ha respondido al ping. Verifique conexión eléctrica o red.")

if __name__ == "__main__":
    main()

# --- EXPLICACIONES DE CONFIGURACIÓN ---
# 1. DATOS_USUARIOS: Matriz con los datos de los usuarios y sus equipos.
#    Cada fila debe tener: [Usuario, NombreEquipo, IP, MAC, NombreReal]
#    Asegúrate de que las direcciones MAC estén en formato correcto (AA:BB:CC:DD:EE:FF o AA-BB-CC-DD-EE-FF).
# 2. Debe existir un usario en la máquina linux "alumno", sin password, que automáticamente ejecute este script al iniciar sesión.
#    ->Para ello
#      a) Crear usuario: sudo adduser alumno
#      b) Configurar para que no pida contraseña al iniciar sesión: 
#           1) sudo passwd -d alumno
#           2) sudo nano /etc/ssh/sshd_config
#              Añadir o modificar la línea: PermitEmptyPasswords yes
#              Luego reiniciar el servicio SSH: sudo systemctl restart ssh   (o sshd según distribución)
#      c) Configurar un entorno virtual para la ejecución del script
#         sudo -u alumno -i
#         python3 -m venv /home/alumno/venv
#         source /home/alumno/venv/bin/activate
#         pip install ldap3
#         pip install pycryptodome  # (si usas autenticación NTLM, sino no es necesario)
#         deactivate
#      c) Añadir al archivo .bashrc o .profile la ejecución automática de este script
                # Ejecutar EnciendeAlumno con el venv "env" al iniciar sesión
                # if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
                #     echo "Lanzando EnciendeAlumno..."
                #     # Navegamos a la carpeta raiz por seguridad
                #     cd ~
                #     # Ejecutamos usando el python del entorno virtual
                #     # No hace falta "activate", basta con llamar a su binario  (exec opcional: hace que se cierre sesión inmediatamente después)
                #     exec ~/venv/bin/python3 ~/EnciendeAlumno.py
                #     echo "Script finalizado. Sesión activa."
                # fi
#      d) Copiar el fichero EnciendeAlumno.py en /home/alumno/
             #cp /opt/IAC-IESMHP/utiles/EnciendeAlumno.py /home/alumno/