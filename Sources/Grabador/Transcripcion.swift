import AVFoundation
import Foundation

/// Junta las dos pistas en un solo audio, lo transcribe con Transcriptor Pro reconociendo
/// hablantes (`-d`) y deja la conversación como nota .md:
///
///     [00:12:03] Hablante 1: Ok, entonces lo vemos el jueves.
///
///     [00:12:10] Hablante 2: Perfecto, te mando la minuta.
///
/// Las pistas separadas se conservan; la mezcla (`<nombre>_mezcla.m4a`) y lo que entrega
/// Transcriptor Pro (`<nombre>_mezcla.blocks.txt`/`.json`) quedan junto a ellas, fuera del vault.
enum Transcripcion {
    /// `destino` es la carpeta de la nota (por ejemplo, dentro del vault de Obsidian); sin ella, va junto al audio.
    static func ejecutar(en carpeta: URL, destino: URL? = nil, rehacer: Bool = false) async throws {
        let archivos = (try? FileManager.default.contentsOfDirectory(at: carpeta, includingPropertiesForKeys: nil)) ?? []
        guard let json = archivos.first(where: { $0.pathExtension == "json" && !$0.lastPathComponent.contains(".blocks.") }) else {
            throw ErrorGrabador("No encontré el JSON de la grabación en \(carpeta.path).")
        }
        let metadatos = try Metadatos.leer(de: json)
        if metadatos.completa == false {
            throw ErrorGrabador("Esta grabación quedó a medias. Corre primero: grabador recuperar")
        }
        guard !metadatos.pistas.isEmpty else {
            throw ErrorGrabador("El JSON no tiene pistas que transcribir.")
        }

        let mezcla = try await prepararMezcla(metadatos, en: carpeta, rehacer: rehacer)
        let bloques = carpeta.appendingPathComponent("\(metadatos.nombre)_mezcla.blocks.txt")

        if rehacer || !FileManager.default.fileExists(atPath: bloques.path) {
            print("\n▶ Transcribiendo con reconocimiento de hablantes…")
            try correrTranscriptor(audio: mezcla, salida: carpeta)
        } else {
            // Si renombraste hablantes con `transcriptor nombres`, esto toma los nombres nuevos
            print("✓ \(bloques.lastPathComponent) ya existe; lo reutilizo.")
        }

        let conversacion = try String(contentsOf: bloques, encoding: .utf8)
        let carpetaNota = destino ?? carpeta
        try FileManager.default.createDirectory(at: carpetaNota, withIntermediateDirectories: true)
        // Mismo nombre que la carpeta de la grabación: "2026-10-26_0913_reu_equipo.md"
        let archivoNota = carpetaNota.appendingPathComponent("\(carpeta.lastPathComponent).md")
        try contenidoNota(metadatos: metadatos, carpetaAudio: carpeta, conversacion: conversacion)
            .write(to: archivoNota, atomically: true, encoding: .utf8)

        print("\n■ Transcripción lista: \(archivoNota.path)")
    }

    // MARK: Mezcla

    /// Deja `<nombre>_mezcla.m4a` en la carpeta de la grabación, si no existe ya (o con `rehacer`).
    /// La usa `grabador` al terminar de grabar, con o sin `-t`, y antes de transcribir.
    @discardableResult
    static func prepararMezcla(_ metadatos: Metadatos, en carpeta: URL, rehacer: Bool = false) async throws -> URL {
        let mezcla = carpeta.appendingPathComponent("\(metadatos.nombre)_mezcla.m4a")
        if rehacer || !FileManager.default.fileExists(atPath: mezcla.path) {
            print("\n▶ Juntando las pistas en \(mezcla.lastPathComponent)…")
            try await mezclar(metadatos.pistas, en: carpeta, hacia: mezcla)
        }
        return mezcla
    }

