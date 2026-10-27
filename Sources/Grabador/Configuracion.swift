import ArgumentParser
import Foundation

/// Ajustes que se eligen una vez y se guardan en ~/.config/grabador/config.json.
struct Configuracion: Codable {
    /// Dónde van los audios y su JSON. Conviene que quede fuera de iCloud y del vault de Obsidian.
    var carpetaAudios: String?
    /// Dónde va la nota .md con la transcripción, por ejemplo una carpeta de tu vault de Obsidian.
    /// Sin valor, la nota queda junto a los audios.
    var carpetaTranscripciones: String?
    /// Ruta al comando `transcriptor`. Sin valor, se busca en los lugares habituales.
    var transcriptor: String?

    static let porDefectoAudios = "~/Grabaciones"
    static let archivo = URL(fileURLWithPath: NSString(string: "~/.config/grabador/config.json").expandingTildeInPath)

    var audios: String { carpetaAudios ?? Self.porDefectoAudios }

    static func leer() -> Configuracion {
        let decodificador = JSONDecoder()
        decodificador.keyDecodingStrategy = .convertFromSnakeCase
        guard let datos = try? Data(contentsOf: archivo),
              let configuracion = try? decodificador.decode(Configuracion.self, from: datos) else {
            return Configuracion()
        }
        return configuracion
    }

    func guardar() throws {
        try FileManager.default.createDirectory(at: Self.archivo.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let codificador = JSONEncoder()
        codificador.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        codificador.keyEncodingStrategy = .convertToSnakeCase
        try codificador.encode(self).write(to: Self.archivo, options: .atomic)
    }
}

/// `grabador config`: muestra las carpetas o las cambia.
struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Muestra o cambia las carpetas de audios y de transcripciones."
    )

    @Option(help: "Carpeta de audios (mejor fuera de iCloud y del vault).")
    var audios: String?

    @Option(help: "Carpeta para las notas de transcripción, por ejemplo dentro de tu vault de Obsidian.")
    var transcripciones: String?

    @Option(help: "Ruta al comando `transcriptor` de Transcriptor Pro, si no lo encuentra solo.")
    var transcriptor: String?

    func run() throws {
        var configuracion = Configuracion.leer()
        if let audios {
            configuracion.carpetaAudios = Self.rutaCompleta(audios)
        }
        if let transcripciones {
            configuracion.carpetaTranscripciones = Self.rutaCompleta(transcripciones)
        }
        if let transcriptor {
            configuracion.transcriptor = Self.rutaCompleta(transcriptor)
        }
        if audios != nil || transcripciones != nil || transcriptor != nil {
            try configuracion.guardar()
            print("✓ Guardado en \(Configuracion.archivo.path)")
        }

        print("Audios:          \(configuracion.audios)")
        print("Transcripciones: \(configuracion.carpetaTranscripciones ?? "junto a cada audio")")
        print("Transcriptor:    \(Transcripcion.buscarTranscriptor()?.path ?? "no encontrado")")
        let audiosURL = URL(fileURLWithPath: NSString(string: configuracion.audios).expandingTildeInPath)
        if let aviso = Sesion.avisoSincronizacion(para: audiosURL.appendingPathComponent("x")) {
            print("⚠️  \(aviso)")
        }
    }

    /// Guarda la ruta completa, para que no dependa de desde dónde se corra el comando.
    private static func rutaCompleta(_ ruta: String) -> String {
        let expandida = NSString(string: ruta).expandingTildeInPath
        return URL(fileURLWithPath: expandida).standardizedFileURL.path
    }
}
