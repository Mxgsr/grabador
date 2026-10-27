import ArgumentParser

/// Punto de entrada: `grabador` sin subcomando equivale a `grabador grabar`.
@main
struct Grabador: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grabador",
        abstract: "Graba el micrófono y el audio del sistema en pistas separadas, sin salir de tu Mac.",
        version: "0.1.0",
        subcommands: [Grabar.self, Config.self, Recuperar.self, Permiso.self, Transcribir.self],
        defaultSubcommand: Grabar.self
    )
}
