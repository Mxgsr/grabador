# Prueba de aceptación de la Fase 1

Objetivo: grabar 30 minutos reales sin cortes, con cada pista limpia, en Meet, Zoom y YouTube.

## Antes de empezar

- Usa audífonos (con cable o AirPods **ya conectados antes de iniciar**). Sin audífonos, el micrófono capta lo que suena por las bocinas y la pista "yo" queda con la voz de los demás.
- No conectes ni desconectes audífonos mientras graba: eso es de la Fase 2 y probablemente corte la captura.
- Compila una vez: `cd ~/Proyectos/Grabador && swift build`.
- Avisa a las personas de la reunión que estás grabando.

## Las tres pruebas

| # | Fuente | Duración | Comando |
|---|---|---|---|
| 1 | Video de YouTube en el navegador, tú hablando a ratos | 5 min | `swift run grabador grabar -n youtube` |
| 2 | Reunión de Google Meet (navegador) | 30 min | `swift run grabador grabar -n meet` |
| 3 | Reunión de Zoom (app) | 10 min o más | `swift run grabador grabar -n zoom` |

Para Meet o Zoom basta una reunión contigo mismo desde otro dispositivo (el teléfono, por ejemplo) si no tienes una real.

Termina cada prueba con **Ctrl+C** y espera a que aparezca "■ Listo".

## Qué revisar en cada carpeta

Abre la carpeta con `open ~/Grabaciones/*_meet/` (cambia `meet` por el nombre de la prueba).

1. **Archivos:** están `_mic.m4a`, `_sistema.m4a` y el `.json`.
2. **Pistas limpias:** en `_mic` se oye solo tu voz; en `_sistema` solo a los demás (o el video), nunca tu voz.
3. **Duración:** QuickTime muestra para cada .m4a casi lo mismo que `duracion_s` del JSON (diferencia de menos de 1 segundo).
4. **Sin cortes:** salta a tres puntos (inicio, mitad, final) de cada pista; no hay silencios ni saltos raros.
5. **Desfase:** en el JSON, cada `desfase_s` está entre 0 y 1.
6. **Terminal:** no apareció "buffers descartados" ni "La captura se detuvo sola". Si apareció, copia el mensaje.

## Qué me mandas

Por cada prueba: lo que imprimió la Terminal al final y una línea por punto que falló. Si todo está bien, con "ok" basta.
