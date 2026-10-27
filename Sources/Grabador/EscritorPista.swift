import AVFoundation
import CoreMedia

/// Escribe una pista de audio en un .m4a (AAC). Todo su trabajo ocurre en `cola`,
/// la misma cola en la que ScreenCaptureKit entrega los buffers de esta pista.
/// Por eso es seguro marcarla `@unchecked Sendable`: su estado nunca se toca desde dos hilos a la vez.
///
/// Para aguantar cambios de dispositivo (por ejemplo, conectar unos AirPods a mitad de reunión):
/// - todo se convierte a un formato fijo (48 kHz), así el archivo no cambia de formato a mitad de camino;
/// - si entre dos buffers queda un hueco, se rellena con silencio para que la pista no se desfase.
final class EscritorPista: @unchecked Sendable {
    let cola: DispatchQueue
    private let rol: String
    private let archivo: URL
    private let inicio: CMTime
    private let alEmpezar: (Pista) -> Void
    /// Formato en que se escribe siempre esta pista: 48 kHz, float, 1 canal (mic) o 2 (sistema)
    private let formatoSalida: AVAudioFormat
    private var escritor: EscritorAAC?
    private var formatoEntrada: AVAudioFormat?
    private var conversor: AVAudioConverter?
    /// Instante en que debería empezar el próximo buffer si no hubiera huecos
    private var siguienteTiempo: CMTime?
    /// Fin del último buffer recibido, según el reloj del sistema (para medir la deriva)
    private var finReal: CMTime?
    private var cuadrosEscritos: AVAudioFramePosition = 0
    private var huecos: [Hueco] = []
    private var descartados = 0
    private var adelantos = 0
    private var cerrado = false

    /// Huecos más cortos que esto se ignoran (variación normal entre buffers)
    private static let huecoMinimo = 0.05

