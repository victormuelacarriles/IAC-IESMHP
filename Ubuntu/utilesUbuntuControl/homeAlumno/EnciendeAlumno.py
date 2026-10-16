import sys
import time
import socket
import struct
import subprocess
import platform
import getpass
import ipaddress
from ldap3 import Server, Connection, ALL, NTLM

VERSION="2026.10.16 14:30"  # WoL por broadcast dirigido a la red destino (antes 255.255.255.255)

# --- CONFIGURACIÓN ---   (ver al final del fichero explicaciones)
# Matriz de datos: [Usuario, NombreEquipo, IP, MAC]
# Formato MAC: Acepta AA:BB:CC... o AA-BB-CC...
DATOS_USUARIOS = [
    ###################################################################### Profesores Distancia
    ["malava", "SMRD-14", "10.0.32.134", "bc:fc:e7:05:73:63", "Belén Álava", "P"],
    ["afernandez", "SMRD-11", "10.0.32.131", "bc:fc:e7:05:73:47", "Angélica Fernandez", "P"],
    ["rmachog", "SMRD-15", "10.0.32.135", "bc:fc:e7:05:73:c8", "Roberto Macho", "P"],
    ["vmuela", "SMRD-18", "10.0.32.138", "bc:fc:e7:05:73:d5", "Víctor Muela", "P"],
    ["luis", "SMRD-16", "10.0.32.136", "bc:fc:e7:04:30:c0", "Luis M. Velázquez", "P"],
    ###################################################################### Alumnos Distancia
    ["SMRV08", "SMRD-10", "10.0.32.130", "bc:fc:e7:04:bc:ed", "Cristian David Abad Ochoa", "A"],
    ["SMRV28", "SMRD-15", "10.0.32.135", "bc:fc:e7:05:73:c8", "Aingeru Arranz Parra", "A"],
    ["SMRV31", "SMRD-04", "10.0.32.124", "bc:fc:e7:05:70:f8", "María Rosario Callirgos Ruiz", "A"],
    ["SMRV06", "SMRD-07", "10.0.32.127", "bc:fc:e7:05:71:60", "Isabel Campos Ortega", "A"],
    ["SMRV30", "SMRD-06", "10.0.32.126", "bc:fc:e7:04:bb:57", "Román Carral Lavín", "A"],
    ["SMRV04", "SMRD-10", "10.0.32.130", "bc:fc:e7:04:bc:ed", "Luis Cue Galán", "A"],
    ["SMRV11", "SMRD-11", "10.0.32.131", "bc:fc:e7:05:73:47", "Gael Da Silva Rivas", "A"],
    ["SMRV22", "SMRD-13", "10.0.32.133", "bc:fc:e7:05:75:7e", "Sandra Díaz García", "A"],
    ["SMRV39", "SMRD-05", "10.0.32.125", "bc:fc:e7:05:71:4a", "Ainara  Erkiaga Silva", "A"],
    ["SMRV21", "SMRD-08", "10.0.32.128", "bc:fc:e7:05:72:e9", "José Antonio Fernández Del Río", "A"],
    ["SMRV15", "SMRD-07", "10.0.32.127", "bc:fc:e7:05:71:60", "Miguel Figaredo Campos", "A"],
    ["SMRV17", "SMRD-03", "10.0.32.123", "bc:fc:e7:05:72:58", "Daniel Fuente Luque", "A"],
    ["SMRV35", "SMRD-07", "10.0.32.127", "bc:fc:e7:05:71:60", "Enrique García Díaz", "A"],
    ["SMRV18", "SMRD-09", "10.0.32.129", "bc:fc:e7:05:72:9a", "Pablo González Trueba", "A"],
    ["SMRV33", "SMRD-16", "10.0.32.136", "bc:fc:e7:04:30:c0", "Daniel González Vega", "A"],
    ["SMRV38", "SMRD-03", "10.0.32.123", "bc:fc:e7:05:72:58", "Juan Manuel Gutierrez Batalla", "A"],
    ["SMRV02", "SMRD-18", "10.0.32.138", "bc:fc:e7:05:73:d5", "María Jesús Gutiérrez Cacho", "A"],
    ["SMRV24", "SMRD-04", "10.0.32.124", "bc:fc:e7:05:70:f8", "Daniel Gutiérrez Castro", "A"],
    ["SMRV34", "SMRD-08", "10.0.32.128", "bc:fc:e7:05:72:e9", "Óscar Gutiérrez López", "A"],
    ["SMRV13", "SMRD-08", "10.0.32.128", "bc:fc:e7:05:72:e9", "Lara Haya Álvarez", "A"],
    ["SMRV29", "SMRD-00", "10.0.32.120", "bc:fc:e7:05:76:08", "Aránzazu del Amor Illán Gutiérrez", "A"],
    ["SMRV10", "SMRD-01", "10.0.32.121", "08:bf:b8:40:09:82", "Ander Iñurrieta Cabrera", "A"],
    ["SMRV12", "SMRD-02", "10.0.32.122", "bc:fc:e7:05:73:d1", "Iván Koriak", "A"],
    ["SMRV03", "SMRD-05", "10.0.32.125", "bc:fc:e7:05:71:4a", "Alicia Leñero Gutiérrez", "A"],
    ["SMRV19", "SMRD-03", "10.0.32.123", "bc:fc:e7:05:72:58", "Fidel Licona Soria", "A"],
    ["SMRV23", "SMRD-00", "10.0.32.120", "bc:fc:e7:05:76:08", "Eliab Luevanos Espinoza", "A"],
    ["SMRV25", "SMRD-09", "10.0.32.129", "bc:fc:e7:05:72:9a", "Miguel Mantecón Coterillo", "A"],
    ["SMRV16", "SMRD-00", "10.0.32.120", "bc:fc:e7:05:76:08", "Ibai Mantilla Cuesta", "A"],
    ["SMRV36", "SMRD-04", "10.0.32.124", "bc:fc:e7:05:70:f8", "Borja Martínez Echevarría", "A"],
    ["SMRV37", "SMRD-02", "10.0.32.122", "bc:fc:e7:05:73:d1", "Victoria Ocejo Leira", "A"],
    ["SMRV05", "SMRD-14", "10.0.32.134", "bc:fc:e7:05:73:63", "Natalija Pankratjeva", "A"],
    ["SMRV07", "SMRD-06", "10.0.32.126", "bc:fc:e7:04:bb:57", "Jairo Pérez Pérez", "A"],
    ["SMRV01", "SMRD-13", "10.0.32.133", "bc:fc:e7:05:75:7e", "Daniel Karol Przygoda", "A"],
    ["SMRV20", "SMRD-01", "10.0.32.121", "08:bf:b8:40:09:82", "Mayra Alejandra Ruiz Fernandez", "A"],
    ["SMRV14", "SMRD-10", "10.0.32.130", "bc:fc:e7:04:bc:ed", "Cristina Sánchez Gutiérrez", "A"],
    ["SMRV27", "SMRD-02", "10.0.32.122", "bc:fc:e7:05:73:d1", "Daniel Santamaría Vallina", "A"],
    ["SMRV32", "SMRD-05", "10.0.32.125", "bc:fc:e7:05:71:4a", "Jonatan Torrejón Asencio", "A"],
    ["SMRV09", "SMRD-06", "10.0.32.126", "bc:fc:e7:04:bb:57", "Olga Vidal Obispo", "A"],
    ["SMRV26", "SMRD-01", "10.0.32.121", "08:bf:b8:40:09:82", "Jorge Zaton Pérez", "A"],

    ########################################################################################## Alumnos CEIABD
    ["CEGSIABD09","IABD-01", "10.0.72.121", "d8:bb:c1:38:71:6f", "Canales De la Hera, María del Carmen","A"],
    ["CEGSIABD04","IABD-02", "10.0.72.122", "d8:bb:c1:38:93:ad", "Carcedo Ruiz, Diego","A"],
    ["CEGSIABD16","IABD-03", "10.0.72.123", "d8:bb:c1:38:94:25", "Coterillo González, Alberto","A"],
    ["CEGSIABD12","IABD-04", "10.0.72.124", "d8:bb:c1:38:93:a2", "Díez Torres, Manuel Enrique","A"],
    ["CEGSIABD11","IABD-06", "10.0.72.126", "d8:bb:c1:38:94:69", "González Collantes, Rodrigo Alberto","A"],
    ["CEGSIABD15","IABD-07", "10.0.72.127", "d8:bb:c1:38:93:e8", "González Hoyos, Rodrigo","A"],
    ["CEGSIABD19","IABD-09", "10.0.72.129", "d8:bb:c1:38:93:ae", "González Tresgallo, Bruno","A"],
    ["CEGSIABD02","IABD-10", "10.0.72.130", "74:56:3C:65:62:C6", "Fuentes Cobo, Carlos","A"],
    ["CEGSIABD10","IABD-12", "10.0.72.132", "74:56:3C:65:60:7F", "Llano Rebanal, Manuel","A"],
    ["CEGSIABD13","IABD-14", "10.0.72.134", "74:56:3C:95:ED:21", "Palacio Cobo, Pablo","A"],
    ["CEGSIABD17","IABD-16", "10.0.72.136", "74:56:3C:95:EC:10", "Pérez Castro, Javier","A"],
    ["CEGSIABD08","IABD-18", "10.0.72.138", "74:56:3C:95:EA:81", "San Juan Rodrigo, Álvaro","A"],
    ["CEGSIABD05","IABD-19", "10.0.72.139", "74:56:3c:95:eb:d5", "Sierra Corral, Jesús","A"],
    ################################################################################# Profesores CEIABD
    ["omunillaf", "IABD-00", "10.0.72.120", "d8:bb:c1:35:f1:dd", "Óscar Munilla Fernández","P"],
    ["dblancog",  "IABD-00", "10.0.72.120", "d8:bb:c1:35:f1:dd", "David Blanco González","P"],
    ["paguirrej", "IABD-00", "10.0.72.120", "d8:bb:c1:35:f1:dd", "Pedro Aguirre Inchaurbe","P"],
    ["larce",     "IABD-00", "10.0.72.120", "d8:bb:c1:35:f1:dd", "Lorenzo  Arce Gómez","P"],
    ["vmuela",    "IABD-20", "10.0.72.140", "74:56:3c:95:eb:57", "Víctor","P"]
]

