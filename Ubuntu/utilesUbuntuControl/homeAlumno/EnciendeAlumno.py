import sys
import time
import socket
import struct
import subprocess
import platform
import getpass
import ipaddress
from ldap3 import Server, Connection, ALL, NTLM

VERSION="2026.10.20 12:30"  # Encendido de aula: una línea por usuario del equipo "WoL EQ (IP)[MAC]->BCAST -> [id] Nombre"

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
    # Equipos de macs.csv sin usuario asignado (descomentar y poner usuario si se usan)
    # ["-", "SMRD-12", "10.0.32.132", "bc:fc:e7:05:73:cc", "Sin asignar", "A"],
    # ["-", "SMRD-17", "10.0.32.137", "bc:fc:e7:05:73:d0", "Sin asignar", "A"],

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
    # Equipos de macs.csv sin usuario asignado (descomentar y poner usuario si se usan)
    # ["-", "IABD-05", "10.0.72.125", "d8:bb:c1:38:93:b1", "Sin asignar", "A"],
    # ["-", "IABD-08", "10.0.72.128", "d8:bb:c1:38:93:8a", "Sin asignar", "A"],
    # ["-", "IABD-11", "10.0.72.131", "74:56:3C:65:5D:51", "Sin asignar", "A"],
    # ["-", "IABD-13", "10.0.72.133", "74:56:3C:95:EA:3C", "Sin asignar", "A"],
    # ["-", "IABD-15", "10.0.72.135", "74:56:3C:95:EB:55", "Sin asignar", "A"],
    # ["-", "IABD-17", "10.0.72.137", "74:56:3C:95:EB:87", "Sin asignar", "A"],
    ################################################################################# Profesores CEIABD
    ["vgrandec",  "IABD-19", "10.0.72.139", "74:56:3c:95:eb:d5", "Grande Cantero, Victor ","P"],
    ["jbahilloc", "IABD-00", "10.0.72.120", "d8:bb:c1:35:f1:dd", "Jairo Bahillo Calvo", "P"],
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
    """
    Busca el usuario en la matriz y devuelve TODAS sus filas
    (un profesor puede tener equipo en varias aulas, p. ej. SMRD e IABD).
    Cada fila: [User, Host, IP, MAC, NombreReal, TipoUsuario]
    """
    return [fila for fila in DATOS_USUARIOS if fila[0].lower() == usuario_input.lower()]

def elegir_equipo(filas):
    """Si hay un solo equipo lo devuelve; si hay varios, pregunta cuál encender."""
    if len(filas) == 1:
        return filas[0]
    print("\nTiene varios equipos asignados:")
    for i, fila in enumerate(filas, 1):
        print(f"   {i}) {fila[1]} ({fila[2]})")
    while True:
        opcion = input(f"¿Qué equipo desea encender? (1-{len(filas)}): ").strip()
        if opcion.isdigit() and 1 <= int(opcion) <= len(filas):
            return filas[int(opcion) - 1]
        print("[!] Opción no válida.")

def encender_aula(ip_equipo, mac_excluida):
    """
    Envía WoL a todos los equipos de DATOS_USUARIOS (alumnos y profesores) que
    están en la misma red (IP/PREFIJO_RED_WOL) que ip_equipo. Solo esa aula.
    Un mismo equipo puede aparecer en varias filas: se envía una vez por MAC y
    se muestra una línea por cada usuario asociado a ese equipo.
    """
    red = ipaddress.ip_network(f"{ip_equipo}/{PREFIJO_RED_WOL}", strict=False)
    excluida = mac_excluida.lower().replace("-", ":")
    # Agrupar filas por MAC (conservando el orden de DATOS_USUARIOS)
    equipos = {}
    for fila in DATOS_USUARIOS:
        mac = fila[3].lower().replace("-", ":")
        if mac != excluida and ipaddress.ip_address(fila[2]) in red:
            equipos.setdefault(mac, []).append(fila)
    print(f"[...] Encendiendo los equipos del aula {red}...")
    for filas in equipos.values():
        equipo, ip, mac = filas[0][1], filas[0][2], filas[0][3]
        try:
            broadcast = enviar_wol(mac, ip)
            for fila in filas:
                print(f"WoL {equipo} ({ip})[{mac}]->{broadcast} -> [{fila[0]}] {fila[4]}")
        except Exception as e:
            print(f"    [X] Error enviando WoL a {equipo}: {e}")
    print("[OK] Señales WoL enviadas a los equipos del aula.")

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
    filas_usuario = buscar_datos_usuario(usuario_input)

    if not filas_usuario:
        print("[X] Error: El usuario no tiene un equipo asociado en la base de datos.")
        return

    nombre_real = filas_usuario[0][4]
    tipo_usuario = filas_usuario[0][5]
    equipos_txt = ", ".join(f"{f[1]} ({f[2]})" for f in filas_usuario)

    print(f"[OK] Usuario encontrado: {nombre_real} ({tipo_usuario}). Equipo(s) asignado(s): {equipos_txt}")


    # 3. Pedir contraseña y verificar dominio
    password_input = getpass.getpass(f"Contraseña para {DOMINIO}\\{usuario_input}: ")

    print("\nVerificando credenciales...")
    if not verificar_credenciales(usuario_input, password_input):
        print("[X] Error: Contraseña incorrecta o error de dominio.")
        return

    # 4. Elegir equipo (un profesor puede tener varios; con uno solo no se pregunta)
    datos_equipo = elegir_equipo(filas_usuario)
    nombre_equipo = datos_equipo[1]
    ip_equipo = datos_equipo[2]
    mac_equipo = datos_equipo[3]

    print(f"[OK] Credenciales válidas. Equipo seleccionado: {nombre_equipo} ({ip_equipo})")

    # 5. Encender equipo (si no lo está ya)
    ya_encendido = hacer_ping(ip_equipo)
    if ya_encendido:
        print(f"[!] El equipo {nombre_equipo} ya está encendido y respondiendo.")
    else:
        print(f"[...] El equipo está apagado. Enviando señal Wake-on-LAN a {mac_equipo} (red {broadcast_de_red(ip_equipo)})...")
        try:
            enviar_wol(mac_equipo, ip_equipo)
            # Si prefieres usar la utilidad externa instalada, comenta la línea de arriba y usa:
            # subprocess.run(["wakeonlan", mac_equipo])
        except Exception as e:
            print(f"[X] Error enviando WoL: {e}")
            return

    # Profesor: ofrecer encender el aula del equipo elegido (solo los equipos de esa red)
    if tipo_usuario.upper() == "P":
        respuesta = input(f"¿Desea encender todos los equipos del aula de {nombre_equipo}? (s/n): [n] ").strip().lower()
        if respuesta == 's':
            encender_aula(ip_equipo, mac_equipo)

    if ya_encendido:
        return

    # 6. Bucle de espera del equipo seleccionado (Timeout 5 min = 300 seg)
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