    init(rol: String, archivo: URL, inicio: CMTime, canales: AVAudioChannelCount,
         alEmpezar: @escaping (Pista) -> Void) {
        self.rol = rol
        self.archivo = archivo
        self.inicio = inicio
        self.alEmpezar = alEmpezar
        formatoSalida = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: canales)!
        cola = DispatchQueue(label: "grabador.\(rol)")
    }

    /// Se llama en `cola` por cada buffer que llega.
    func agregar(_ buffer: CMSampleBuffer) {
        guard !cerrado, let descripcion = buffer.formatDescription, buffer.numSamples > 0 else { return }
        let tiempo = buffer.presentationTimeStamp

        if escritor == nil {
            do {
                escritor = try EscritorAAC(archivo: archivo, formato: formatoSalida, primerTiempo: tiempo)
            } catch {
                print("⚠️  No pude crear \(archivo.lastPathComponent): \(error)")
                cerrado = true
                return
            }
            // Se anota de inmediato en el JSON: si después hay un corte, el desfase no se pierde
            alEmpezar(pistaActual(primerTiempo: tiempo))
        }

        let formato = AVAudioFormat(cmAudioFormatDescription: descripcion)
        if formato != formatoEntrada {
            cambiarFormatoEntrada(a: formato)
        }

        finReal = tiempo + CMTime(value: CMTimeValue(buffer.numSamples), timescale: CMTimeScale(formato.sampleRate))

        // Si el archivo ya va más adelante que el reloj real, este buffer sobra: se descarta
        // para no acumular deriva. Pasa muy rara vez (redondeos de la conversión).
        if let siguienteTiempo, (siguienteTiempo - tiempo).seconds > Self.huecoMinimo {
            adelantos += 1
            return
        }
        rellenarHueco(hasta: tiempo)

        guard let pcm = Self.pcm(de: buffer, formato: formato),
              let convertido = convertir(pcm) else {
            descartados += 1
            return
        }
        // Se escribe pegado al buffer anterior (la conversión puede variar unas pocas muestras);
        // los huecos reales ya se rellenaron arriba, así que esto no desfasa la pista
        escribir(convertido, en: siguienteTiempo ?? tiempo)
    }

    // MARK: Conversión de formato

    private func cambiarFormatoEntrada(a formato: AVAudioFormat) {
        let fuente = rol == "yo" ? "de tu micrófono" : "del sistema"
        let descripcion = "\(Int(formato.sampleRate)) Hz, \(formato.channelCount) \(formato.channelCount == 1 ? "canal" : "canales")"
        if formatoEntrada == nil {
            print("  ✓ Llegó audio \(fuente) (\(descripcion))")
        } else {
            print("  🎧 Cambió el formato \(fuente): ahora \(descripcion). Sigo grabando.")
        }
        formatoEntrada = formato
        if formato == formatoSalida {
            conversor = nil
        } else {
            conversor = AVAudioConverter(from: formato, to: formatoSalida)
            conversor?.downmix = true  // por si un micrófono USB entrega estéreo
        }
    }

    /// Lleva el buffer al formato fijo de salida. Si ya viene así, lo devuelve tal cual.
    private func convertir(_ pcm: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let conversor else { return pcm }
        let proporcion = formatoSalida.sampleRate / pcm.format.sampleRate
        let capacidad = AVAudioFrameCount((Double(pcm.frameLength) * proporcion).rounded(.up)) + 64
        guard let salida = AVAudioPCMBuffer(pcmFormat: formatoSalida, frameCapacity: capacidad) else { return nil }

        var entregado = false
        var error: NSError?
        let estado = conversor.convert(to: salida, error: &error) { _, estadoEntrada in
            // El conversor pide datos; le damos este buffer una sola vez
            if entregado {
                estadoEntrada.pointee = .noDataNow
                return nil
            }
            entregado = true
            estadoEntrada.pointee = .haveData
            return pcm
        }
        guard estado != .error, salida.frameLength > 0 else { return nil }
        return salida
    }

    // MARK: Huecos y escritura

    /// Si el nuevo buffer llega más tarde de lo esperado (por ejemplo, mientras macOS cambia de
    /// micrófono), escribe silencio en el medio para que el resto de la pista no se adelante.
    private func rellenarHueco(hasta tiempo: CMTime) {
        guard let siguienteTiempo else { return }
        let segundos = (tiempo - siguienteTiempo).seconds
        guard segundos > Self.huecoMinimo else { return }

        huecos.append(Hueco(inicioS: Self.redondear((siguienteTiempo - inicio).seconds),
                            duracionS: Self.redondear(segundos)))
        print("  ⏸  Hueco de \(String(format: "%.2f", segundos)) s en \(archivo.lastPathComponent); lo relleno con silencio.")
        var restantes = AVAudioFrameCount((segundos * formatoSalida.sampleRate).rounded())
        var cursor = siguienteTiempo
        while restantes > 0 {
            let cuadros = min(restantes, AVAudioFrameCount(formatoSalida.sampleRate))  // de a 1 segundo
            guard let silencio = AVAudioPCMBuffer(pcmFormat: formatoSalida, frameCapacity: cuadros) else { return }
            silencio.frameLength = cuadros  // un buffer nuevo ya viene en ceros
            escribir(silencio, en: cursor)
            cursor = cursor + CMTime(value: CMTimeValue(cuadros), timescale: CMTimeScale(formatoSalida.sampleRate))
            restantes -= cuadros
        }
    }

    private func escribir(_ pcm: AVAudioPCMBuffer, en tiempo: CMTime) {
        guard let escritor, let muestra = Self.muestra(de: pcm, tiempo: tiempo) else {
            descartados += 1
            return
        }
        if !escritor.agregar(muestra) {
            descartados += 1
            // Si el escritor falló, ya no aceptará nada más: avisamos de inmediato en vez de descartar en silencio
            if escritor.fallo {
                print("\n⚠️  Se dejó de grabar \(archivo.lastPathComponent): \(escritor.error)")
                cerrado = true
            }
            return
        }
        let duracion = CMTime(value: CMTimeValue(pcm.frameLength), timescale: CMTimeScale(formatoSalida.sampleRate))
        siguienteTiempo = tiempo + duracion
        cuadrosEscritos += AVAudioFramePosition(pcm.frameLength)
    }

    // MARK: Cierre

    /// Cierra el archivo limpio. Devuelve nil si nunca llegó audio a esta pista o si el archivo quedó inservible.
    func finalizar() async -> Pista? {
        await withCheckedContinuation { continuacion in
            cola.async { [self] in
                cerrado = true
                guard let escritor else {
                    continuacion.resume(returning: nil)
                    return
                }
                escritor.finalizar { [self] completo in
                    if descartados > 0 {
                        print("  ℹ \(descartados) buffers descartados en \(archivo.lastPathComponent)")
                    }
                    if !huecos.isEmpty {
                        print("  ℹ \(huecos.count) \(huecos.count == 1 ? "hueco rellenado" : "huecos rellenados") con silencio en \(archivo.lastPathComponent)")
                    }
                    if adelantos > 0 {
                        print("  ℹ \(adelantos) buffers sobrantes descartados en \(archivo.lastPathComponent) para no adelantarse")
                    }
                    guard completo else {
                        print("⚠️  \(archivo.lastPathComponent) quedó inservible y no se anota en el JSON: \(escritor.error)")
                        continuacion.resume(returning: nil)
                        return
                    }
                    continuacion.resume(returning: pistaFinal(primerTiempo: escritor.primerTiempo))
                }
            }
        }
    }

    private func pistaActual(primerTiempo: CMTime) -> Pista {
        // Los buffers de ScreenCaptureKit vienen en el reloj del sistema, igual que `inicio`
        let desfase = max(0, (primerTiempo - inicio).seconds)
        return Pista(rol: rol, archivo: archivo.lastPathComponent, desfaseS: Self.redondear(desfase))
    }

    /// La pista con lo que se midió al cerrar: duración en el archivo, deriva respecto del reloj y huecos.
    private func pistaFinal(primerTiempo: CMTime) -> Pista {
        var pista = pistaActual(primerTiempo: primerTiempo)
        let enArchivo = Double(cuadrosEscritos) / formatoSalida.sampleRate
        let real = finReal.map { ($0 - primerTiempo).seconds } ?? enArchivo
        let deriva = enArchivo - real
        pista.duracionS = Self.redondear(enArchivo)
        pista.derivaS = Self.redondear(deriva)
        pista.huecos = huecos
        if abs(deriva) > 0.1 {
            print("⚠️  \(archivo.lastPathComponent) se desvió \(String(format: "%+.2f", deriva)) s del reloj real.")
        }
        return pista
    }

    private static func redondear(_ segundos: Double) -> Double {
        (segundos * 1000).rounded() / 1000
    }

    // MARK: Conversión entre CMSampleBuffer y AVAudioPCMBuffer

    private static func pcm(de buffer: CMSampleBuffer, formato: AVAudioFormat) -> AVAudioPCMBuffer? {
        let cuadros = AVAudioFrameCount(buffer.numSamples)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: formato, frameCapacity: cuadros) else { return nil }
        pcm.frameLength = cuadros
        let estado = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            buffer, at: 0, frameCount: Int32(cuadros), into: pcm.mutableAudioBufferList)
        return estado == noErr ? pcm : nil
    }

    private static func muestra(de pcm: AVAudioPCMBuffer, tiempo: CMTime) -> CMSampleBuffer? {
        var tiempos = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
            presentationTimeStamp: tiempo,
            decodeTimeStamp: .invalid)
        var muestra: CMSampleBuffer?
        guard CMSampleBufferCreate(
                allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                makeDataReadyCallback: nil, refcon: nil,
                formatDescription: pcm.format.formatDescription,
                sampleCount: CMItemCount(pcm.frameLength),
                sampleTimingEntryCount: 1, sampleTimingArray: &tiempos,
                sampleSizeEntryCount: 0, sampleSizeArray: nil,
                sampleBufferOut: &muestra) == noErr,
              let muestra,
              CMSampleBufferSetDataBufferFromAudioBufferList(
                muestra, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0, bufferList: pcm.audioBufferList) == noErr
        else { return nil }
        return muestra
    }
}

