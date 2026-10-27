# Grabador de voz

Graba el micrófono y el audio del sistema de tu Mac en pistas separadas, en una carpeta local, y al terminar deja además un audio con las dos juntas. Opcionalmente lo transcribe con [Transcriptor Pro](https://github.com/Mxgsr/Transcriptor-pro) y deja la conversación como nota `.md`.

Todo ocurre en tu Mac: no usa internet ni telemetría. La única conexión es al compilar, para descargar `swift-argument-parser`.

**Estado:** CLI funcional (fases 1 a 3). Graba, aguanta cortes y cambios de audífonos, mezcla las pistas y transcribe. La app de barra de menú todavía no existe.

## Requisitos

- Mac con Apple Silicon (M1 o posterior).
- **macOS 15 Sequoia o posterior.** ScreenCaptureKit solo captura el micrófono desde esa versión.
- **Command Line Tools de Apple** (incluyen Swift 6). No hace falta Xcode completo, aunque también sirve.
- Opcional, para transcribir: Transcriptor Pro instalado y con su token de Hugging Face configurado (lo usa para reconocer quién habla).

## Instalar en otro Mac

### 1. Instalar las Command Line Tools

En Terminal:

```
xcode-select --install
```

Acepta la ventana que aparece y espera a que termine. Comprueba que quedó Swift 6 o superior:

```
swift --version
```

Si ya tenías Xcode instalado, este paso no hace falta.

### 2. Descargar el código

El repositorio es privado, así que necesitas haber iniciado sesión en GitHub en ese Mac (con `gh auth login` o con tus credenciales de git).

```
mkdir -p ~/Proyectos
cd ~/Proyectos
git clone https://github.com/Mxgsr/grabador.git
cd grabador
```

### 3. Compilar

```
swift build -c release
```

La primera vez tarda uno o dos minutos y descarga `swift-argument-parser`. El programa queda en `.build/release/grabador`.

### 4. Copiar el programa a un lugar del PATH

Para poder escribir `grabador` desde cualquier carpeta:

```
sudo mkdir -p /usr/local/bin
sudo cp .build/release/grabador /usr/local/bin/
```

Comprueba que funciona:

```
grabador --help
```

> Si prefieres no usar `sudo`, cópialo a `~/.local/bin` y agrega `export PATH="$HOME/.local/bin:$PATH"` a tu `~/.zshrc`.
>
> Cuando actualices el código (`git pull`), repite los pasos 3 y 4.

### 5. Dar los permisos de macOS

El permiso se le da a la **app desde la que corres el comando** (Terminal, iTerm, etc.), no al archivo `grabador`.

1. **Grabación de pantalla y audio del sistema.** Corre:
   ```
   grabador permiso
   ```
   Si falta, macOS muestra un aviso. Ve a Ajustes del Sistema → Privacidad y seguridad → **Grabación de pantalla y audio del sistema** y activa Terminal. Después cierra Terminal por completo con **Cmd+Q** y vuelve a abrirla: el permiso solo se aplica al reiniciarla. Al volver a correr `grabador permiso` debe decir "✅ El permiso de grabación está activo".
2. **Micrófono.** La primera grabación muestra el aviso de micrófono para Terminal: acéptalo. Si lo rechazaste, actívalo en Ajustes del Sistema → Privacidad y seguridad → **Micrófono** → Terminal.

### 6. Elegir las carpetas (una sola vez)

Por defecto los audios van a `~/Grabaciones` y la nota de transcripción queda junto a cada audio. Para cambiarlo:

```
grabador config --audios ~/Grabaciones
grabador config --transcripciones "/ruta/a/tu/vault/Transcripciones"
grabador config            # muestra las carpetas actuales
```

Deja la carpeta de audios **fuera de iCloud** y de cualquier carpeta sincronizada (ojo con Escritorio y Documentos si tienes iCloud Drive activado para ellas); el programa avisa si la carpeta parece sincronizarse. La configuración se guarda en `~/.config/grabador/config.json`.

### 7. Probar

Pon un video de YouTube, graba unos 30 segundos hablando a ratos y termina con **Ctrl+C**:

```
grabador -n prueba
```

Revisa la carpeta:

```
open ~/Grabaciones/
```

Debe haber una carpeta `AAAA-MM-DD_HHMM_prueba` con `prueba_mic.m4a` (solo tu voz), `prueba_sistema.m4a` (solo el video), `prueba_mezcla.m4a` (las dos juntas) y `prueba.json`.

## Uso diario

```
grabador -n reu_equipo        # graba hasta Ctrl+C y deja las pistas y la mezcla
grabador -t -n reu_equipo     # lo mismo y además transcribe al terminar
```

- `-n, --nombre`: nombre de la grabación (por defecto `reunion`). Se usa en la carpeta y en los archivos.
- `-t, --transcribir`: al terminar, transcribe la mezcla con Transcriptor Pro, reconociendo hablantes, y deja la nota `.md` en la carpeta de transcripciones.
- `-c, --carpeta`: carpeta de los audios solo para esta grabación.
- Al terminar con **Ctrl+C** siempre se crea `<nombre>_mezcla.m4a`, con las dos pistas alineadas, se transcriba o no.
- Usa audífonos: sin ellos, el micrófono capta por los parlantes la voz de los demás y queda duplicada en la mezcla.
- Avisa siempre a los demás que estás grabando.

La nota de transcripción se ve así:

```
[00:12:03] Hablante 1: Ok, entonces lo vemos el jueves.

[00:12:10] Hablante 2: Perfecto, te mando la minuta.
```

### Transcribir después o poner nombres

```
grabador transcribir ~/Grabaciones/2026-10-26_0913_reu_equipo            # transcribe una grabación ya hecha
grabador transcribir ~/Grabaciones/2026-10-26_0913_reu_equipo --rehacer  # vuelve a mezclar y transcribir desde cero
```

Para cambiar "Hablante 1" por nombres reales:

```
transcriptor nombres -e <carpeta>/<nombre>_mezcla.blocks.json
grabador transcribir <carpeta>
```

### Transcriptor Pro

`grabador` busca el comando `transcriptor` en este orden: lo que diga `grabador config --transcriptor`, el PATH, `~/.local/bin/transcriptor` y `~/Proyectos/Transcriptor/.venv/bin/transcriptor`. Si lo instalaste en otro lugar:

```
grabador config --transcriptor /ruta/a/transcriptor
```

## Si algo se corta

- **Ctrl+C, cerrar la ventana de Terminal o apagar el Mac:** el grabador lo detecta y cierra los archivos bien.
- **Conectar o desconectar audífonos a mitad de grabación:** la captura se reconecta sola sin cortar la grabación.
- **Corte de luz, `kill -9` o el programa se cae:** los `.m4a` se escriben en fragmentos de 10 s, así que se pierden como mucho los últimos segundos. El JSON queda marcado `"completa": false`. Para rescatarlo:
  ```
  grabador recuperar
  ```
  Revisa las grabaciones a medias, mide cuánto se alcanzó a guardar y completa su JSON.

## Formato de salida

```
~/Grabaciones/2026-10-23_1000_reunion/
├── reunion_mic.m4a          (tu micrófono)
├── reunion_sistema.m4a      (audio del sistema: los demás)
├── reunion_mezcla.m4a       (las dos juntas, alineadas)
└── reunion.json             (fecha, duración, pistas y su desfase)
```

El JSON es el contrato con el transcriptor. Ver `Sources/Grabador/Metadatos.swift`.

## Comandos

| Comando | Qué hace |
|---|---|
| `grabador` o `grabador grabar` | Graba hasta Ctrl+C |
| `grabador permiso` | Revisa o pide el permiso de grabación |
| `grabador config` | Muestra o cambia las carpetas |
| `grabador recuperar` | Completa grabaciones que quedaron a medias |
| `grabador transcribir <carpeta>` | Transcribe una grabación ya hecha |

`grabador --help` y `grabador <comando> --help` muestran todas las opciones.

## Para desarrollar

Sin instalar, desde la carpeta del repo:

```
swift run grabador --help
swift run -c release grabador -n prueba
```

`PRUEBA.md` describe la prueba de aceptación con Meet, Zoom y YouTube.
