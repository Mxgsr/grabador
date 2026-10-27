import Foundation

/// Una grabación en disco: su carpeta, su nombre y la hora en que empezó.
/// Estructura: ~/Grabaciones/2026-10-23_1000_reunion/{reunion_mic.m4a, reunion_sistema.m4a, reunion.json}
struct Sesion {
    let carpeta: URL
    let nombre: String
    let inicio: Date

    var archivoMetadatos: URL { carpeta.appendingPathComponent("\(nombre).json") }

    /// Crea la carpeta de la sesión. Falla si ya existe, para no pisar una grabación anterior.
    static func crear(en raiz: String, nombre: String, inicio: Date) throws -> Sesion {
        let limpio = limpiar(nombre)
        let base = URL(fileURLWithPath: NSString(string: raiz).expandingTildeInPath, isDirectory: true)

        let formato = DateFormatter()
        formato.locale = Locale(identifier: "en_US_POSIX")
        formato.dateFormat = "yyyy-MM-dd_HHmm"
        let carpeta = base.appendingPathComponent("\(formato.string(from: inicio))_\(limpio)", isDirectory: true)

        if FileManager.default.fileExists(atPath: carpeta.path) {
            throw ErrorGrabador("Ya existe \(carpeta.path). Usa otro --nombre o espera un minuto.")
        }
        try FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
        return Sesion(carpeta: carpeta, nombre: limpio, inicio: inicio)
    }

    /// Escribe el JSON de contrato con el transcriptor. La escritura es atómica:
    /// o queda el archivo anterior o el nuevo, nunca uno a medias.
    /// `completa` queda en false mientras se graba; `grabador recuperar` busca las que quedaron así.
    func guardarMetadatos(duracion: TimeInterval, pistas: [Pista] = [], completa: Bool) throws {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current  // "2026-10-23T10:00:00-03:00", con tu zona horaria
        let metadatos = Metadatos(
            nombre: nombre,
            inicio: iso.string(from: inicio),
            duracionS: (duracion * 10).rounded() / 10,
            pistas: pistas,
            completa: completa
        )
        try metadatos.guardar(en: archivoMetadatos)
    }

    /// Avisa si la carpeta parece estar dentro de iCloud u otro servicio de sincronización.
    /// No revisa si tienes activado "Escritorio y Documentos" en iCloud: evita esas dos carpetas.
    static func avisoSincronizacion(para carpeta: URL) -> String? {
        let ruta = carpeta.path
        let sospechosas = ["/Library/Mobile Documents/", "/Library/CloudStorage/", "/Desktop/", "/Documents/"]
        guard sospechosas.contains(where: { ruta.contains($0) }) else { return nil }
        return "La carpeta podría sincronizarse con la nube: \(ruta)"
    }

    /// Deja solo letras, números, "-" y "_" para que el nombre sirva como nombre de archivo.
    private static func limpiar(_ nombre: String) -> String {
        let permitidos = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let limpio = String(nombre.trimmingCharacters(in: .whitespaces).unicodeScalars.map {
            permitidos.contains($0) ? Character($0) : "_"
        })
        return limpio.isEmpty ? "grabacion" : limpio
    }
}

/// Error con un mensaje en español listo para mostrar.
struct ErrorGrabador: Error, CustomStringConvertible {
    let description: String
    init(_ mensaje: String) { description = mensaje }
}

/// Lleva las pistas que ya empezaron y las anota en el JSON apenas llega su primer audio,
/// para que el desfase de cada una sobreviva aunque el programa se caiga después.
final class RegistroSesion: @unchecked Sendable {
    private let sesion: Sesion
    private let candado = NSLock()
    private var pistas: [Pista] = []

    init(sesion: Sesion) {
        self.sesion = sesion
    }

    /// Se llama desde la cola de cada pista (de ahí el candado).
    func anotar(_ pista: Pista) {
        candado.withLock {
            pistas.append(pista)
            do {
                try sesion.guardarMetadatos(duracion: Date().timeIntervalSince(sesion.inicio),
                                            pistas: pistas, completa: false)
            } catch {
                print("⚠️  No pude actualizar \(sesion.archivoMetadatos.lastPathComponent): \(error)")
            }
        }
    }
}