# Configuración del Dominio
DOMINIO = "iesmhp.local" # Cambiar por tu dominio
SERVIDOR_AD = "10.0.1.48" # IP del Controlador de Dominio

# Wake-on-LAN: el paquete mágico se envía al broadcast de la red del equipo
# destino (IP/PREFIJO_RED_WOL). Ej.: 10.0.32.120 -> 10.0.32.255
PREFIJO_RED_WOL = 24
PUERTO_WOL = 9

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
            return fila # Retorna [User, Host, IP, MAC, NombreReal, TipoUsuario]
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

def broadcast_de_red(ip, prefijo=PREFIJO_RED_WOL):
    """
    Devuelve la dirección de broadcast de la red a la que pertenece la IP.
    Ej.: 10.0.32.120 con /24 -> red 10.0.32.0/24 -> broadcast 10.0.32.255
    """
    red = ipaddress.ip_network(f"{ip}/{prefijo}", strict=False)
    return str(red.broadcast_address)

def enviar_wol(mac_address, ip_destino):
    """
    Envía un paquete mágico (Wake-on-LAN) a la dirección MAC.
    Esto sustituye a la utilidad externa para mayor compatibilidad.
    El paquete se manda como broadcast dirigido a la red del equipo destino
    (10.0.32.120 -> 10.0.32.255), no a 255.255.255.255, para que llegue aunque
    esta máquina esté en otra red (el router debe permitir broadcast dirigido).
    """
    # Limpiar formato MAC
    mac_clean = mac_address.replace(":", "").replace("-", "")

    if len(mac_clean) != 12:
        raise ValueError("Dirección MAC incorrecta")

    data = bytes.fromhex('FF' * 6 + mac_clean * 16)
    broadcast = broadcast_de_red(ip_destino)

    # Enviar paquete broadcast dirigido a la red destino
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.sendto(data, (broadcast, PUERTO_WOL))
    return broadcast