/// Envoltorio mínimo de AVAssetWriter para una sola pista de audio AAC en formato fijo.
final class EscritorAAC {
    let primerTiempo: CMTime
    private let writer: AVAssetWriter
    private let entrada: AVAssetWriterInput

    var fallo: Bool { writer.status == .failed }
    var error: String { writer.error.map { "\($0)" } ?? "sin detalle" }

    init(archivo: URL, formato: AVAudioFormat, primerTiempo: CMTime) throws {
        // Sin AVEncoderBitRateKey: el codificador AAC elige una tasa válida para la frecuencia
        let ajustes: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: formato.sampleRate,
            AVNumberOfChannelsKey: Int(formato.channelCount),
        ]
        writer = try AVAssetWriter(outputURL: archivo, fileType: .m4a)
        entrada = AVAssetWriterInput(mediaType: .audio, outputSettings: ajustes)
        entrada.expectsMediaDataInRealTime = true
        // Escribe el archivo en fragmentos de 10 s: si el programa se cae, lo grabado hasta el
        // último fragmento sigue siendo legible (sin esto, un .m4a sin cerrar no se puede abrir)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        guard writer.canAdd(entrada) else {
            throw ErrorGrabador("AVAssetWriter no acepta este formato de audio")
        }
        writer.add(entrada)
        guard writer.startWriting() else {
            throw writer.error ?? ErrorGrabador("AVAssetWriter no pudo empezar a escribir")
        }
        // La línea de tiempo del archivo parte en el primer buffer; el desfase queda en el JSON
        writer.startSession(atSourceTime: primerTiempo)
        self.primerTiempo = primerTiempo
    }

    /// Devuelve false si el buffer no se pudo escribir.
    func agregar(_ muestra: CMSampleBuffer) -> Bool {
        entrada.isReadyForMoreMediaData && entrada.append(muestra)
    }

    func finalizar(_ listo: @escaping (Bool) -> Void) {
        guard writer.status == .writing else {
            listo(false)
            return
        }
        entrada.markAsFinished()
        writer.finishWriting { [writer] in
            listo(writer.status == .completed)
        }
    }
}
