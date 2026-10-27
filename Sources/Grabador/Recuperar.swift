import ArgumentParser
import AVFoundation
import Foundation

/// `grabador recuperar`: busca grabaciones que quedaron a medias (corte de luz, cierre inesperado)
/// y deja su JSON completo con lo que se alcanzó a guardar.
struct Recuperar: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Completa el JSON de las grabaciones que quedaron a medias."
    )

    @Option(name: .shortAndLong, help: "Carpeta de los audios (por defecto, la de `grabador config`).")
    var carpeta: String?

    func run() async throws {
        let ruta = carpeta ?? Configuracion.leer().audios
        let base = URL(fileURLWithPath: NSString(string: ruta).expandingTildeInPath, isDirectory: true)
        let sesiones = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []

        var revisadas = 0
        for carpetaSesion in sesiones.sorted(by: { $0.path < $1.path }) {
            let archivos = (try? FileManager.default.contentsOfDirectory(at: carpetaSesion, includingPropertiesForKeys: nil)) ?? []
            guard let json = archivos.first(where: { $0.pathExtension == "json" }),
                  let metadatos = try? Metadatos.leer(de: json),
                  metadatos.completa == false else { continue }

            revisadas += 1
            print("• \(carpetaSesion.lastPathComponent)")
            try await recuperar(metadatos, en: carpetaSesion).guardar(en: json)
        }
        print(revisadas == 0
              ? "No hay grabaciones a medias en \(base.path)."
              : "Listo: \(revisadas) \(revisadas == 1 ? "grabación revisada" : "grabaciones revisadas").")
    }

    private func recuperar(_ original: Metadatos, en carpeta: URL) async -> Metadatos {
        var metadatos = original

        // Si el corte fue antes de que se anotaran las pistas, se buscan los archivos por nombre
        if metadatos.pistas.isEmpty {
            for (rol, sufijo) in [("yo", "mic"), ("otros", "sistema")] {
                let nombre = "\(metadatos.nombre)_\(sufijo).m4a"
                if FileManager.default.fileExists(atPath: carpeta.appendingPathComponent(nombre).path) {
                    metadatos.pistas.append(Pista(rol: rol, archivo: nombre, desfaseS: 0))
                    print("  ℹ \(nombre): no se alcanzó a anotar su desfase; uso 0.")
                }
            }
        }

        var legibles: [Pista] = []
        var duracion = 0.0
        for pista in metadatos.pistas {
            let asset = AVURLAsset(url: carpeta.appendingPathComponent(pista.archivo))
            do {
                let segundos = try await asset.load(.duration).seconds
                guard segundos.isFinite, segundos > 0 else { throw ErrorGrabador("no trae audio") }
                print("  ✓ \(pista.archivo): \(String(format: "%.1f", segundos)) s rescatados")
                legibles.append(pista)
                duracion = max(duracion, pista.desfaseS + segundos)
            } catch {
                print("  ✗ \(pista.archivo) no se puede leer (\(error)); queda fuera del JSON.")
            }
        }

        metadatos.pistas = legibles
        metadatos.duracionS = (duracion * 10).rounded() / 10
        metadatos.completa = true
        return metadatos
    }
}