# --- FLUJO PRINCIPAL ---

def main():
    print(f"--- SISTEMA DE ARRANQUE REMOTO CORPORATIVO ---{VERSION}---\n")

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
    nombre_real = datos_equipo[4]
    tipo_usuario = datos_equipo[5]

    print(f"[OK] Usuario encontrado: {nombre_real} ({tipo_usuario}). Equipo asignado: {nombre_equipo} ({ip_equipo})")


    # 3. Pedir contraseña y verificar dominio
    password_input = getpass.getpass(f"Contraseña para {DOMINIO}\\{usuario_input}: ")

    print("\nVerificando credenciales...")
    if not verificar_credenciales(usuario_input, password_input):
        print("[X] Error: Contraseña incorrecta o error de dominio.")
        return

    print(f"[OK] Credenciales válidas. Equipo asociado: {nombre_equipo} ({ip_equipo})")

    #Si el tipo de usuario es profesor, preguntar si quiere encender todos los equipos de su clase, donde clase se define como todos los alumnos (tipo "A"), cuya IP empiece por los mismos primeros que la IP física del equipo actual.
    if tipo_usuario.upper() == "P":
        respuesta = input("¿Desea encender todos los equipos de su clase? (s/n): [n]").strip().lower()
        if respuesta == 's':
            prefijo_ip = '.'.join(ip_equipo.split('.')[:3]) + '.'
            print(f"[...] Encendiendo todos los equipos de la clase con prefijo IP {prefijo_ip}...")
            for fila in DATOS_USUARIOS:
                if fila[5].upper() == "A" and fila[2].startswith(prefijo_ip):
                    try:
                        broadcast = enviar_wol(fila[3], fila[2])
                        print(f"    WoL para {fila[1]} ({fila[2]}) - MAC: {fila[3]} -> {broadcast} ->{fila[0]}({fila[4]}) ")
                    except Exception as e:
                        print(f"    [X] Error enviando WoL a {fila[1]}: {e}")
            print("[OK] Señales WoL enviadas a todos los equipos asignados de la clase.")


    # 4. Comprobar estado actual
    if hacer_ping(ip_equipo):
        print(f"[!] El equipo {nombre_equipo} ya está encendido y respondiendo.")
        return

    # 5. Encender equipo
    print(f"[...] El equipo está apagado. Enviando señal Wake-on-LAN a {mac_equipo} (red {broadcast_de_red(ip_equipo)})...")
    try:
        enviar_wol(mac_equipo, ip_equipo)
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
#      d) Copiar el fichero EnciendeAlumno.py en /home/alumno/  (Si no hubiera ninguno!. La versión última no es la de github
             #cp /opt/IAC-IESMHP/Ubuntu/utilesUbuntuControl/homeAlumno/EnciendeAlumno.py /home/alumno/

# ssh root@10.0.32.252 "cd /opt/IAC-IESMHP; git pull"