    /// Pone cada pista en su desfase y exporta todo como un solo .m4a; así los tiempos de la
    /// transcripción quedan contados desde el inicio de la sesión.
    private static func mezclar(_ pistas: [Pista], en carpeta: URL, hacia destino: URL) async throws {
        let composicion = AVMutableComposition()
        for pista in pistas {
            let asset = AVURLAsset(url: carpeta.appendingPathComponent(pista.archivo))
            guard let origen = try await asset.loadTracks(withMediaType: .audio).first,
                  let nueva = composicion.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
                print("⚠️  \(pista.archivo) no trae audio; queda fuera de la mezcla.")
                continue
            }
            let duracion = try await asset.load(.duration)
            let desfase = CMTime(seconds: pista.desfaseS, preferredTimescale: 48_000)
            if desfase > .zero {
                nueva.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: desfase))
            }
            try nueva.insertTimeRange(CMTimeRange(start: .zero, duration: duracion), of: origen, at: desfase)
        }

        // Al recodificar, la exportación suma todas las pistas de audio en una sola
        guard let exportador = AVAssetExportSession(asset: composicion, presetName: AVAssetExportPresetAppleM4A) else {
            throw ErrorGrabador("No pude preparar la mezcla de las pistas.")
        }
        if FileManager.default.fileExists(atPath: destino.path) {
            try FileManager.default.removeItem(at: destino)  // solo con --rehacer: es una mezcla anterior
        }
        try await exportador.export(to: destino, as: .m4a)
    }

    // MARK: Nota

    /// Nota para Obsidian: propiedades arriba (fecha, duración, dónde está el audio) y después la conversación.
    private static func contenidoNota(metadatos: Metadatos, carpetaAudio: URL, conversacion: String) -> String {
        let minutos = Int((metadatos.duracionS / 60).rounded())
        return """
        ---
        fecha: \(metadatos.inicio)
        duracion: \(minutos) min
        audio: "\(carpetaAudio.path)"
        tags: [transcripcion]
        ---

        # \(metadatos.nombre)

        \(conversacion.trimmingCharacters(in: .whitespacesAndNewlines))

        """
    }

    // MARK: Transcriptor Pro

    private static func correrTranscriptor(audio: URL, salida: URL) throws {
        // Al grabar, Ctrl+C se ignora para cerrar los archivos con calma. Esa configuración la
        // heredaría Transcriptor Pro, así que se restaura: aquí Ctrl+C debe poder cortar.
        for senal in [SIGINT, SIGHUP, SIGTERM] {
            signal(senal, SIG_DFL)
        }

        guard let comando = buscarTranscriptor() else {
            throw ErrorGrabador("""
            No encontré el comando `transcriptor`. Dime dónde está con:
              grabador config --transcriptor /ruta/a/transcriptor
            """)
        }

        let proceso = Process()
        proceso.executableURL = comando
        // -d: reconoce quién habla (necesita el token de Hugging Face de Transcriptor Pro)
        proceso.arguments = ["transcribir", audio.path, "-d", "--sin-preguntas", "-o", salida.path]
        try proceso.run()
        proceso.waitUntilExit()

        guard proceso.terminationStatus == 0 else {
            throw ErrorGrabador("Transcriptor Pro terminó con error (código \(proceso.terminationStatus)).")
        }
    }

    /// Dónde está `transcriptor`: lo que diga `grabador config`, si no el PATH, y si no los lugares
    /// donde suele quedar (instalado con uv, o el entorno virtual del repo en ~/Proyectos/Transcriptor).
    static func buscarTranscriptor() -> URL? {
        var candidatos: [String] = []
        if let configurado = Configuracion.leer().transcriptor {
            candidatos.append(configurado)
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidatos += path.split(separator: ":").map { "\($0)/transcriptor" }
        candidatos += ["~/.local/bin/transcriptor", "~/Proyectos/Transcriptor/.venv/bin/transcriptor"]
            .map { NSString(string: $0).expandingTildeInPath }
        return candidatos.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}
