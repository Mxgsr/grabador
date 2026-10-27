import Foundation

/// El JSON que acompaña a cada grabación. Es el contrato con Transcriptor Pro:
/// si cambia o desaparece un campo, hay que subir `version` (agregar uno nuevo no lo exige).
///
/// {
///   "completa": true,
///   "duracion_s": 1834.2,
///   "inicio": "2026-10-23T10:00:00-03:00",
///   "nombre": "reunion",
///   "pistas": [
///     {"archivo": "reunion_mic.m4a", "desfase_s": 0.2, "rol": "yo",
///      "duracion_s": 1833.9, "deriva_s": 0.001, "huecos": [{"inicio_s": 612.4, "duracion_s": 0.83}]},
///     {"archivo": "reunion_sistema.m4a", "desfase_s": 0.135, "rol": "otros",
///      "duracion_s": 1834.0, "deriva_s": 0.0, "huecos": []}
///   ],
///   "version": 1
/// }
struct Metadatos: Codable {
    var version = 1
    var nombre: String
    var inicio: String       // ISO 8601 con la zona horaria local
    var duracionS: Double
    var pistas: [Pista]
    /// false mientras se graba o si el programa se cayó; nil en JSON anteriores a este campo (= completa)
    var completa: Bool?
}

struct Pista: Codable {
    var rol: String          // "yo" (micrófono) u "otros" (audio del sistema)
    var archivo: String      // nombre del .m4a dentro de la misma carpeta
    var desfaseS: Double     // segundos entre el inicio de la sesión y el primer audio de esta pista
    // Los tres siguientes se miden al cerrar; faltan si la grabación se cortó o es anterior a ellos
    var duracionS: Double?   // segundos de audio en el archivo (incluye el silencio de los huecos)
    var derivaS: Double?     // duracionS menos lo que duró de verdad según el reloj; cerca de 0 = sin deriva
    var huecos: [Hueco]?     // tramos sin audio que se rellenaron con silencio
}

/// Un tramo sin audio (por ejemplo, mientras macOS cambiaba de micrófono), relleno con silencio.
struct Hueco: Codable {
    var inicioS: Double      // segundos desde el inicio de la sesión
    var duracionS: Double
}

extension Metadatos {
    static func leer(de archivo: URL) throws -> Metadatos {
        let decodificador = JSONDecoder()
        decodificador.keyDecodingStrategy = .convertFromSnakeCase  // "duracion_s" → duracionS
        return try decodificador.decode(Metadatos.self, from: Data(contentsOf: archivo))
    }

    /// La escritura es atómica: o queda el archivo anterior o el nuevo, nunca uno a medias.
    func guardar(en archivo: URL) throws {
        let codificador = JSONEncoder()
        // sortedKeys: sin esto el orden de los campos cambia de una vez a otra
        codificador.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        codificador.keyEncodingStrategy = .convertToSnakeCase  // duracionS → "duracion_s"
        try codificador.encode(self).write(to: archivo, options: .atomic)
    }
}
