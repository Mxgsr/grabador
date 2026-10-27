import ArgumentParser
import CoreMedia
import Foundation

/// `grabador grabar` (o solo `grabador`): graba el micrófono y el audio del sistema en dos .m4a
/// hasta que aprietes Ctrl+C, y al terminar los junta en `<nombre>_mezcla.m4a`.
/// Con `-t`, además transcribe esa mezcla con Transcriptor Pro.
struct Grabar: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Empieza una grabación. Ctrl+C la termina."
    )

    @Option(name: .shortAndLong, help: "Nombre de la grabación; se usa en la carpeta y en los archivos.")
    var nombre: String = "reunion"

    @Option(name: .shortAndLong, help: "Carpeta de los audios (por defecto, la de `grabador config`).")
    var carpeta: String?

    @Flag(name: .shortAndLong, help: "Transcribe al terminar y deja la nota en la carpeta de transcripciones.")
    var transcribir = false

    func run() async throws {
        guard Permisos.tieneGrabacionDePantalla() else {
            Permisos.explicar()
            throw ExitCode.failure
        }

        // Desde aquí, Ctrl+C, cerrar la ventana de Terminal o un `kill` cierran los archivos limpio
        let cierre = SenalDeCierre()

        // Se toman juntos: la hora del JSON y el mismo instante en el reloj de los buffers de audio
        let inicio = Date()
        let inicioReloj = CMClockGetTime(CMClockGetHostTimeClock())

        let configuracion = Configuracion.leer()
        let sesion = try Sesion.crear(en: carpeta ?? configuracion.audios, nombre: nombre, inicio: inicio)
        if let aviso = Sesion.avisoSincronizacion(para: sesion.carpeta) {
            print("⚠️  \(aviso)")
        }

        // El JSON se escribe desde el principio, marcado como incompleto hasta que termine bien
        try sesion.guardarMetadatos(duracion: 0, completa: false)
        let registro = RegistroSesion(sesion: sesion)

        let captura = Captura(carpeta: sesion.carpeta, nombre: sesion.nombre, inicio: inicioReloj,
                              alEmpezarPista: registro.anotar)
        do {
            try await captura.iniciar()
        } catch {
            throw ErrorGrabador("No pude iniciar la captura: \(error.localizedDescription)")
        }

        print("● Grabando en \(sesion.carpeta.path)")
        print("  ¿Avisaste que estás grabando? Aprieta Ctrl+C para terminar.")

        let motivo = await cierre.esperar()

        print("\n\(motivo). Cerrando archivos…")
        let pistas = await captura.detener()
        let duracion = Date().timeIntervalSince(inicio)
        try sesion.guardarMetadatos(duracion: duracion, pistas: pistas, completa: true)

        if !pistas.contains(where: { $0.rol == "yo" }) {
            print("⚠️  No llegó audio del micrófono. Revisa Ajustes → Privacidad y seguridad → Micrófono → Terminal.")
        }
        if !pistas.contains(where: { $0.rol == "otros" }) {
            print("⚠️  No llegó audio del sistema. ¿Estaba sonando algo mientras grababas?")
        }
        for pista in pistas {
            print("  • \(pista.archivo) (desfase \(String(format: "%.3f", pista.desfaseS)) s)")
        }
        print("■ Listo: \(String(format: "%.1f", duracion)) s. Metadatos en \(sesion.archivoMetadatos.lastPathComponent)")

        // Mezcla y transcripción solo si se terminó con Ctrl+C: con la ventana cerrada o el Mac
        // apagándose no hay quién espere. Las pistas separadas ya quedaron guardadas igual.
        guard motivo == SenalDeCierre.ctrlC, !pistas.isEmpty else { return }

        // Siempre se deja el audio mezclado (micrófono + sistema), se transcriba o no
        do {
            let metadatos = try Metadatos.leer(de: sesion.archivoMetadatos)
            let mezcla = try await Transcripcion.prepararMezcla(metadatos, en: sesion.carpeta)
            print("■ Audio mezclado: \(mezcla.lastPathComponent)")
        } catch {
            print("⚠️  No pude mezclar las pistas: \(error)")
            print("  Las pistas separadas están a salvo. Reintenta con: grabador transcribir \"\(sesion.carpeta.path)\"")
            return
        }

        guard transcribir else { return }
        print("\nTranscribiendo. La grabación ya está a salvo: si la cortas con Ctrl+C, retómala con")
        print("  grabador transcribir \"\(sesion.carpeta.path)\"")
        do {
            let destino = configuracion.carpetaTranscripciones.map { URL(fileURLWithPath: $0, isDirectory: true) }
            try await Transcripcion.ejecutar(en: sesion.carpeta, destino: destino)
        } catch {
            print("⚠️  \(error)")
            print("  La grabación está a salvo. Reintenta con: grabador transcribir \"\(sesion.carpeta.path)\"")
        }
    }
}

/// Atrapa las señales con las que se suele cerrar un programa para que no muera de golpe
/// y alcance a cerrar los archivos:
/// - SIGINT: Ctrl+C (también la usa la reconexión fallida de `Captura`)
/// - SIGHUP: cerrar la ventana o pestaña de Terminal
/// - SIGTERM: `kill`, o macOS cerrando sesión o apagándose
/// Un `kill -9` o un corte de luz no se pueden atrapar: para eso están los fragmentos de 10 s y `grabador recuperar`.
final class SenalDeCierre: @unchecked Sendable {
    static let ctrlC = "Ctrl+C"

    private static let senales: [(Int32, String)] = [
        (SIGINT, ctrlC),
        (SIGHUP, "Se cerró la ventana de Terminal"),
        (SIGTERM, "macOS pidió cerrar el programa"),
    ]

    /// Todo ocurre en esta cola serial, así `motivo` y `esperando` nunca se pisan
    private let cola = DispatchQueue(label: "grabador.senales")
    private var fuentes: [DispatchSourceSignal] = []
    private var motivo: String?
    private var esperando: CheckedContinuation<String, Never>?

    init() {
        // Con la ventana cerrada, escribir en la Terminal no debe matar el programa
        signal(SIGPIPE, SIG_IGN)
        for (numero, descripcion) in Self.senales {
            // Sin esto, la señal mata el proceso antes de que podamos guardar nada
            signal(numero, SIG_IGN)
            let fuente = DispatchSource.makeSignalSource(signal: numero, queue: cola)
            fuente.setEventHandler { [unowned self] in self.recibir(descripcion) }
            fuente.resume()
            fuentes.append(fuente)
        }
    }

    /// Espera la primera señal y devuelve su descripción.
    func esperar() async -> String {
        await withCheckedContinuation { continuacion in
            cola.async { [self] in
                if let motivo {
                    continuacion.resume(returning: motivo)
                } else {
                    esperando = continuacion
                }
            }
        }
    }

    private func recibir(_ descripcion: String) {
        guard motivo == nil else { return }  // solo cuenta la primera
        motivo = descripcion
        esperando?.resume(returning: descripcion)
        esperando = nil
    }
}
