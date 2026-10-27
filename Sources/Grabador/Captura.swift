import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captura el audio del sistema y el del micrófono con ScreenCaptureKit, y entrega cada uno
/// a su propio `EscritorPista`. Requiere macOS 15 o superior (`captureMicrophone`).
///
/// Si la captura se cae (por ejemplo, al cambiar de micrófono), se reconecta sola sin cerrar
/// los archivos: el tiempo que estuvo caída queda como silencio en cada pista.
final class Captura: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let pistaSistema: EscritorPista
    private let pistaMic: EscritorPista
    private let colaVideo = DispatchQueue(label: "grabador.video")
    /// Protege `stream` y `deteniendo`, que se tocan desde la tarea principal y desde el delegado
    private let candado = NSLock()
    private var stream: SCStream?
    private var deteniendo = false

    private static let intentosDeReconexion = 5

    /// `inicio` es el instante de inicio de la sesión en el reloj del sistema; sirve para calcular el desfase de cada pista.
    /// `alEmpezarPista` se llama una vez por pista, cuando llega su primer audio.
    init(carpeta: URL, nombre: String, inicio: CMTime, alEmpezarPista: @escaping (Pista) -> Void) {
        pistaSistema = EscritorPista(rol: "otros", archivo: carpeta.appendingPathComponent("\(nombre)_sistema.m4a"),
                                     inicio: inicio, canales: 2, alEmpezar: alEmpezarPista)
        pistaMic = EscritorPista(rol: "yo", archivo: carpeta.appendingPathComponent("\(nombre)_mic.m4a"),
                                 inicio: inicio, canales: 1, alEmpezar: alEmpezarPista)
    }

    func iniciar() async throws {
        let nuevo = try await crearStream()
        try await nuevo.startCapture()
        candado.withLock { stream = nuevo }
    }

    /// Detiene la captura y cierra los dos archivos. Devuelve solo las pistas que recibieron audio.
    func detener() async -> [Pista] {
        let actual = candado.withLock { () -> SCStream? in
            deteniendo = true
            return stream
        }
        if let actual {
            try? await actual.stopCapture()  // falla si el stream ya se había detenido solo; no importa
        }
        var pistas: [Pista] = []
        for escritor in [pistaMic, pistaSistema] {
            if let pista = await escritor.finalizar() {
                pistas.append(pista)
            }
        }
        return pistas
    }

    /// Arma un stream nuevo con la pantalla actual. Se usa al iniciar y al reconectar.
    private func crearStream() async throws -> SCStream {
        let contenido = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let pantalla = contenido.displays.first else {
            throw ErrorGrabador("No encontré ninguna pantalla para crear el filtro de captura.")
        }
        // El filtro exige una pantalla aunque solo nos interese el audio
        let filtro = SCContentFilter(display: pantalla, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        // Video mínimo (2×2 píxeles, 1 cuadro por segundo); los cuadros se descartan
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.capturesAudio = true
        config.captureMicrophone = true              // macOS 15+; usa el micrófono predeterminado
        config.excludesCurrentProcessAudio = true    // que grabador no se grabe a sí mismo
        config.sampleRate = 48_000
        config.channelCount = 2

        let nuevo = SCStream(filter: filtro, configuration: config, delegate: self)
        // Sin una salida de video, ScreenCaptureKit llena la consola de avisos por cada cuadro sin destino
        try nuevo.addStreamOutput(self, type: .screen, sampleHandlerQueue: colaVideo)
        // Cada pista recibe sus buffers en su propia cola, la misma en la que escribe
        try nuevo.addStreamOutput(self, type: .audio, sampleHandlerQueue: pistaSistema.cola)
        try nuevo.addStreamOutput(self, type: .microphone, sampleHandlerQueue: pistaMic.cola)
        return nuevo
    }

    /// Intenta volver a capturar varias veces. Si no lo logra, cierra la sesión como si fuera Ctrl+C.
    private func reconectar() async {
        for intento in 1...Self.intentosDeReconexion {
            try? await Task.sleep(for: .seconds(1))
            if candado.withLock({ deteniendo }) { return }
            do {
                let nuevo = try await crearStream()
                try await nuevo.startCapture()
                let seguir = candado.withLock { () -> Bool in
                    guard !deteniendo else { return false }
                    stream = nuevo
                    return true
                }
                if !seguir {
                    try? await nuevo.stopCapture()
                    return
                }
                print("  🔄 Captura recuperada (intento \(intento)). Sigo grabando.")
                return
            } catch {
                print("  … intento \(intento) de \(Self.intentosDeReconexion) falló: \(error.localizedDescription)")
            }
        }
        print("⚠️  No pude recuperar la captura. Cierro y guardo lo grabado.")
        raise(SIGINT)  // usa el mismo camino de cierre que Ctrl+C
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of tipo: SCStreamOutputType) {
        guard buffer.isValid else { return }
        switch tipo {
        case .audio: pistaSistema.agregar(buffer)
        case .microphone: pistaMic.agregar(buffer)
        default: break  // .screen: el video no nos interesa
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let debeReconectar = candado.withLock { () -> Bool in
            // Solo nos importa el stream vigente, y no si estamos cerrando a propósito
            guard !deteniendo, stream === self.stream else { return false }
            self.stream = nil
            return true
        }
        guard debeReconectar else { return }
        print("\n⚠️  La captura se detuvo: \(error.localizedDescription). Intento reconectar…")
        Task { await self.reconectar() }
    }
}
