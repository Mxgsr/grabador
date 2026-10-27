import ArgumentParser
import Foundation

/// `grabador transcribir <carpeta>`: transcribe (o vuelve a unir) una grabación ya hecha.
/// Sirve para las que se grabaron con `--sin-transcribir`, se recuperaron o cuya transcripción se cortó.
struct Transcribir: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribe una grabación ya hecha (para reintentar si la transcripción se cortó).",
        shouldDisplay: false  // lo normal es `grabador -t`; este queda como respaldo
    )

    @Argument(help: "Carpeta de la grabación, por ejemplo ~/Grabaciones/2026-10-26_0913_reu_equipo")
    var carpeta: String

    @Flag(help: "Vuelve a mezclar y transcribir aunque ya exista la transcripción.")
    var rehacer = false

    func run() async throws {
        let url = URL(fileURLWithPath: NSString(string: carpeta).expandingTildeInPath, isDirectory: true)
        let destino = Configuracion.leer().carpetaTranscripciones.map { URL(fileURLWithPath: $0, isDirectory: true) }
        try await Transcripcion.ejecutar(en: url, destino: destino, rehacer: rehacer)
    }
}
